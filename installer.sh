#!/usr/bin/env bash
# OPL Crew — standalone demo installer
# Usage:  curl -fsSL https://raw.githubusercontent.com/varkrish/opl-crew-mono/main/installer.sh | bash
# Or:     ./installer.sh [--force] [--yes] [--help]
#
# Does NOT require cloning the repo. Downloads compose.yml, writes config, pulls images.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/varkrish/opl-crew-mono/main"
COMPOSE_URL="${REPO_RAW}/compose.yml"
REALM_URL="${REPO_RAW}/keycloak/realm-export.json"
COMPOSE_FILE="compose.yml"
REALM_FILE="keycloak/realm-export.json"
# Primary config lives next to compose.yml so the volume mount is always a
# real file under the install dir (Podman/Docker create a *directory* when the
# mount source is missing — which then blocks writing config.yaml later).
# Also keep ~/.crew-ai/config.yaml as a compatibility copy for local tools.
CONFIG_DIR="${HOME}/.crew-ai"
USER_CONFIG_PATH="${CONFIG_DIR}/config.yaml"

OS="$(uname -s)"
ARCH="$(uname -m)"
DEFAULT_BASE_URL="https://litellm-prod.apps.maas.redhatworkshops.io"
FORCE=false

MODEL_DEEPSEEK="deepseek-r1-distill-qwen-14b"
MODEL_QWEN="qwen3-14b"
MODEL_GRANITE="granite-3-2-8b-instruct"

# ── Colors (TTY only) ────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m';  C_RED=$'\033[31m'
else
  C_RESET=; C_BOLD=; C_GREEN=; C_YELLOW=; C_CYAN=; C_RED=
fi

info()   { printf '%b\n' "${C_CYAN}→${C_RESET} $*"; }
ok()     { printf '%b\n' "${C_GREEN}✓${C_RESET} $*"; }
warn()   { printf '%b\n' "${C_YELLOW}!${C_RESET} $*"; }
die()    { printf '%b\n' "${C_RED}✗${C_RESET} $*" >&2; exit 1; }
header() { printf '\n%b%s%b\n\n' "$C_BOLD" "$*" "$C_RESET"; }

usage() {
  cat <<'EOF'
Usage: ./installer.sh [OPTIONS]

Standalone installer for OPL Crew (no git clone required).
Downloads compose.yml, writes config, pulls pre-built images, starts the stack.

Supported: macOS, Fedora, Ubuntu/Debian, RHEL
Requires:  curl, podman ≥ 4.0

The installer is non-interactive and never asks for an LLM API key.
Credentials are BYOK: each user saves their own key in the UI under
Settings → API Configuration, encrypted per user.

Options:
  --force   Re-pull images even if already present
  --yes     Accepted for compatibility (no prompts to skip)
  --help    Show this help

Optional server fallback (used only for users with no key of their own):
  LLM_API_KEY=...        Shared key. Empty by default, and empty is fine.
  LLM_API_BASE_URL=...   Defaults to the Red Hat MaaS gateway
  LLM_MODEL_MANAGER=...  Defaults to deepseek-r1-distill-qwen-14b
  LLM_MODEL_WORKER=...   Defaults to qwen3-14b
  LLM_MODEL_REVIEWER=... Defaults to qwen3-14b

Quick start (pipe install):
  curl -fsSL https://raw.githubusercontent.com/varkrish/opl-crew-mono/main/installer.sh | bash

After install:
  UI:  http://localhost:3000  → Settings → API Configuration to add your key
  API: http://localhost:8080
EOF
}

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --yes)   : ;;  # accepted for compatibility — there are no prompts to skip
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $arg (try --help)" ;;
  esac
done

# ── Work in a stable directory ───────────────────────────────────────────────
INSTALL_DIR="${OPL_CREW_DIR:-${HOME}/opl-crew}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ── Prereqs ──────────────────────────────────────────────────────────────────

