# OPL Crew Mono

AI-powered software development platform. Multi-agent crew (MetaAgent, ProductOwner, TechArchitect, Developer, DevOps) generates complete application projects from a natural language description.

## Architecture

| Service | Description | Port |
|---------|-------------|------|
| **Backend** | FastAPI ASGI + AI Agents | 8080 |
| **Frontend** | React + PatternFly UI | 3000 |
| **Validator** | Code validation microservice | 8181 |
| **Skills** | Semantic skill search _(optional)_ | 8090 |
| **Jira** | Atlassian Jira Server _(optional)_ | 8081 |
| **Connector** | Jira-to-Crew webhook bridge _(optional)_ | 8082 |

---

## Production Install

### Option A — One-line install (no git clone needed)

Requires: `curl`, `podman ≥ 4.0`

```bash
curl -fsSL https://raw.githubusercontent.com/varkrish/opl-crew-mono/main/installer.sh | bash
```

Or download and run locally:

```bash
curl -fsSL https://raw.githubusercontent.com/varkrish/opl-crew-mono/main/installer.sh -o installer.sh
chmod +x installer.sh
./installer.sh
```

The installer will:
1. Download `compose.yml` from this repo
2. Prompt for your LLM API key, base URL, and agent models
3. Write `~/.crew-ai/config.yaml` (permissions `600`) and a local `.env`
4. Pull all pre-built images from `quay.io`
5. Start the stack and open `http://localhost:3000`

**What it asks:**

| Prompt | Default |
|--------|---------|
| LLM API Key | _(required)_ |
| LLM Base URL | `https://litellm-prod.apps.maas.redhatworkshops.io` |
| Manager model | `deepseek-r1-distill-qwen-14b` |
| Worker model | `qwen3-14b` |
| Reviewer model | `qwen3-14b` |

**Installer flags:**

```bash
./installer.sh --yes    # re-use existing .env, no prompts
./installer.sh --force  # re-pull images even if already present
./installer.sh --help
```

**Update to latest images:**

```bash
./installer.sh --force --yes
```

> Works on **macOS** (bash 3.2+) and **Linux** (Fedora, Ubuntu, RHEL).  
> Pipe-install (`curl | bash`) is supported — all prompts read from `/dev/tty`.

---

### Option B — Manual setup from clone

```bash
git clone --recurse-submodules https://github.com/varkrish/opl-crew-mono.git
cd opl-crew-mono
```

Copy and edit the environment file:

```bash
cp .env.example .env
# Fill in LLM_API_KEY, LLM_API_BASE_URL, and model names
```

Write backend config (adjust models as needed):

```bash
mkdir -p ~/.crew-ai && chmod 700 ~/.crew-ai
cat > ~/.crew-ai/config.yaml <<'EOF'
llm:
  api_key: "YOUR_API_KEY"
  api_base_url: "https://litellm-prod.apps.maas.redhatworkshops.io"
  environment: "production"
  model_manager: "deepseek-r1-distill-qwen-14b"
  model_worker: "qwen3-14b"
  model_reviewer: "qwen3-14b"
  max_tokens: 8192
  temperature: 0.7
budget:
  max_cost_per_project: 100.0
EOF
chmod 600 ~/.crew-ai/config.yaml
```

Add to `.env`:

```env
CONFIG_FILE=~/.crew-ai/config.yaml
AUTH_ENABLED=false
HF_HOME=/tmp/hf
```

Start the stack:

```bash
podman compose -f compose.yml up -d validator backend frontend
```

---

## Development Setup

Source-mounted services with hot-reload:

```bash
# Core stack (backend + frontend + validator)
podman compose -f dev-compose.yml up -d

# Add skills service
podman compose -f dev-compose.yml --profile skills up -d

# Add Jira + connector
podman compose -f dev-compose.yml --profile jira up -d

# All optional profiles
COMPOSE_PROFILES=skills,jira podman compose -f dev-compose.yml up -d
```

---

## Authentication

### No-auth mode (demo / dev)

```env
AUTH_ENABLED=false
```

When disabled, services bypass OIDC and use mock credentials automatically.

### Keycloak / OIDC

The stack includes Keycloak with a pre-seeded `opl-crew` realm. For external OIDC providers:

| Variable | Where | Purpose |
|----------|-------|---------|
| `VITE_OIDC_AUTHORITY` | Frontend | Identity provider authority URL |
| `VITE_OIDC_CLIENT_ID` | Frontend | Public client ID (default: `opl-studio`) |
| `KEYCLOAK_ISSUER_URL` | Backend | Issuer URL for JWT verification |
| `KEYCLOAK_JWKS_URL` | Backend | JWKS cert endpoint |

---

## Service Health

```bash
curl localhost:8080/health    # Backend
curl localhost:8181/healthz   # Validator
curl localhost:3000/          # Frontend
```

---

## Common Commands

```bash
# Submit a test job (auth disabled)
curl -X POST http://localhost:8080/api/jobs \
  -H "Content-Type: application/json" \
  -d '{"vision": "Build a simple calculator API"}'

# Follow backend logs
podman logs -f crew-backend

# Restart a single service
podman compose -f compose.yml restart backend

# Stop everything
podman compose -f compose.yml down

# Stop and remove volumes (full reset)
podman compose -f compose.yml down -v
```

---

## Compose Files

| File | Purpose |
|------|---------|
| `compose.yml` | **Production** — all pre-built images, no local build |
| `dev-compose.yml` | **Development** — source-mounted, hot-reload, optional profiles |

---

## Submodules

| Directory | Repository |
|-----------|------------|
| `opl-ai-software-team` | [varkrish/opl-ai-software-team](https://github.com/varkrish/opl-ai-software-team) |
| `opl-studio-ui` | [varkrish/opl-studio-ui](https://github.com/varkrish/opl-studio-ui) |
| `crew-code-validator` | [varkrish/crew-code-validator](https://github.com/varkrish/crew-code-validator) |
| `crew_jira_connector` | [varkrish/crew_jira_connector](https://github.com/varkrish/crew_jira_connector) |
| `skills-service` | [varkrish/skills-service](https://github.com/varkrish/skills-service) |

Update all submodules to latest:

```bash
git submodule update --remote --merge
```

---

## UI Settings

Configure workflow behaviour from the Studio UI (Settings menu):

| Tab | What it configures |
|-----|--------------------|
| **Workflow** | Plan review gate, solutioning loop, auto-approve |
| **GitHub** | PAT for solutioning research |
| **API Configuration** | Per-user LLM provider and models |
| **Jira** | Jira credentials for issue integration |
