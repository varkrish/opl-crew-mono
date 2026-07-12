#!/usr/bin/env bash
# OPL Crew — standalone demo installer
# Usage:  curl -fsSL https://raw.githubusercontent.com/varkrish/opl-crew-mono/main/installer.sh | bash
# Or:     ./installer.sh [--force] [--yes] [--help]
#
# Does NOT require cloning the repo. Downloads compose.yml, writes config, pulls images.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/varkrish/opl-crew-mono/main"
COMPOSE_URL="${REPO_RAW}/compose.yml"
COMPOSE_FILE="compose.yml"
CONFIG_DIR="${HOME}/.crew-ai"
CONFIG_PATH="${CONFIG_DIR}/config.yaml"

OS="$(uname -s)"
ARCH="$(uname -m)"
DEFAULT_BASE_URL="https://litellm-prod.apps.maas.redhatworkshops.io"
FORCE=false
SKIP_PROMPTS=false

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

Options:
  --force   Re-pull images even if already present
  --yes     Re-use existing .env without re-prompting
  --help    Show this help

Quick start (pipe install):
  curl -fsSL https://raw.githubusercontent.com/varkrish/opl-crew-mono/main/installer.sh | bash

After install:
  UI:  http://localhost:3000
  API: http://localhost:8080
EOF
}

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --yes)   SKIP_PROMPTS=true ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $arg (try --help)" ;;
  esac
done

# ── Work in a stable directory ───────────────────────────────────────────────
INSTALL_DIR="${OPL_CREW_DIR:-${HOME}/opl-crew}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ── Prereqs ──────────────────────────────────────────────────────────────────

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
  command -v curl >/dev/null 2>&1 || die "curl is required"

  # Podman required
  if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    COMPOSE_FN=podman; COMPOSE_SUBCMD=(compose); COMPOSE_LABEL="podman compose"; CONTAINER_CMD=podman
    ok "podman compose"
  elif command -v podman-compose >/dev/null 2>&1; then
    COMPOSE_FN=podman-compose; COMPOSE_SUBCMD=(); COMPOSE_LABEL="podman-compose"; CONTAINER_CMD=podman
    ok "podman-compose"
  elif [ "$OS" = "Darwin" ]; then
    die "Podman not found. Install: brew install podman && podman machine init && podman machine start"
  else
    die "Podman not found. Install: sudo dnf install podman  (or apt install podman)"
  fi

  # Fix DOCKER_HOST before any container operations
  _fix_podman_socket

  if ! "$CONTAINER_CMD" images >/dev/null 2>&1; then
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

# ── Download compose.yml ─────────────────────────────────────────────────────
fetch_compose() {
  header "Fetching compose.yml"
  if [ -f "$COMPOSE_FILE" ] && [ "$FORCE" = false ]; then
    ok "compose.yml already present (use --force to re-download)"
    return
  fi
  info "Downloading from ${COMPOSE_URL} ..."
  curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_FILE"
  ok "compose.yml downloaded → ${INSTALL_DIR}/compose.yml"
}

# ── Config helpers ───────────────────────────────────────────────────────────
# Use /dev/tty for all interactive reads so the script works when piped
# (curl ... | bash) as well as when run directly. /dev/tty always connects
# to the controlling terminal regardless of how stdin is wired.
# Fall back to /dev/null if /dev/tty is not available (e.g. CI with no TTY).
# The redirect test is the most portable way to check tty availability.
if { : >/dev/tty; } 2>/dev/null; then
  TTY=/dev/tty
else
  TTY=/dev/null
fi

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

prompt_secret() {
  local label="$1" val=""
  # When there is no controlling terminal (CI, pipe with --yes) skip prompting.
  [ "$TTY" = "/dev/null" ] && return 0
  while [ -z "$val" ]; do
    printf '%s' "$label" >"$TTY"
    # stty -echo / stty echo works on macOS and Linux
    stty -echo <"$TTY" 2>/dev/null || true
    read -r val <"$TTY"
    stty echo  <"$TTY" 2>/dev/null || true
    printf '\n' >"$TTY"
    [ -n "$val" ] || warn "Value is required."
  done
  printf '%s' "$val"
}

prompt_with_default() {
  local label="$1" default="$2" val
  [ "$TTY" = "/dev/null" ] && printf '%s' "$default" && return 0
  printf '%s [%s]: ' "$label" "$default" >"$TTY"
  read -r val <"$TTY"
  printf '%s' "${val:-$default}"
}

select_model() {
  local role="$1" default_num="$2" choice result
  if [ "$TTY" = "/dev/null" ]; then
    choice="$default_num"
  else
    printf '\n%s model:\n' "$role" >"$TTY"
    printf '  1) %s\n' "$MODEL_DEEPSEEK" >"$TTY"
    printf '  2) %s\n' "$MODEL_QWEN"     >"$TTY"
    printf '  3) %s\n' "$MODEL_GRANITE"  >"$TTY"
    printf 'Select [1-3, Enter=%s]: ' "$default_num" >"$TTY"
    read -r choice <"$TTY"
    [ -z "$choice" ] && choice="$default_num"
  fi
  case "$choice" in
    1) result="$MODEL_DEEPSEEK" ;;
    2) result="$MODEL_QWEN" ;;
    3) result="$MODEL_GRANITE" ;;
    *) die "Invalid choice: $choice" ;;
  esac
  printf '%s' "$result"
}

