#!/usr/bin/env bash
# OPL Crew — interactive demo installer (macOS, Fedora, Linux)
# Pulls pre-built images, builds the validator, writes config, starts the stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

OS="$(uname -s)"
ARCH="$(uname -m)"
COMPOSE_FILE="compose.yml"
DEFAULT_BASE_URL="https://litellm-prod.apps.maas.redhatworkshops.io"
CONFIG_PATH="./opl-ai-software-team/config.yaml"
FORCE=false
SKIP_PROMPTS=false

# Red Hat MaaS model options (same as opl-studio-ui Settings)
MODEL_DEEPSEEK="deepseek-r1-distill-qwen-14b"
MODEL_QWEN="qwen3-14b"
MODEL_GRANITE="granite-3-2-8b-instruct"

# ── Colors (only when stdout is a TTY) ───────────────────────────────────────
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_RED=$'\033[31m'
else
  C_RESET= C_BOLD= C_GREEN= C_YELLOW= C_CYAN= C_RED=
fi

info()  { printf '%b\n' "${C_CYAN}→${C_RESET} $*"; }
ok()    { printf '%b\n' "${C_GREEN}✓${C_RESET} $*"; }
warn()  { printf '%b\n' "${C_YELLOW}!${C_RESET} $*"; }
die()   { printf '%b\n' "${C_RED}✗${C_RESET} $*" >&2; exit 1; }
header(){ printf '\n%b%s%b\n\n' "$C_BOLD" "$*" "$C_RESET"; }

usage() {
  cat <<'EOF'
Usage: ./installer.sh [OPTIONS]

Interactive installer for the OPL Crew demo stack (validator + backend + frontend).

Options:
  --force          Re-pull images and rebuild the validator even if present
  --yes            Use existing .env without re-prompting (if present)
  --help           Show this help

Requirements:
  git, curl, podman compose OR docker compose

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

detect_compose() {
  if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    COMPOSE_FN=podman
    COMPOSE_SUBCMD=(compose)
    COMPOSE_LABEL="podman compose"
    CONTAINER_CMD=podman
    ok "Using podman compose"
    return
  fi
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_FN=docker
    COMPOSE_SUBCMD=(compose)
    COMPOSE_LABEL="docker compose"
    CONTAINER_CMD=docker
    ok "Using docker compose"
    return
  fi
  if command -v podman-compose >/dev/null 2>&1; then
    COMPOSE_FN=podman-compose
    COMPOSE_SUBCMD=()
    COMPOSE_LABEL="podman-compose"
    CONTAINER_CMD=podman
    ok "Using podman-compose"
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_FN=docker-compose
    COMPOSE_SUBCMD=()
    COMPOSE_LABEL="docker-compose"
    CONTAINER_CMD=docker
    ok "Using docker-compose"
    return
  fi
  die "Need podman compose or docker compose. Install Podman/Docker and try again."
}

run_compose() {
  if [ "${#COMPOSE_SUBCMD[@]}" -gt 0 ]; then
    "$COMPOSE_FN" "${COMPOSE_SUBCMD[@]}" -f "$COMPOSE_FILE" "$@"
  else
    "$COMPOSE_FN" -f "$COMPOSE_FILE" "$@"
  fi
}

check_prereqs() {
  header "Checking prerequisites"
  command -v git >/dev/null 2>&1 || die "git is required"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  detect_compose
  ok "git and curl found"
}

init_submodules() {
  header "Initializing submodules"
  if [ ! -d .git ]; then
    warn "Not a git repository — skipping submodule init"
    return
  fi
  git submodule update --init crew-code-validator opl-ai-software-team
  [ -d crew-code-validator ] || die "crew-code-validator submodule missing — clone with --recurse-submodules"
  [ -f "$CONFIG_PATH" ] || die "config not found at $CONFIG_PATH — init opl-ai-software-team submodule"
  ok "Submodules ready"
}

read_env_value() {
  local key="$1"
  local file=".env"
  [ -f "$file" ] || return 1
  local line
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 || true)"
  [ -n "$line" ] || return 1
  printf '%s' "${line#*=}"
}

prompt_api_key() {
  local val=""
  while [ -z "$val" ]; do
    printf '%s' "[1/5] LLM API Key (required): "
    if [ -t 0 ]; then
      read -r -s val
      printf '\n'
    else
      read -r val
    fi
    [ -n "$val" ] || warn "API key is required."
  done
  LLM_API_KEY="$val"
}

prompt_with_default() {
  local label="$1"
  local default="$2"
  local val=""
  printf '%s [%s]: ' "$label" "$default"
  read -r val
  if [ -z "$val" ]; then
    val="$default"
  fi
  printf '%s' "$val"
}