# curl|bash runs a non-interactive non-login shell that does not load
# ~/.zprofile / ~/.bash_profile — so Homebrew's bin dir is often missing
# from PATH even when podman is installed. Prepend common locations.
_ensure_path() {
  local d
  local candidates=()
  if [ "$OS" = "Darwin" ]; then
    # Homebrew (Apple Silicon / Intel) + official Podman .pkg installer
    candidates+=("/opt/homebrew/bin" "/usr/local/bin" "/opt/podman/bin")
  fi
  candidates+=("${HOME}/.local/bin")
  for d in "${candidates[@]}"; do
    if [ -d "$d" ] && [[ ":${PATH}:" != *":${d}:"* ]]; then
      PATH="${d}:${PATH}"
    fi
  done
  export PATH
}

# On Linux, rootless podman exposes its socket at a user-specific path.
# Some compose shims (docker-compose, older podman-compose) look for the
# Docker socket instead — set DOCKER_HOST so they find podman's socket.
_fix_podman_socket() {
  [ "$OS" = "Linux" ] || return 0
  # Already set externally — trust it
  [ -n "${DOCKER_HOST:-}" ] && return 0

  local uid_socket="/run/user/$(id -u)/podman/podman.sock"
  local system_socket="/run/podman/podman.sock"

  if [ -S "$uid_socket" ]; then
    export DOCKER_HOST="unix://${uid_socket}"
    info "DOCKER_HOST → ${DOCKER_HOST}"
  elif [ -S "$system_socket" ]; then
    export DOCKER_HOST="unix://${system_socket}"
    info "DOCKER_HOST → ${DOCKER_HOST}"
  else
    # Socket doesn't exist yet — start user service
    warn "Podman socket not found. Starting podman system service ..."
    podman system service --time=0 &
    sleep 2
    if [ -S "$uid_socket" ]; then
      export DOCKER_HOST="unix://${uid_socket}"
      info "DOCKER_HOST → ${DOCKER_HOST}"
    fi
  fi
}

check_prereqs() {
  header "Checking prerequisites"
  _ensure_path
  command -v curl >/dev/null 2>&1 || die "curl is required"

  # Podman required — detect the binary first (do not require a running machine
  # for compose discovery; `podman compose version` talks to the VM and fails
  # when the machine is down, incorrectly falling through to podman-compose).
  if ! command -v podman >/dev/null 2>&1; then
    if [ "$OS" = "Darwin" ]; then
      die "Podman not found. Install: brew install podman && podman machine init && podman machine start"
    fi
    die "Podman not found. Install: sudo dnf install podman  (or apt install podman)"
  fi

  if podman help compose >/dev/null 2>&1; then
    COMPOSE_FN=podman; COMPOSE_SUBCMD=(compose); COMPOSE_LABEL="podman compose"; CONTAINER_CMD=podman
    ok "podman compose"
  elif command -v podman-compose >/dev/null 2>&1; then
    COMPOSE_FN=podman-compose; COMPOSE_SUBCMD=(); COMPOSE_LABEL="podman-compose"; CONTAINER_CMD=podman
    ok "podman-compose"
  else
    die "podman found ($(command -v podman)) but 'podman compose' is unavailable. Upgrade podman (brew upgrade podman) or install podman-compose."
  fi

  # Fix DOCKER_HOST before any container operations
  _fix_podman_socket

  if ! "$CONTAINER_CMD" info >/dev/null 2>&1; then
    [ "$OS" = "Darwin" ] && die "Podman machine not running — run: podman machine start"
    die "Podman daemon not running — run: podman system service --time=0 &"
  fi

  ok "Prerequisites satisfied"
}

run_compose() {
  if [ "${#COMPOSE_SUBCMD[@]}" -gt 0 ]; then
    "$COMPOSE_FN" "${COMPOSE_SUBCMD[@]}" -f "$COMPOSE_FILE" "$@"
  else
    "$COMPOSE_FN" -f "$COMPOSE_FILE" "$@"
  fi
}