load_or_prompt_config() {
  header "Configuration"

  if [ -f .env ] && [ "$SKIP_PROMPTS" = true ]; then
    info "Using existing .env (--yes)"
    LLM_API_KEY="$(read_env_value LLM_API_KEY || true)"
    [ -n "$LLM_API_KEY" ] || die ".env missing LLM_API_KEY"
    LLM_API_BASE_URL="$(read_env_value LLM_API_BASE_URL || echo "$DEFAULT_BASE_URL")"
    LLM_MODEL_MANAGER="$(read_env_value LLM_MODEL_MANAGER || echo "$MODEL_DEEPSEEK")"
    LLM_MODEL_WORKER="$(read_env_value LLM_MODEL_WORKER || echo "$MODEL_QWEN")"
    LLM_MODEL_REVIEWER="$(read_env_value LLM_MODEL_REVIEWER || echo "$MODEL_QWEN")"
    return
  fi

  if [ -f .env ]; then
    local reconfigure
    printf 'Existing .env found. Reconfigure? [y/N]: ' >"$TTY"
    read -r reconfigure <"$TTY"
    if [ "$reconfigure" != "y" ] && [ "$reconfigure" != "Y" ]; then
      LLM_API_KEY="$(read_env_value LLM_API_KEY || true)"
      [ -n "$LLM_API_KEY" ] || die ".env missing LLM_API_KEY — re-run without --yes"
      LLM_API_BASE_URL="$(read_env_value LLM_API_BASE_URL || echo "$DEFAULT_BASE_URL")"
      LLM_MODEL_MANAGER="$(read_env_value LLM_MODEL_MANAGER || echo "$MODEL_DEEPSEEK")"
      LLM_MODEL_WORKER="$(read_env_value LLM_MODEL_WORKER || echo "$MODEL_QWEN")"
      LLM_MODEL_REVIEWER="$(read_env_value LLM_MODEL_REVIEWER || echo "$MODEL_QWEN")"
      return
    fi
  fi

  LLM_API_KEY="$(prompt_secret "[1/5] LLM API Key (hidden): ")"
  LLM_API_BASE_URL="$(prompt_with_default "[2/5] LLM Base URL" "$DEFAULT_BASE_URL")"
  LLM_MODEL_MANAGER="$(select_model "Manager [3/5]" "1")"
  LLM_MODEL_WORKER="$(select_model "Worker [4/5]" "2")"
  LLM_MODEL_REVIEWER="$(select_model "Reviewer [5/5]" "2")"
}

yaml_quote() { local v="${1//\\/\\\\}"; v="${v//\"/\\\"}"; printf '"%s"' "$v"; }

write_env_file() {
  header "Writing .env"
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
CONFIG_FILE=${CONFIG_PATH}
HF_HOME=/tmp/hf
TECH_STACK_MANIFEST_GUARD=relaxed
VALIDATOR_LOG_LEVEL=INFO
EOF
  ok "Wrote .env"
  # Export port variables into the current shell so health checks use the right ports
  export FRONTEND_PORT=3100
  export BACKEND_PORT=8280
  export VALIDATOR_PORT=8281
  export KEYCLOAK_PORT=8380
}

write_config_yaml() {
  header "Writing backend config (${CONFIG_PATH})"
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"

  if [ -f "$CONFIG_PATH" ] && [ ! -f "${CONFIG_PATH}.bak" ]; then
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    info "Backed up existing config → ${CONFIG_PATH}.bak"
  fi

  cat > "$CONFIG_PATH" <<EOF
# OPL Crew — LLM Configuration
# Generated by installer.sh — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
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
  chmod 600 "$CONFIG_PATH"
  ok "Wrote ${CONFIG_PATH}"
}

# ── Pull images ───────────────────────────────────────────────────────────────
image_exists() { "$CONTAINER_CMD" image exists "$1" >/dev/null 2>&1; }

# Extract the image ref for a given compose service name from compose.yml.
_image_for_service() {
  local svc="$1"
  grep -A5 "container_name: crew-${svc}" "$COMPOSE_FILE" 2>/dev/null \
    | grep 'image:' | awk '{print $2}' | head -1 || true
}

pull_images() {
  header "Pulling images"
  local services=(keycloak validator backend frontend skills-service skill-manager jira connector)
  for svc in "${services[@]}"; do
    local img
    # keycloak container is named crew-keycloak
    img="$(_image_for_service "$svc")"
    if [ -z "$img" ]; then
      info "Pulling ${svc} via compose ..."
      run_compose pull "$svc" 2>/dev/null || warn "Could not pull ${svc}"
    elif [ "$FORCE" = true ] || ! image_exists "$img"; then
      info "Pulling ${img} ..."
      "$CONTAINER_CMD" pull "$img" || warn "Could not pull ${img}"
    else
      ok "${img} already present"
    fi
  done
}

# ── Start stack ──────────────────────────────────────────────────────────────
start_stack() {
  header "Starting stack"

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
  printf '  Models:\n'
  printf '    %-12s %s\n' "Manager:"  "$LLM_MODEL_MANAGER"
  printf '    %-12s %s\n' "Worker:"   "$LLM_MODEL_WORKER"
  printf '    %-12s %s\n' "Reviewer:" "$LLM_MODEL_REVIEWER"
  printf '\n'
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
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  printf '%b\n' "${C_BOLD}OPL Crew Installer${C_RESET}"
  info "Platform: ${OS} (${ARCH})"
  info "Install dir: ${INSTALL_DIR}"

  check_prereqs
  fetch_compose
  load_or_prompt_config
  write_env_file
  write_config_yaml
  pull_images
  start_stack
  wait_for_health
  print_summary
}

main "$@"
