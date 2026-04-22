# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

**OPL Crew Mono** is a monorepo orchestrating an AI-powered software development platform. It uses multi-agent collaboration (MetaAgent, ProductOwner, TechArchitect, Developer, DevOps) to generate complete application projects from natural language descriptions.

## Architecture

```
opl_ai_mono/
├── opl-ai-software-team/   # Backend: FastAPI + LlamaIndex agents (submodule)
├── opl-studio-ui/           # Frontend: React + PatternFly + Vite (submodule)
├── crew-code-validator/     # Validator: FastAPI code validation (submodule)
├── skills-service/          # Skills: semantic search over skill docs (submodule)
├── crew_jira_connector/     # Jira webhook bridge (submodule)
├── helm/                    # Helm charts for OpenShift/K8s deployment
├── compose.yml              # Production compose (pre-built images)
├── dev-compose.yml          # Dev compose (source-mounted, hot-reload)
└── .env.example             # Environment variable template
```

All subdirectories are Git submodules. After cloning:

```bash
git submodule update --init --recursive
```

## Service Management

### Container Mode (default — podman or docker)

All commands from the mono repo root.

**Start core services:**

```bash
podman compose -f dev-compose.yml up -d --build backend validator skills-service frontend
```

**Start all services (including Jira):**

```bash
podman compose -f dev-compose.yml up -d --build
```

**Stop:**

```bash
podman compose -f dev-compose.yml down
```

**Stop and wipe volumes:**

```bash
podman compose -f dev-compose.yml down -v
```

**Restart a single service:**

```bash
podman compose -f dev-compose.yml restart backend
```

**Rebuild and restart a single service:**

```bash
podman compose -f dev-compose.yml up -d --build backend
```

**Logs:**

```bash
podman compose -f dev-compose.yml logs -f backend
```

**Status:**

```bash
podman compose -f dev-compose.yml ps
```

### Local Mode (bare-metal, no containers)

#### Backend

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

#### Validator

```bash
cd crew-code-validator
PYTHONPATH=$PWD/src uvicorn crew_validator.app:create_app --factory --host 0.0.0.0 --port 8180 --reload
```

#### Skills Service

```bash
cd skills-service/src
SKILLS_BASE_DIRS=../../opl-ai-software-team/skills,/path/to/frappe/skills \
SKILLS_INDEX_CACHE_DIR=/tmp/skills-cache \
uvicorn main:app --host 0.0.0.0 --port 8090 --reload
```

#### Frontend

```bash
cd opl-studio-ui
npm install
VITE_DEV_PROXY_TARGET=http://localhost:8080 npm run dev
```

#### Stop local mode

```bash
pkill -f "uvicorn crew_studio"
pkill -f "uvicorn crew_validator"
pkill -f "uvicorn main:app.*8090"
pkill -f "vite"
```

### Service Ports and Health

| Service | Port | Health |
|---------|------|--------|
| Backend | 8080 | `curl localhost:8080/health` |
| Frontend | 3000 | `curl localhost:3000/` |
| Validator | 8180 | `curl localhost:8180/healthz` |
| Skills | 8090 | `curl localhost:8090/health` |
| Jira | 8081 | — |
| Jira Connector | 8082 | — |

### Troubleshooting

| Issue | Fix |
|-------|-----|
| Skills list empty | Check `FRAPPE_SKILLS_DIR` in `.env` points to a valid skills directory |
| Cache permission denied in skills | `podman exec -u 0 crew-skills-dev chown -R 1001:0 /app/cache` |
| Validator unhealthy | `podman restart crew-validator-dev` (resets health state) |
| Frontend proxy 502 | Backend must be healthy first |

## Key Configuration

- **LLM config**: `~/.crew-ai/config.yaml` — model selection, API keys, tools
- **Env vars**: `.env` — ports, directories, API keys
- **Agent skills**: `opl-ai-software-team/skills/` + external Frappe skills via `FRAPPE_SKILLS_DIR`

## Common Development Tasks

### Submit a job

```bash
curl -X POST http://localhost:8080/api/jobs \
  -H "Content-Type: application/json" \
  -d '{"vision": "Build a Frappe app for invoicing"}'
```

### Query skills

```bash
curl -X POST http://localhost:8090/query \
  -H "Content-Type: application/json" \
  -d '{"query": "Frappe Containerfile", "top_k": 3}'
```

### Reload skills index

```bash
curl -X POST http://localhost:8090/reload
```

## Code Conventions

- **Backend**: Python 3.11, FastAPI (async), LlamaIndex for agents
- **Frontend**: TypeScript, React 18, PatternFly 5, Vite
- **Tests**: pytest (backend), Cypress (frontend)
- **Containers**: Red Hat UBI9 base images, multi-stage builds
- **Compose**: `podman compose` preferred, `docker compose` compatible