# ── Download compose.yml + Keycloak realm ────────────────────────────────────
fetch_compose() {
  header "Fetching compose.yml"
  if [ -f "$COMPOSE_FILE" ] && [ "$FORCE" = false ]; then
    ok "compose.yml already present (use --force to re-download)"
  else
    info "Downloading from ${COMPOSE_URL} ..."
    curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_FILE"
    ok "compose.yml downloaded → ${INSTALL_DIR}/compose.yml"
  fi

  # compose.yml mounts this file into Keycloak — required for realm import
  mkdir -p "$(dirname "$REALM_FILE")"
  if [ -f "$REALM_FILE" ] && [ "$FORCE" = false ]; then
    ok "realm-export.json already present (use --force to re-download)"
  else
    info "Downloading Keycloak realm from ${REALM_URL} ..."
    curl -fsSL "$REALM_URL" -o "$REALM_FILE"
    ok "realm-export.json downloaded → ${INSTALL_DIR}/${REALM_FILE}"
  fi
}

# ── Config helpers ───────────────────────────────────────────────────────────
# There is no /dev/tty handling here any more: the installer asks nothing, so a
# piped install (curl ... | bash) and an unattended CI run take the identical
# path. That was the point of removing the key prompt — a shared key collected
# at install time is the wrong credential model when keys are per user.

read_env_value() {
  local key="$1" file=".env" line val
  [ -f "$file" ] || return 1
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 || true)"
  [ -n "$line" ] || return 1
  val="${line#*=}"
  # Strip surrounding quotes — POSIX sed, works on bash 3.2 (macOS) and bash 5+
  val="$(printf '%s' "$val" | sed 's/^"\(.*\)"$/\1/')"
  printf '%s' "$val"
}

# Resolve LLM settings without asking anything.
#
# The installer does not prompt for an API key. Credentials are BYOK: each user
# saves their own key in the UI under Settings → API Configuration, where it is
# encrypted per user. Asking at install time collected a key that every user of
# the instance would then share, and made an unattended install impossible.
#
# Everything below is an optional SERVER FALLBACK, used only when a user has no
# key of their own. It stays empty unless explicitly supplied via the
# environment or an existing .env, and an empty fallback is a supported state —
# the backend reports "LLM not configured" and points the user at Settings.
resolve_llm_config() {
  header "Configuration"

  # Precedence: environment > existing .env > built-in default.
  local from_env=""
  [ -f .env ] && from_env=".env"

  LLM_API_KEY="${LLM_API_KEY:-$( [ -n "$from_env" ] && read_env_value LLM_API_KEY || true )}"
  LLM_API_BASE_URL="${LLM_API_BASE_URL:-$( [ -n "$from_env" ] && read_env_value LLM_API_BASE_URL || true )}"
  LLM_MODEL_MANAGER="${LLM_MODEL_MANAGER:-$( [ -n "$from_env" ] && read_env_value LLM_MODEL_MANAGER || true )}"
  LLM_MODEL_WORKER="${LLM_MODEL_WORKER:-$( [ -n "$from_env" ] && read_env_value LLM_MODEL_WORKER || true )}"
  LLM_MODEL_REVIEWER="${LLM_MODEL_REVIEWER:-$( [ -n "$from_env" ] && read_env_value LLM_MODEL_REVIEWER || true )}"

  : "${LLM_API_BASE_URL:=$DEFAULT_BASE_URL}"
  : "${LLM_MODEL_MANAGER:=$MODEL_DEEPSEEK}"
  : "${LLM_MODEL_WORKER:=$MODEL_QWEN}"
  : "${LLM_MODEL_REVIEWER:=$MODEL_QWEN}"

  if [ -n "${LLM_API_KEY:-}" ]; then
    ok "Server fallback key configured (users may still bring their own)"
  else
    info "No server fallback key — each user adds their own in Settings → API Configuration"
  fi
  info "Base URL: ${LLM_API_BASE_URL}"
  info "Models:   ${LLM_MODEL_MANAGER} / ${LLM_MODEL_WORKER} / ${LLM_MODEL_REVIEWER}"
}

