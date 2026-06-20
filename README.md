# OPL Crew Mono

Mono-repo that brings together the full OPL AI Crew platform as Git submodules with unified compose orchestration.

## Architecture

| Service | Description | Port | Source |
|---------|-------------|------|--------|
| **Backend** | FastAPI ASGI + AI Agents | 8080 | `opl-ai-software-team` |
| **Frontend** | React + PatternFly UI | 3000 | `opl-studio-ui` |
| **Validator** | Code validation microservice (FastAPI) | 8180 | `crew-code-validator` |
| **Skills** | Semantic skill search (FastAPI + LlamaIndex) | 8090 | `skills-service` |
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

Source-mounted backend and frontend; pulls base images (no image build step). **Core** stack is validator + backend + frontend. **Skills** and **Jira** are optional Compose profiles.

```bash
podman compose -f dev-compose.yml up -d
# Optional: add skills-service + skill-manager
podman compose -f dev-compose.yml --profile skills up -d
# Optional: add Jira + connector
podman compose -f dev-compose.yml --profile jira up -d
```

Or set `COMPOSE_PROFILES=skills,jira` in `.env`. Same with Docker: `docker compose -f dev-compose.yml ...`.

## Authentication

OPL Crew platform includes standard-compliant OpenID Connect (OIDC) authentication.

### Dev Mode (No authentication)
To run the developer stack without authentication, configure the following in your `.env`:
```env
AUTH_ENABLED=false
VITE_AUTH_ENABLED=false
```
When disabled, the services will bypass OIDC redirects and run with mock developer credentials automatically.

### Keycloak / OIDC Mode
By default, the stack runs with OIDC authentication enabled. The Keycloak service is managed via the unified compose stack and automatically imports a pre-seeded realm (`opl-crew`) on startup.

Key configurations for custom OIDC providers or production deployments:
- **Frontend Variables**:
  - `VITE_OIDC_AUTHORITY`: Authority URL of your identity provider.
  - `VITE_OIDC_CLIENT_ID`: Public client ID configured in the provider (defaults to `opl-studio`).
- **Backend Variables**:
  - `KEYCLOAK_ISSUER_URL`: Issuer verification string.
  - `KEYCLOAK_JWKS_URL`: JSON Web Key Set cert endpoint.
- **Jira Connector Variables**:
  - `KEYCLOAK_TOKEN_URL`: OIDC token endpoint.
  - `KEYCLOAK_CLIENT_ID`: Confidential client credentials for token exchange.
  - `KEYCLOAK_CLIENT_SECRET`: Client secret for token exchange.

## Compose Files

| File | Purpose |
|------|---------|
| `compose.yml` | **Production** — pre-built backend/frontend images, builds validator and connector |
| `dev-compose.yml` | **Development** — bind-mounted source, hot-reload; optional **`skills`** and **`jira`** profiles |

## Submodules

| Directory | Repository |
|-----------|------------|
| `opl-ai-software-team` | [varkrish/opl-ai-software-team](https://github.com/varkrish/opl-ai-software-team) |
| `opl-studio-ui` | [varkrish/opl-studio-ui](https://github.com/varkrish/opl-studio-ui) |
| `crew-code-validator` | [varkrish/crew-code-validator](https://github.com/varkrish/crew-code-validator) |
| `crew_jira_connector` | [varkrish/crew_jira_connector](https://github.com/varkrish/crew_jira_connector) |
| `skills-service` | [varkrish/skills-service](https://github.com/varkrish/skills-service) |

Dev compose under `opl-ai-software-team/` uses `SKILLS_SERVICE_DIR` (default `../skills-service`) so the build context points at this submodule checkout.

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
