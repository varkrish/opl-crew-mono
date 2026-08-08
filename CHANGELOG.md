# Changelog — OPL Crew Mono

Platform-level release notes. Component details live in submodule changelogs.

## [Unreleased]

### Platform
- **Runtime code execution** — generated code can now be *run*, not just statically checked, via the standalone [Sandbox API](https://github.com/varkrish/podman-sandbox-api2). Opt in with `SMOKE_TEST_BACKEND=sandbox_api`; the default stays `syntax_only`
- Compose wires `SANDBOX_API_URL` (default `http://host.docker.internal:18080`) and `extra_hosts: host-gateway` so the backend reaches a Sandbox API running on the host — it drives the podman CLI directly and so is not a compose service
- Sandbox usage/security `SKILL.md`s can be indexed by setting `SANDBOX_SKILLS_DIR`
- **Installer writes `./config.yaml` next to compose.yml** (plus `~/.crew-ai` copy) so Podman/Docker never turn a missing mount into an empty directory
- Compose default `CONFIG_FILE` is `./config.yaml`; backend entrypoint fails clearly if the mount is not a file
- Empty LLM API key is rejected at install time; stale directory traps are removed before start

### Backend
- Execute generated code in a sandbox during validation and as a `sandbox_execute` agent tool
- Live preview endpoints (`/api/jobs/<id>/live-preview`) run the generated app and return a URL
- Runtime/build failures now reach the per-file fix loop instead of ending as `completed_with_errors` with the broken code untouched; the loop no longer stops while it is still making progress
- Fix an arbitrary file read on `/api/workspace/files/<path>`
- Reject `POST /api/jobs` with `llm_not_configured` when no BYOK or server key; add `GET /api/llm/status`

### Frontend
- Live preview panel on the job page (start/stop the app, open its URL)
- `completed_with_errors` is a first-class status: result panel, **View build output** link, Dashboard filter, restart
- Build page surfaces missing LLM credentials and blocks submit until configured

## [2026.07.16] — v2.5.0

### Backend (`opl-ai-software-team` → **v2.5.0**)
- Module integrity & code quality (wiring contracts, module identity, stack lock, multi-lang E2E)
- Configurable workflows (`workflow_resolver`, TDD QA, feature-by-feature, auto-approve)
- Skill preferences (skills-first layout, family gating, `SKILLS_SERVICE_URL` prefetch)

See [opl-ai-software-team/CHANGELOG.md](./opl-ai-software-team/CHANGELOG.md).

### Frontend (`opl-studio-ui` → **v2.5.0**)
- Workflow settings + capability profile / auto-approve UX
- Files Push to Git fixes

See [opl-studio-ui/CHANGELOG.md](./opl-studio-ui/CHANGELOG.md).

### Platform
- Keycloak readiness / port-aware OIDC defaults; GitHub push reliability

### Deploy

```bash
export APP_VERSION=v2.5.0
git submodule update --init --recursive
podman compose -f compose.yml pull
podman compose -f compose.yml up -d
```

Images:
- `ghcr.io/varkrish/crew-backend:v2.5.0`
- `ghcr.io/varkrish/crew-frontend:v2.5.0`
- `quay.io/varkrish/crew-validator:latest`
- `quay.io/varkrish/skills-service:latest`
- `quay.io/varkrish/skill-manager:latest`

## [2026.07.13] — v2.4.6

### Added
- Backend **workflow_resolver** — YAML + smart_router pipeline resolution; plan-approve resumes at `qa` on full/TDD paths; feature-by-feature dev when PO is in pipeline (`opl-ai-software-team` @ `2ed3dd4`).

### Changed
- **Container images** — `compose.yml` backend and frontend default to GHCR (`ghcr.io/varkrish/crew-backend`, `crew-frontend`); validator, skills, skill-manager, and Jira connector remain on Quay.

### Fixed
- Backend **LLM 429 rate-limit resilience** — exponential backoff with `Retry-After` and provider reset timestamps (`opl-ai-software-team` @ `2ed3dd4`).
- Backend **v2.4.5** — manifest derivation from approved solution spec (Redis/Postgres unlocks database tier).
- Backend **v2.4.2** (path-like component matching) / **v2.4.1** — technology-agnostic stack_manifest tier unlock.

### Deploy

```bash
git submodule update --init --recursive
podman compose -f compose.yml pull
podman compose -f compose.yml up -d
```

Images:
- `ghcr.io/varkrish/crew-backend:latest`
- `ghcr.io/varkrish/crew-frontend:latest`
- `quay.io/varkrish/crew-validator:latest`
- `quay.io/varkrish/skills-service:latest`
- `quay.io/varkrish/skill-manager:latest`

## [2026.07.13] — v2.4.0

### Backend (`opl-ai-software-team` → **v2.4.0**)

- Pipeline-based `fast` / `adaptive` / `full` phase routing
- `capability_profile` accepts string or dict; Auto uses vision inference
- Fast-mode seed registers file tasks + hardened unicode tree prompt
- Native FastAPI validation report endpoint

See [opl-ai-software-team/CHANGELOG.md](./opl-ai-software-team/CHANGELOG.md).

### Frontend (`opl-studio-ui` → **v2.4.0**)

- Capability profile dropdown on job create (Auto / Fast / Full)
- Validation report panel uses authenticated API client

### Deploy

```bash
export APP_VERSION=v2.4.0
git submodule update --init --recursive
podman compose pull backend frontend
podman compose up -d
```

Images:
- `quay.io/varkrish/crew-backend:v2.4.0`
- `quay.io/varkrish/crew-frontend:v2.4.0`

## [2026.07.12] — Backend v2.2.0

### Backend (`opl-ai-software-team` → **v2.2.0**)

Production release focused on **approved-solution fidelity** and **reliable tech-stack scaffolding**:

- Tech Architect 3-pass pipeline with file-level tree validation
- Approved `solution_spec.md` binding through development
- BYOK / Settings → LLM resolution for jobs and isolated tests
- Solutioning and dev-phase stability fixes (chat reset, 503 retry)

See [opl-ai-software-team/CHANGELOG.md](./opl-ai-software-team/CHANGELOG.md) and [RELEASE.md](./opl-ai-software-team/RELEASE.md).

### Deploy

```bash
git submodule update --init --recursive
cd opl-ai-software-team && git checkout v2.2.0
podman compose pull backend
podman compose up -d backend
```

Image: `quay.io/varkrish/crew-backend:v2.2.0`