yaml_quote() { local v="${1//\\/\\\\}"; v="${v//\"/\\\"}"; printf '"%s"' "$v"; }

# Remove a path if a previous compose run turned a missing mount into a directory.
_remove_mount_dir_trap() {
  local path="$1"
  if [ -d "$path" ] && [ ! -L "$path" ]; then
    warn "Removing directory at ${path} (compose created it when the config file was missing)"
    rm -rf "$path"
  fi
}

_write_one_config_yaml() {
  local dest="$1"
  local dest_dir
  dest_dir="$(dirname "$dest")"
  mkdir -p "$dest_dir"
  [ "$dest_dir" = "$CONFIG_DIR" ] && chmod 700 "$dest_dir" 2>/dev/null || true

  _remove_mount_dir_trap "$dest"

  if [ -f "$dest" ] && [ ! -f "${dest}.bak" ]; then
    cp "$dest" "${dest}.bak"
    info "Backed up existing config → ${dest}.bak"
  fi

  cat > "$dest" <<EOF
# OPL Crew — LLM Configuration
# Generated by installer.sh — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# api_key here is an OPTIONAL SERVER FALLBACK, used only for users who have not
# saved their own. Credentials are BYOK: each user adds a key in the UI under
# Settings → API Configuration, encrypted per user. Leaving api_key empty is a
# supported state and the default.
llm:
  api_key: $(yaml_quote "$LLM_API_KEY")
  api_base_url: $(yaml_quote "$LLM_API_BASE_URL")
  environment: "production"
  model_manager: $(yaml_quote "$LLM_MODEL_MANAGER")
  model_worker: $(yaml_quote "$LLM_MODEL_WORKER")
  model_reviewer: $(yaml_quote "$LLM_MODEL_REVIEWER")
  max_tokens: 8192
  temperature: 0.7
budget:
  max_cost_per_project: 100.0
plan_review:
  enabled: false
solutioning:
  enabled: false
generation:
  parallel_file_workers: 5
EOF
  chmod 600 "$dest"
  [ -f "$dest" ] || die "Failed to write config file: ${dest}"
  ok "Wrote ${dest}"
}

write_env_file() {
  header "Writing .env"
  # Relative to compose.yml so the mount works on every machine / Podman VM.
  local compose_config="./config.yaml"
  cat > .env <<EOF
# Generated by installer.sh — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
LLM_API_KEY=$(yaml_quote "$LLM_API_KEY")
LLM_API_BASE_URL=$(yaml_quote "$LLM_API_BASE_URL")
LLM_MODEL_MANAGER=$(yaml_quote "$LLM_MODEL_MANAGER")
LLM_MODEL_WORKER=$(yaml_quote "$LLM_MODEL_WORKER")
LLM_MODEL_REVIEWER=$(yaml_quote "$LLM_MODEL_REVIEWER")

AUTH_ENABLED=false
FRONTEND_PORT=3100
BACKEND_PORT=8280
VALIDATOR_PORT=8281
KEYCLOAK_PORT=8380
CONFIG_FILE=${compose_config}
HF_HOME=/tmp/hf
TECH_STACK_MANIFEST_GUARD=relaxed
VALIDATOR_LOG_LEVEL=INFO
EOF
  ok "Wrote .env (CONFIG_FILE=${compose_config})"
  # Export port variables into the current shell so health checks use the right ports
  export FRONTEND_PORT=3100
  export BACKEND_PORT=8280
  export VALIDATOR_PORT=8281
  export KEYCLOAK_PORT=8380
  export CONFIG_FILE="$compose_config"
}

write_config_yaml() {
  header "Writing backend config"

  # 1) Install-dir config — this is what compose mounts (required).
  _write_one_config_yaml "${INSTALL_DIR}/config.yaml"

  # 2) User home copy — for host-side tools / docs that reference ~/.crew-ai.
  _write_one_config_yaml "$USER_CONFIG_PATH"

  # Guard: never start with a directory where a file should be.
  if [ ! -f "${INSTALL_DIR}/config.yaml" ]; then
    die "config.yaml missing at ${INSTALL_DIR}/config.yaml — cannot start backend"
  fi
}

