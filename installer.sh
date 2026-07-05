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
read_env_value() {
  local key="$1" file=".env" line val
  [ -f "$file" ] || return 1
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 || true)"
  [ -n "$line" ] || return 1
  val="${line#*=}"
  [[ "$val" =~ ^\"(.*)\"$ ]] && val="${BASH_REMATCH[1]}"
  printf '%s' "$val"
}

prompt_secret() {
  local label="$1" val=""
  while [ -z "$val" ]; do
    printf '%s' "$label"
    if [ -t 0 ]; then read -r -s val; printf '\n'; else read -r val; fi
    [ -n "$val" ] || warn "Value is required."
  done
  printf '%s' "$val"
}

prompt_with_default() {
  local label="$1" default="$2" val
  printf '%s [%s]: ' "$label" "$default"
  read -r val
  printf '%s' "${val:-$default}"
}

select_model() {
  local role="$1" default_num="$2" choice result
  printf '\n%s model:\n' "$role"
  printf '  1) %s\n' "$MODEL_DEEPSEEK"
  printf '  2) %s\n' "$MODEL_QWEN"
  printf '  3) %s\n' "$MODEL_GRANITE"
  printf 'Select [1-3, Enter=%s]: ' "$default_num"
  read -r choice
  [ -z "$choice" ] && choice="$default_num"
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

  if [ -f .env ] && [ -t 0 ]; then
    local reconfigure
    printf 'Existing .env found. Reconfigure? [y/N]: '
    read -r reconfigure
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
FRONTEND_PORT=3000
BACKEND_PORT=8080
VALIDATOR_PORT=8181
CONFIG_FILE=${CONFIG_PATH}
HF_HOME=/tmp/hf
TECH_STACK_MANIFEST_GUARD=relaxed
VALIDATOR_LOG_LEVEL=INFO
EOF
  ok "Wrote .env"
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

pull_images() {
  header "Pulling images"
  local images=(backend frontend validator)
  for svc in "${images[@]}"; do
    local img
    img="$(grep -A3 "container_name: crew-${svc}" "$COMPOSE_FILE" 2>/dev/null | grep 'image:' | awk '{print $2}' | head -1 || true)"
    if [ -z "$img" ]; then
      info "Pulling ${svc} via compose ..."
      run_compose pull "$svc" || warn "Could not pull ${svc}"
    elif [ "$FORCE" = true ] || ! image_exists "$img"; then
      info "Pulling ${img} ..."
      "$CONTAINER_CMD" pull "$img" || warn "Could not pull ${img}"
    else
      ok "${img} already present"
    fi
  done
}

# ── Start stack ──────────────────────────────────────────────────────────────
ensure_volumes() {
  local project_name
  project_name="$(basename "$INSTALL_DIR")"
  mkdir -p \
    "${INSTALL_DIR}/${project_name}_crew-workspace/_data" \
    "${INSTALL_DIR}/${project_name}_crew-data/_data"
}

start_stack() {
  header "Starting stack"
  run_compose down --remove-orphans >/dev/null 2>&1 || true
  ensure_volumes
  info "Starting validator, backend, frontend ..."
  run_compose up -d validator backend frontend
  ok "Containers started"
}

wait_for_url() {
  local name="$1" url="$2" timeout="${3:-180}" elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    curl -sf "$url" >/dev/null 2>&1 && ok "${name} healthy" && return 0
    sleep 5; elapsed=$((elapsed + 5))
    info "Waiting for ${name} … (${elapsed}s/${timeout}s)"
  done
  warn "${name} not healthy after ${timeout}s — check: podman logs crew-${name,,}"
  return 1
}

wait_for_health() {
  header "Waiting for services"
  wait_for_url "Validator" "http://localhost:${VALIDATOR_PORT:-8181}/healthz" 120 || true
  wait_for_url "Backend"   "http://localhost:${BACKEND_PORT:-8080}/health"    180 || true
  wait_for_url "Frontend"  "http://localhost:${FRONTEND_PORT:-3000}/"          60 || true
}

print_summary() {
  local fp="${FRONTEND_PORT:-3000}" bp="${BACKEND_PORT:-8080}"
  header "OPL Crew is ready"
  printf '  %-12s %s\n' "UI:"  "http://localhost:${fp}"
  printf '  %-12s %s\n' "API:" "http://localhost:${bp}"
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
  printf '    Logs:    podman logs -f crew-backend\n'
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
