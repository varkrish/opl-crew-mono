# OPL Crew Mono

Mono-repo that brings together the full OPL AI Crew platform as Git submodules with unified compose orchestration.

## Architecture

| Service | Description | Port | Source |
|---------|-------------|------|--------|
| **Backend** | Flask API + CrewAI agents | 8080 | `opl-ai-software-team` |
| **Frontend** | React + PatternFly UI | 3000 | `opl-ai-software-team` |
| **Validator** | Code validation microservice (FastAPI) | 8180 | `crew-code-validator` |
| **Jira** | Atlassian Jira Server | 8081 | Docker image |
| **Connector** | Jira-to-Crew webhook bridge | 8082 | `crew_jira_connector` |

## Quick Start

### 1. Clone with submodules

```bash
git clone --recurse-submodules https://github.com/varkrish/opl-crew-mono.git
cd opl-crew-mono
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

### 2. Configure environment

```bash
cp .env.example .env
# Edit .env with your API keys and settings
```

### 3. Run (Production)

Uses pre-built images from `quay.io` for backend and frontend; builds validator and connector from source.

```bash
podman compose up -d
# or
docker compose up -d
```

### 4. Run (Development)

Builds all services from source with hot-reload for frontend and source-mounted backend.

```bash
podman compose -f dev-compose.yml up -d --build
# or
docker compose -f dev-compose.yml up -d --build
```

## Compose Files

| File | Purpose |
|------|---------|
| `compose.yml` | **Production** — pre-built backend/frontend images, builds validator and connector |
| `dev-compose.yml` | **Development** — builds everything from source, hot-reload enabled |

## Submodules

| Directory | Repository |
|-----------|------------|
| `opl-ai-software-team` | [varkrish/opl-ai-software-team](https://github.com/varkrish/opl-ai-software-team) |
| `crew-code-validator` | [varkrish/crew-code-validator](https://github.com/varkrish/crew-code-validator) |
| `crew_jira_connector` | [varkrish/crew_jira_connector](https://github.com/varkrish/crew_jira_connector) |

## Updating Submodules

Pull the latest changes from all submodules:

```bash
git submodule update --remote --merge
```

## Useful Commands

```bash
# View logs for a specific service
podman compose logs -f backend

# Rebuild and restart a single service
podman compose up -d --build validator

# Stop everything and remove volumes
podman compose down -v

# Check service health
podman compose ps
```
