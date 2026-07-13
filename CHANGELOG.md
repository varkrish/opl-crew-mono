# Changelog — OPL Crew Mono

Platform-level release notes. Component details live in submodule changelogs.

## [Unreleased]

### Added
- Backend **workflow_resolver** — YAML + smart_router pipeline resolution; plan-approve resumes at `qa` on full/TDD paths; feature-by-feature dev when PO is in pipeline (`opl-ai-software-team`).

### Changed
- **Container images** — `compose.yml` defaults switched from Quay to GHCR (`ghcr.io/varkrish/*`); GitHub Actions workflows publish to GHCR instead of Quay.

### Fixed
- Backend **LLM 429 rate-limit resilience** — exponential backoff with `Retry-After` and provider reset timestamps (`opl-ai-software-team` @ `4abdc36`).
- Backend **v2.4.5** — manifest derivation from approved solution spec (Redis/Postgres unlocks database tier).
- Backend **v2.4.2** (path-like component matching) / **v2.4.1** — technology-agnostic stack_manifest tier unlock (chosen_stack no longer conflicts with forbidden_tiers).

### Changed
- **Community compose** — `compose.yml` defaults backend/frontend images to `:latest`; docs/header describe whole-stack quick start for installer + clone users. CORS defaults include `http://localhost:3100`.

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