select_model() {
  local role="$1"
  local default_num="$2"
  local choice=""
  local result=""

  printf '\n%s model (%s):\n' "$role" "$(echo "$role" | tr '[:upper:]' '[:lower:]')"
  printf '  1) %s\n' "$MODEL_DEEPSEEK"
  printf '  2) %s\n' "$MODEL_QWEN"
  printf '  3) %s\n' "$MODEL_GRANITE"
  if [ "$default_num" = "1" ]; then
    printf 'Select [1-3, Enter=1]: '
  elif [ "$default_num" = "2" ]; then
    printf 'Select [1-3, Enter=2]: '
  else
    printf 'Select [1-3, Enter=%s]: ' "$default_num"
  fi
  read -r choice
  [ -z "$choice" ] && choice="$default_num"
  case "$choice" in
    1) result="$MODEL_DEEPSEEK" ;;
    2) result="$MODEL_QWEN" ;;
    3) result="$MODEL_GRANITE" ;;
    *) die "Invalid model choice: $choice" ;;
  esac
  printf '%s' "$result"
}

load_or_prompt_config() {
  header "Configuration"

  if [ -f .env ] && [ "$SKIP_PROMPTS" = true ]; then
    info "Using existing .env (--yes)"
    LLM_API_KEY="$(read_env_value LLM_API_KEY || true)"
    LLM_API_BASE_URL="$(read_env_value LLM_API_BASE_URL || true)"
    LLM_MODEL_MANAGER="$(read_env_value LLM_MODEL_MANAGER || true)"
    LLM_MODEL_WORKER="$(read_env_value LLM_MODEL_WORKER || true)"
    LLM_MODEL_REVIEWER="$(read_env_value LLM_MODEL_REVIEWER || true)"
    [ -n "$LLM_API_KEY" ] || die ".env missing LLM_API_KEY"
    LLM_API_BASE_URL="${LLM_API_BASE_URL:-$DEFAULT_BASE_URL}"
    LLM_MODEL_MANAGER="${LLM_MODEL_MANAGER:-$MODEL_DEEPSEEK}"
    LLM_MODEL_WORKER="${LLM_MODEL_WORKER:-$MODEL_QWEN}"
    LLM_MODEL_REVIEWER="${LLM_MODEL_REVIEWER:-$MODEL_QWEN}"
    return
  fi

  if [ -f .env ] && [ -t 0 ]; then
    local reconfigure=""
    printf 'Existing .env found. Reconfigure? [y/N]: '
    read -r reconfigure
    if [ "$reconfigure" != "y" ] && [ "$reconfigure" != "Y" ]; then
      info "Keeping existing .env values"
      LLM_API_KEY="$(read_env_value LLM_API_KEY || true)"
      LLM_API_BASE_URL="$(read_env_value LLM_API_BASE_URL || true)"
      LLM_MODEL_MANAGER="$(read_env_value LLM_MODEL_MANAGER || true)"
      LLM_MODEL_WORKER="$(read_env_value LLM_MODEL_WORKER || true)"
      LLM_MODEL_REVIEWER="$(read_env_value LLM_MODEL_REVIEWER || true)"
      [ -n "$LLM_API_KEY" ] || die ".env missing LLM_API_KEY — re-run and choose reconfigure"
      LLM_API_BASE_URL="${LLM_API_BASE_URL:-$DEFAULT_BASE_URL}"
      LLM_MODEL_MANAGER="${LLM_MODEL_MANAGER:-$MODEL_DEEPSEEK}"
      LLM_MODEL_WORKER="${LLM_MODEL_WORKER:-$MODEL_QWEN}"
      LLM_MODEL_REVIEWER="${LLM_MODEL_REVIEWER:-$MODEL_QWEN}"
      return
    fi
  fi

  prompt_api_key
  LLM_API_BASE_URL="$(prompt_with_default "[2/5] LLM Base URL" "$DEFAULT_BASE_URL")"
  LLM_MODEL_MANAGER="$(select_model "Manager" "1")"
  LLM_MODEL_WORKER="$(select_model "Worker" "2")"
  LLM_MODEL_REVIEWER="$(select_model "Reviewer" "2")"
}

yaml_quote() {
  local val="$1"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  printf '"%s"' "$val"
}

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
CONFIG_FILE=./opl-ai-software-team/config.yaml
FLASK_ENV=production
TECH_STACK_MANIFEST_GUARD=relaxed
VALIDATOR_LOG_LEVEL=INFO
EOF
  ok "Wrote .env"
}

