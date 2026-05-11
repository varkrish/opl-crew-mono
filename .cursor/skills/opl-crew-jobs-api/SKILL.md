---
name: opl-crew-jobs-api
description: >-
  Create and monitor OPL Crew jobs via HTTP: POST /api/jobs, modes (build,
  import, migration, refactor), import analyze + refinement for existing code,
  GET job status, scripts, CORS. Use for submitting jobs, curl smoke tests,
  or automating job creation.
---

# OPL Crew — Jobs API

Backend base URL defaults to **`http://localhost:8080`** in local dev (FastAPI + Flask fallback when `MOUNT_FLASK_FALLBACK=1`).

**Multipart `POST /api/jobs`** is handled by **forwarding the raw body to Flask** inside the FastAPI app so ZIP extract, GitHub clone, and document uploads stay identical to `llamaindex_web_app.create_job`. **`POST /api/jobs/{id}/analyze`** and other un-ported routes are served by the mounted Flask app. Confirm `import_flow` is registered (`import_bp`) if import analyze returns 404.

## Preconditions

- Backend healthy: `curl -sf http://localhost:8080/health`
- See **opl-dev-services** to start the stack (`dev-compose.yml`).

## Understanding `mode: build` (JSON API)

**Greenfield only:** `mode: "build"` runs `run_build_pipeline` and **generates a new project** from `vision`. It does **not** attach an existing tree from disk.

**JSON `POST /api/jobs` (FastAPI)** only uses `vision`, `mode`, `backend`, `metadata`. It **ignores** `github_urls`—no repo attach via JSON.

**Flask `build` + `github_urls`:** Repomix packs repos as **reference** text in the vision; output is still a **new** codebase, not in-place edits.

## Refactor vs import (where new work lands)

| Flow | What it does | Workspace layout |
|------|----------------|------------------|
| **Import & iterate** (`mode=import`) | Analyzes the tree you attached, then **Refine edits that same tree** in place. | Source lives at the job workspace root; refinement patches those files. |
| **Refactor** (`mode=refactor`) | Architect + executor pipeline toward a **`target_stack`**; **does not** replace the imported tree in place — new generated work is kept **alongside** the original (e.g. under `refactored/`); the legacy tree stays for comparison. | Parallel trees; original preserved. |

Use **import** when you want iteration on the codebase you uploaded. Use **refactor** when you want a **target-stack migration** artifact tree next to the source.

## Import & iterate (existing code → analyze → Refine / file edits)

Use this for **real projects already on disk** when the product path is **import analysis + chat refinement** (not the separate refactor architect pipeline).

1. **Multipart** `POST /api/jobs` with:
   - `mode=import`
   - `vision=` (optional; default can be `[Import] Existing codebase`)
   - `source_archive=@project.zip` and/or form field `github_urls` (clone into workspace)  
   Flask validates that at least one of ZIP or clone produced files; sets `metadata.job_mode=import`, `current_phase=awaiting_import`.

2. **Start analysis** (tech stack + file index):
   ```bash
   curl -sS -X POST "http://localhost:8080/api/jobs/${JOB_ID}/analyze"
   ```
   Returns 202; job moves through `import_analyzing`, then completes per runner.

3. **Edit files** via **Refine** in the UI (or refinement API). Import jobs use the enhanced refinement path when `job_mode` is `import`.

Helper: `./scripts/submit-import-with-source.sh` (set `SOURCE_ZIP` and/or `GITHUB_URL`).

## Refactor (target-stack migration pipeline)

**Different workflow:** architect + executor refactor toward an explicit **`target_stack`** (not the same as Import & Iterate).

1. Multipart `POST /api/jobs` with `mode=refactor`, `source_archive` and/or `github_urls` → `awaiting_refactor`.

2. `POST /api/jobs/${JOB_ID}/refactor` with JSON body **`{"target_stack": "..."}`** (required).

Helper: `./scripts/submit-refactor-with-source.sh`

## Create a build job (JSON) — example

```bash
curl -sS -X POST http://localhost:8080/api/jobs \
  -H 'Content-Type: application/json' \
  -d '{
    "vision": "Build a minimal REST API in Python with FastAPI and health endpoint",
    "mode": "build",
    "backend": "opl-ai-team"
  }'
```

`opl-ai-team` is the default backend **name** in the API.

## Get job status

```bash
JOB_ID="<uuid-from-create-response>"
curl -sS "http://localhost:8080/api/jobs/${JOB_ID}" | python3 -m json.tool
```

## List jobs (paginated)

```bash
curl -sS "http://localhost:8080/api/jobs?page=1&page_size=10"
```

## Modes (conceptual)

| `mode` | Typical use |
|--------|----------------|
| `build` | New project from `vision` (greenfield). |
| `import` | Existing ZIP/Git clone → **`/analyze`** → Refine / file edits. |
| `migration` | MTA + Java migration workflow. |
| `refactor` | Architect/executor toward **`target_stack`** via **`/refactor`**. |

JSON `POST /api/jobs` with `"mode": "import"` creates a queued import job **without** a ZIP (files must still come from multipart or you attach source another way). In practice use **multipart** for `import` with `source_archive` and/or `github_urls`.

## Sample scripts (mono repo)

- `./scripts/submit-java-small-project-update-job.sh` — greenfield `build` example.
- `./scripts/submit-import-with-source.sh` — **import** + instructions for `/analyze`.
- `./scripts/submit-refactor-with-source.sh` — refactor + `/refactor`.

Optional: `export CREW_API_URL=https://your-api.example.com`

## Split UI / CORS

If the browser calls the API from another origin, set **`CORS_ALLOWED_ORIGINS`**. Build the UI with **`VITE_API_URL`** when split. See **CLAUDE.md** and **opl-studio-ui** README.

## Related

- **opl-dev-services** — ports, compose, health checks.
- **opl-crew-testing** — pytest and contract tests including CORS.
