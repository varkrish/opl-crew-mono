# Changelog — OPL Crew Mono

Platform-level release notes. Component details live in submodule changelogs.

## [Unreleased]

### Added
- Backend **Frappe / Spring Boot simple fast E2E** — stack-lock + layout assertions; Go/Java checks tightened (`opl-ai-software-team`).
- Backend **multi-language simple fast E2E** — Python, Java, Go, HTML, Node.js calculator fixtures (`opl-ai-software-team`).
- Backend **wiring contract / creation manifest** — language-neutral module identity, adaptive tiny-project manifests (`opl-ai-software-team`).

### Fixed
- Backend — **skills-first wiring** (skills authoritative for layout); ``SKILLS_SERVICE_URL`` prefetch fallback; negated vision tech ignored; exclusive skill-family gating; Frappe flat↔nested reconciliation (`opl-ai-software-team`).
- Backend — **auto-approve** honors plan/solution review skip; empty/island Python trees via wiring-contract harden; Python `src/`-layout import validation false positives.
- Frontend — Landing always sends capability profile; Approvals control labeled for solution + plan auto-approve (`opl-studio-ui`).
- Frontend — Files **Push to Git** no longer clipped beside the job selector; action row wraps with Push first (`opl-studio-ui`).
- Backend — on-demand GitHub push no longer false-succeeds; honors requested repo name and surfaces real git errors (`opl-ai-software-team`).
- Frontend — Push success copy notes private repo + Settings GitHub account (`opl-studio-ui`).
- Demo compose — Keycloak readiness probe + port-aware OIDC/CORS defaults; install `jq` in backend dev entrypoint when missing.

### Changed
- `.env.example` — document Keycloak issuer/authority when using non-default `KEYCLOAK_PORT`.

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
