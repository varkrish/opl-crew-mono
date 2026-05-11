---
name: opl-crew-testing
description: >-
  Run tests for the OPL Crew platform: backend pytest (agent + root tests),
  CORS/async API contract tests, refinement tests, validator, and opl-studio-ui
  Cypress. Use when the user asks to run tests, verify CI locally, TDD, pytest,
  coverage, component tests, or frontend E2E.
---

# OPL Crew — Testing

All paths are relative to the **mono repo root** (`opl_ai_mono/`) unless noted. Submodules must be initialized: `git submodule update --init --recursive`.

## Backend (`opl-ai-software-team/`)

Install test deps once (matches CI `ci-install`):

```bash
cd opl-ai-software-team
make ci-install
```

### Quick unit tests (agent framework)

```bash
cd opl-ai-software-team && make test-quick
```

Runs `agent/tests/unit/` with a 60s timeout per test.

### Unit + API tests with coverage

```bash
cd opl-ai-software-team && make test-coverage
```

Runs `agent/tests/unit/` and `agent/tests/api/`; writes `coverage.xml` and `htmlcov/` at repo root.

### API tests only (Flask-linked `crew_studio`)

```bash
cd opl-ai-software-team && make backend-test-api
```

Uses the symlink `agent/src/llamaindex_crew/web` → `crew_studio` and runs `agent/tests/api/`.

### Root-level API tests (FastAPI ASGI, no server)

Some tests live under **`opl-ai-software-team/tests/api/`** (e.g. `test_cors.py`, `test_async_api_contract.py`). Run from the **backend submodule root** with project `PYTHONPATH`:

```bash
cd opl-ai-software-team
export PYTHONPATH=$PWD:$PWD/agent:$PWD/agent/src
python -m pytest tests/api/test_cors.py tests/api/test_async_api_contract.py -v --timeout=30
```

### E2E (slow, needs LLM / resources)

```bash
cd opl-ai-software-team && make backend-test-e2e
```

Optional env: `OPENROUTER_API_KEY`, `BUDGET_MAX_COST_PER_PROJECT`. Quick smoke:

```bash
cd opl-ai-software-team && make backend-test-e2e-quick
```

### Refinement tests

```bash
cd opl-ai-software-team && make refine-test
cd opl-ai-software-team && make refine-test-e2e   # slow
```

### Agent-wide tests

```bash
cd opl-ai-software-team && make agent-test
```

## Validator (`crew-code-validator/`)

With venv and `PYTHONPATH`:

```bash
cd crew-code-validator
PYTHONPATH=$PWD/src pytest -q
```

## Frontend (`opl-studio-ui/` submodule)

```bash
cd opl-studio-ui
npm ci
npm run build
npx tsc --noEmit
npm run cy:component
# E2E needs dev server + backend:
# npm run cy:e2e
```

## Live stack smoke (optional)

After `podman compose -f dev-compose.yml up -d` (see **opl-dev-services**):

```bash
curl -sf http://localhost:8080/health
curl -sf http://localhost:8180/healthz
curl -sf http://localhost:3000/ >/dev/null
```

## Related

- **opl-dev-services** — start/stop local or container env before E2E or Cypress E2E.
- **opl-crew-jobs-api** — submit jobs via HTTP for manual or scripted checks.