write_config_yaml() {
  header "Writing backend config"
  if [ -f "$CONFIG_PATH" ] && [ ! -f "${CONFIG_PATH}.bak" ]; then
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    info "Backed up existing config to ${CONFIG_PATH}.bak"
  fi

  cat > "$CONFIG_PATH" <<EOF
# AI Crew Studio — LLM Configuration
# Generated by installer.sh — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
llm:
  api_key: $(yaml_quote "$LLM_API_KEY")
  api_base_url: $(yaml_quote "$LLM_API_BASE_URL")
  environment: "production"
  model_manager: $(yaml_quote "$LLM_MODEL_MANAGER")
  model_worker: $(yaml_quote "$LLM_MODEL_WORKER")
  model_reviewer: $(yaml_quote "$LLM_MODEL_REVIEWER")
budget:
  max_cost_per_project: 100.0
EOF
  ok "Wrote $CONFIG_PATH"
}

image_exists() {
  local ref="$1"
  "$CONTAINER_CMD" image exists "$ref" >/dev/null 2>&1
}

pull_and_build() {
  header "Pulling images and building validator"

  if [ "$FORCE" = true ] || ! image_exists "quay.io/varkrish/crew-backend:latest"; then
    info "Pulling crew-backend:latest ..."
    run_compose pull backend
  else
    ok "crew-backend:latest already present (use --force to re-pull)"
  fi

  if [ "$FORCE" = true ] || ! image_exists "quay.io/varkrish/crew-frontend:latest"; then
    info "Pulling crew-frontend:latest ..."
    run_compose pull frontend
  else
    ok "crew-frontend:latest already present (use --force to re-pull)"
  fi

  if [ "$FORCE" = true ] || ! image_exists "crew-code-validator:latest"; then
    info "Building validator (first time may take a minute) ..."
    run_compose build validator
  else
    ok "crew-code-validator:latest already present (use --force to rebuild)"
  fi
}

start_stack() {
  header "Starting demo stack"
  info "Starting validator, backend, frontend (Jira/connector skipped for demo) ..."
  run_compose up -d validator backend frontend
  ok "Containers started"
}

wait_for_url() {
  local name="$1"
  local url="$2"
  local timeout="${3:-180}"
  local elapsed=0

  while [ "$elapsed" -lt "$timeout" ]; do
    if curl -sf "$url" >/dev/null 2>&1; then
      ok "$name is healthy"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    info "Waiting for $name ... (${elapsed}s / ${timeout}s)"
  done
  warn "$name did not become healthy within ${timeout}s — check: run_compose logs $name"
  return 1
}

wait_for_health() {
  header "Waiting for services"
  local backend_port="${BACKEND_PORT:-8080}"
  local validator_port="${VALIDATOR_PORT:-8181}"

  wait_for_url "Validator" "http://localhost:${validator_port}/healthz" 120 || true
  wait_for_url "Backend" "http://localhost:${backend_port}/health" 180 || true
  wait_for_url "Frontend" "http://localhost:${FRONTEND_PORT:-3000}/" 60 || true
}

print_summary() {
  local frontend_port="${FRONTEND_PORT:-3000}"
  local backend_port="${BACKEND_PORT:-8080}"

  header "Demo ready"
  printf '%b\n' "${C_GREEN}OPL Crew is running.${C_RESET}"
  printf '\n'
  printf '  UI:  %s\n' "http://localhost:${frontend_port}"
  printf '  API: %s\n' "http://localhost:${backend_port}"
  printf '\n'
  printf '  Models:\n'
  printf '    Manager:  %s\n' "$LLM_MODEL_MANAGER"
  printf '    Worker:   %s\n' "$LLM_MODEL_WORKER"
  printf '    Reviewer: %s\n' "$LLM_MODEL_REVIEWER"
  printf '\n'
  printf '  Submit a test job:\n'
  printf '    curl -X POST http://localhost:%s/api/jobs \\\n' "$backend_port"
  printf '      -H "Content-Type: application/json" \\\n'
  printf '      -d '"'"'{"vision": "Build a simple calculator API"}'"'"'\n'
  printf '\n'
  printf '  Logs:    %s -f compose.yml logs -f backend\n' "$COMPOSE_LABEL"
  printf '  Stop:    %s -f compose.yml down\n' "$COMPOSE_LABEL"
  printf '\n'

  if [ -t 1 ]; then
    if [ "$OS" = "Darwin" ]; then
      open "http://localhost:${frontend_port}" 2>/dev/null || true
    elif command -v xdg-open >/dev/null 2>&1; then
      xdg-open "http://localhost:${frontend_port}" 2>/dev/null || true
    fi
  fi
}

main() {
  printf '%b\n' "${C_BOLD}OPL Crew Demo Installer${C_RESET}"
  info "Platform: $OS ($ARCH)"

  check_prereqs
  init_submodules
  load_or_prompt_config
  write_env_file
  write_config_yaml
  pull_and_build
  start_stack
  wait_for_health
  print_summary
}

main "$@"
