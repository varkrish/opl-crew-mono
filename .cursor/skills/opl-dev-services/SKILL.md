---
name: opl-dev-services
description: >-
  Start, stop, restart, and check status of OPL Crew services. Use when the
  user asks to run, start, stop, restart, rebuild, or check containers, services,
  dev compose, local development, or health checks. Covers both container mode
  (podman/docker compose) and local mode (bare-metal processes).
---

# OPL Dev Services

Manage the OPL Crew platform services in two modes: **container** (default) and **local**.

## Service Topology

| Service | Container Name | Port | Health Endpoint |
|---------|---------------|------|-----------------|
| Backend (FastAPI) | crew-backend-dev | 8080 | `/health` |
| Frontend (Vite) | crew-frontend-dev | 3000 | `/` |
| Validator (FastAPI) | crew-validator-dev | 8180 | `/healthz` |
| Skills Service | crew-skills-dev | 8090 | `/health` |
| Jira Server | jira-dev | 8081 | — |
| Jira Connector | crew-jira-connector-dev | 8082 | — |

## Prerequisites

```bash
# Ensure .env exists (copy from template if not)
cp .env.example .env  # then fill in LLM_API_KEY at minimum
```

---

## Container Mode (Default)

All commands run from the **mono repo root** (`opl_ai_mono/`).

### Start core services (recommended)

```bash
podman compose -f dev-compose.yml up -d --build backend validator skills-service frontend
```

Starts: validator → backend → frontend, plus skills-service in parallel.
Jira/connector are excluded unless explicitly requested.

### Start all services (including Jira)

```bash
podman compose -f dev-compose.yml up -d --build
```

### Stop all services

```bash
podman compose -f dev-compose.yml down
```

### Stop and reset volumes (clean slate)

```bash
podman compose -f dev-compose.yml down -v
```

### Restart a single service

```bash
podman compose -f dev-compose.yml restart backend
```

### Rebuild and restart a single service

```bash
podman compose -f dev-compose.yml up -d --build backend
```

### View logs

```bash
# All services
podman compose -f dev-compose.yml logs -f

# Single service
podman compose -f dev-compose.yml logs -f backend
```

### Check status

```bash
podman compose -f dev-compose.yml ps
```

### Health check all services

```bash
curl -sf http://localhost:8080/health  && echo "backend: OK"
curl -sf http://localhost:8180/healthz && echo "validator: OK"
curl -sf http://localhost:8090/health  && echo "skills: OK"
curl -sf http://localhost:3000/        > /dev/null && echo "frontend: OK"
```

### Common issues

| Symptom | Fix |
|---------|-----|
| Validator exits 127 | Rebuild: `podman compose -f dev-compose.yml up -d --build validator` |
| Validator stuck "unhealthy" | Restart to reset health: `podman restart crew-validator-dev` |
| Skills list empty | Check logs for "Skills base dir does not exist" — verify `FRAPPE_SKILLS_DIR` in `.env` |
| Cache permission denied | `podman exec -u 0 crew-skills-dev chown -R 1001:0 /app/cache` then restart |
| Frontend proxy error | Backend must be healthy first — check `curl localhost:8080/health` |
| Backend slow to start | Embedding model download on first run — check `podman logs crew-backend-dev` |

---

## Local Mode (Bare-Metal)

Run services directly on the host without containers. Useful for debugging or when podman is unavailable.

### 1. Backend

```bash
cd opl-ai-software-team
export PYTHONPATH=$PWD/agent:$PWD/agent/src:$PWD
export CONFIG_FILE_PATH=$HOME/.crew-ai/config.yaml
export WORKSPACE_PATH=$PWD/workspace
export JOB_DB_PATH=$PWD/data/crew_jobs.db
export VALIDATOR_URL=http://localhost:8180
export SKILLS_SERVICE_URL=http://localhost:8090

mkdir -p workspace data
uvicorn crew_studio.asgi_app:app --host 0.0.0.0 --port 8080 --reload
```

### 2. Validator

```bash
cd crew-code-validator
export PYTHONPATH=$PWD/src
uvicorn crew_validator.app:create_app --factory --host 0.0.0.0 --port 8180 --reload
```

### 3. Skills Service

```bash
cd skills-service/src
export SKILLS_BASE_DIRS=../../opl-ai-software-team/skills,$HOME/personal/1frappe_ecosystem/frappe-apps-manager/.cursor/skills
export SKILLS_INDEX_CACHE_DIR=/tmp/skills-cache
uvicorn main:app --host 0.0.0.0 --port 8090 --reload
```

### 4. Frontend

```bash
cd opl-studio-ui
npm install
VITE_DEV_PROXY_TARGET=http://localhost:8080 npm run dev
```

### Stop local mode

Kill each process (Ctrl+C) or use:

```bash
pkill -f "uvicorn crew_studio"
pkill -f "uvicorn crew_validator"
pkill -f "uvicorn main:app.*8090"
pkill -f "vite"
```

---

## Quick Reference

| Action | Container Mode | Local Mode |
|--------|---------------|------------|
| Start core | `podman compose -f dev-compose.yml up -d --build backend validator skills-service frontend` | Start each service manually (see above) |
| Stop all | `podman compose -f dev-compose.yml down` | `pkill -f uvicorn; pkill -f vite` |
| Restart one | `podman compose -f dev-compose.yml restart <svc>` | Kill and re-run the process |
| Logs | `podman compose -f dev-compose.yml logs -f <svc>` | Terminal output directly |
| Status | `podman compose -f dev-compose.yml ps` | `curl` health endpoints |
| Clean reset | `podman compose -f dev-compose.yml down -v` | Delete `data/`, `workspace/`, `/tmp/skills-cache` |