# ── Pull images ───────────────────────────────────────────────────────────────
image_exists() { "$CONTAINER_CMD" image exists "$1" >/dev/null 2>&1; }

# Extract the image ref for a given compose service name from compose.yml.
# Expands ${VAR:-default} so podman pull gets a concrete reference.
_image_for_service() {
  local svc="$1" raw
  raw="$(
    grep -A8 "container_name: crew-${svc}" "$COMPOSE_FILE" 2>/dev/null \
      | grep 'image:' | awk '{print $2}' | head -1 || true
  )"
  [ -n "$raw" ] || return 0
  # ${VAR:-default} → default (or $VAR if set); bare ${VAR} → $VAR or empty
  while [[ "$raw" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^\}]*))?\} ]]; do
    local full="${BASH_REMATCH[0]}"
    local var="${BASH_REMATCH[1]}"
    local def="${BASH_REMATCH[3]}"
    local val="${!var:-}"
    [ -n "$val" ] || val="$def"
    raw="${raw/"$full"/$val}"
  done
  printf '%s' "$raw"
}

pull_images() {
  header "Pulling images"
  # Always pull via compose so platform: (e.g. linux/amd64) and
  # ${VAR:-default} image refs are resolved correctly on Apple Silicon.
  local services=(keycloak validator backend frontend skills-service skill-manager jira connector)
  for svc in "${services[@]}"; do
    info "Pulling ${svc} ..."
    run_compose pull "$svc" 2>/dev/null || warn "Could not pull ${svc}"
  done
}

# ── Start stack ──────────────────────────────────────────────────────────────
start_stack() {
  header "Starting stack"

  # Fail fast if the compose mount source is wrong (missing → empty directory).
  local cfg="${CONFIG_FILE:-./config.yaml}"
  # Resolve relative to install dir
  case "$cfg" in
    /*) ;;
    *) cfg="${INSTALL_DIR}/${cfg#./}" ;;
  esac
  if [ -d "$cfg" ]; then
    die "${cfg} is a directory (stale empty mount). Remove it and re-run: rm -rf ${cfg}"
  fi
  if [ ! -f "$cfg" ]; then
    die "Missing ${cfg}. Re-run the installer so it writes config.yaml before starting."
  fi
  ok "Config mount source OK → ${cfg}"

  # Stop and remove any containers compose knows about in this project.
  info "Stopping existing containers (if any) ..."
  run_compose down --remove-orphans 2>&1 || true

  # Force-remove containers by their fixed names in case they were created by a
  # previous install from a different directory (different compose project name).
  # compose --remove-orphans only removes containers it owns; cross-project
  # leftovers keep the name slot locked and block `up` with "name already in use".
  local core_containers="crew-keycloak-prod crew-validator-prod crew-backend-prod crew-frontend-prod crew-skills-prod crew-skill-manager-prod jira-prod crew-jira-connector-prod"
  for ctr in $core_containers; do
    if "$CONTAINER_CMD" container exists "$ctr" 2>/dev/null; then
      info "Removing stale container: $ctr"
      "$CONTAINER_CMD" rm -f "$ctr" 2>&1 || true
    fi
  done

  # keycloak is started because backend has depends_on: keycloak: healthy.
  # With AUTH_ENABLED=false the backend bypasses auth but compose still waits
  # for keycloak's healthcheck before allowing backend to start.
  info "Starting all services ..."
  run_compose up -d --force-recreate keycloak validator backend frontend skills-service skill-manager jira connector
  ok "Containers started"
}

wait_for_url() {
  local name="$1" url="$2" timeout="${3:-180}" elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    curl -sf "$url" >/dev/null 2>&1 && ok "${name} healthy" && return 0
    sleep 5; elapsed=$((elapsed + 5))
    info "Waiting for ${name} … (${elapsed}s/${timeout}s)"
  done
  warn "${name} not healthy after ${timeout}s — check: podman logs crew-$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')-prod"
  return 1
}

wait_for_health() {
  header "Waiting for services"
  wait_for_url "Validator"     "http://localhost:${VALIDATOR_PORT:-8181}/healthz"  120 || true
  wait_for_url "Backend"       "http://localhost:${BACKEND_PORT:-8080}/health"     180 || true
  wait_for_url "Frontend"      "http://localhost:${FRONTEND_PORT:-3000}/"           60 || true
  wait_for_url "Skills"        "http://localhost:${SKILLS_PORT:-8090}/health"       90 || true
  wait_for_url "Skill-Manager" "http://localhost:${SKILL_MANAGER_PORT:-8091}/api/health" 90 || true
}

print_summary() {
  local fp="${FRONTEND_PORT:-3000}" bp="${BACKEND_PORT:-8080}"
  local sp="${SKILLS_PORT:-8090}" smp="${SKILL_MANAGER_PORT:-8091}"
  local jp="${JIRA_PORT:-8081}" cp="${CONNECTOR_PORT:-8082}"
  header "OPL Crew is ready"
  printf '  %-16s %s\n' "UI:"           "http://localhost:${fp}"
  printf '  %-16s %s\n' "API:"          "http://localhost:${bp}"
  printf '  %-16s %s\n' "Skills:"       "http://localhost:${sp}"
  printf '  %-16s %s\n' "Skill Mgr:"   "http://localhost:${smp}"
  printf '  %-16s %s\n' "Jira:"         "http://localhost:${jp}"
  printf '  %-16s %s\n' "Jira Connector:" "http://localhost:${cp}"
  printf '\n'
  printf '  Config:\n'
  printf '    %-12s %s\n' "Compose:"  "${INSTALL_DIR}/config.yaml"
  printf '    %-12s %s\n' "User copy:" "${USER_CONFIG_PATH}"
  printf '\n'
  printf '  Models (server defaults — each user may override):\n'
  printf '    %-12s %s\n' "Manager:"  "$LLM_MODEL_MANAGER"
  printf '    %-12s %s\n' "Worker:"   "$LLM_MODEL_WORKER"
  printf '    %-12s %s\n' "Reviewer:" "$LLM_MODEL_REVIEWER"
  printf '\n'
  if [ -z "${LLM_API_KEY:-}" ]; then
    printf '%b\n' "  ${C_BOLD}Next step — add your LLM key${C_RESET}"
    printf '    Open http://localhost:%s → Settings → API Configuration\n' "$fp"
    printf '    Keys are per user and encrypted at rest (BYOK). Jobs stay\n'
    printf '    pending until a key is saved.\n'
    printf '\n'
  fi
  printf '  Test job:\n'
  printf '    curl -X POST http://localhost:%s/api/jobs \\\n' "$bp"
  printf '      -H "Content-Type: application/json" \\\n'
  printf '      -d '"'"'{"vision":"Build a simple calculator API"}'"'"'\n'
  printf '\n'
  printf '  Manage:\n'
  printf '    Logs:    podman logs -f crew-backend-prod\n'
  printf '    Stop:    cd %s && %s -f compose.yml down\n' "$INSTALL_DIR" "$COMPOSE_LABEL"
  printf '    Update:  ./installer.sh --force --yes\n'
  printf '\n'

  [ -t 1 ] && {
    [ "$OS" = "Darwin" ] && open "http://localhost:${fp}" 2>/dev/null || true
    command -v xdg-open >/dev/null 2>&1 && xdg-open "http://localhost:${fp}" 2>/dev/null || true
  }
  return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  printf '%b\n' "${C_BOLD}OPL Crew Installer${C_RESET}"
  info "Platform: ${OS} (${ARCH})"
  info "Install dir: ${INSTALL_DIR}"

  check_prereqs
  fetch_compose
  resolve_llm_config
  write_env_file
  write_config_yaml
  pull_images
  start_stack
  wait_for_health
  print_summary
}

main "$@"
