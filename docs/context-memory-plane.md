# Context Memory Plane (P3) — Setup and Operations

The context memory plane gives OPL Crew cross-job memory. Job outcomes, Jira
issue context, and reference-doc summaries are written at lifecycle hooks;
relevant past context is recalled at the start of solutioning. A new job on a
domain starts with what earlier jobs learned instead of re-deriving it.

Backed by [MemMachine](https://github.com/MemMachine/MemMachine) (episodic +
semantic memory over Postgres/pgvector and Neo4j).

**Everything is fail-open.** With the plane disabled, the server unreachable, or
`memmachine-client` not installed, every integration point degrades to a no-op
and jobs run exactly as they do today. There is no "memory unavailable" error
path to handle.

---

## Quick start (local dev)

```bash
# 1. Start the memory stack (3 containers, opt-in profile)
podman compose -f dev-compose.yml --profile memory up -d

# 2. Wait for health, then confirm the API is up
curl http://localhost:8280/api/v2/health

# 3. Enable the backend side — add to .env
echo "MEMORY_ENABLED=true" >> .env
podman compose -f dev-compose.yml up -d backend

# 4. Confirm it connected
podman logs crew-backend-dev 2>&1 | grep -i "context memory"
#   → "Context memory ready — org=… project=… domain=…"
```

Run two jobs in the same domain. The second should log
`Injected N chars of recalled context into solutioning`.

### Ports

Host ports were chosen to avoid what is already in use (8080 backend, 8180
Keycloak, 8081 Jira, 8082 connector):

| Service | Host | Container |
|---|---|---|
| `memmachine-app` | 8280 | 8080 |
| `memmachine-postgres` | 55432 | 5432 |
| `memmachine-neo4j` | 7474 / 7687 | 7474 / 7687 |

> MemMachine's own compose defaults to host 8080 and the roadmap said 8180 —
> both collide here. Override with `MEMMACHINE_PORT` if 8280 is taken.

---

## Prerequisite you will hit: embeddings

MemMachine runs **its own** embedder and LLM for semantic indexing, separate
from the OPL agents. It needs a working `/v1/embeddings` endpoint.

Not every OpenAI-compatible gateway serves one. The MaaS LiteLLM proxy used for
chat may not. If long-term memory writes fail with 404s on `/embeddings`, point
MemMachine at something that does, while leaving the agents where they are:

```bash
# Option A — OpenAI directly for embeddings only
MEMMACHINE_LLM_BASE_URL=https://api.openai.com/v1
MEMMACHINE_LLM_API_KEY=sk-…
MEMMACHINE_EMBED_MODEL=text-embedding-3-small
MEMMACHINE_EMBED_DIMENSIONS=1536

# Option B — local Ollama, no external calls
MEMMACHINE_LLM_BASE_URL=http://host.docker.internal:11434/v1
MEMMACHINE_LLM_API_KEY=EMPTY
MEMMACHINE_EMBED_MODEL=nomic-embed-text
MEMMACHINE_EMBED_DIMENSIONS=768
```

Changing `MEMMACHINE_EMBED_DIMENSIONS` after data exists invalidates the vector
index — pick one and stay on it, or wipe the volumes.

### How configuration.yml is produced

`memmachine-app` requires a mounted `configuration.yml`. Committing one would
mean committing an API key, so:

1. `memmachine/configuration.template.yml` (committed) holds the structure with
   `__PLACEHOLDER__` markers.
2. The `memmachine-config` init container renders it into a volume at startup,
   substituting from the environment.
3. `memmachine-app` copies it to `/app/configuration.yml` before starting.

To change the memory topology, edit the template and restart the profile. Never
put real secrets in the template.

---

## Scope model

MemMachine 0.3.x has only two first-class hierarchy levels, so the four-level
scoping maps like this:

| Concept | Where it lives | Source |
|---|---|---|
| Customer | `org_id` (first-class) | `jobs.team_id`, else `jobs.owner_id` |
| Framework | `project_id` (first-class) | `stack_manifest.json` → `tech_stack.md` |
| Domain | `group_id` in instance metadata | `jobs.metadata.domain`, else Jira project key |
| Storing agent | episode `producer` field | hook name |

Instance metadata is turned into an **automatic search filter** by the client, so
only scope keys go there. Per-episode facts (`job_id`, `type`, status) are passed
per-write instead — putting `job_id` in instance metadata would scope every
recall to a single job and silently defeat the whole plane.

### Two projects, not one

| Project | Holds | Why |
|---|---|---|
| `<framework>` e.g. `frappe-15` | Job outcomes | Written after the stack is known |
| `shared-context` | Jira context, reference docs | Written *before* a stack is chosen |

A Jira issue describes *what* to build, not which framework. Filing pre-build
memories under a framework would either strand them beneath
`unknown-framework`, where later framework-scoped reads never look, or split one
domain's history across two projects. Recall queries **both** projects and
merges, deduplicating by content.

### Isolation

Customer and framework isolation is enforced by `org_id`/`project_id` at the
server, and domain by the auto-filter. This is asserted in
`agent/tests/unit/test_context_memory.py::TestScopeIsolation`, not assumed — the
commercial claim depends on a Spring Boot memory never surfacing in a Frappe job.

### Scope fragmentation is the failure mode to watch

If the framework or domain resolves differently between the write and a later
read, the memory exists but can never be recalled. Mitigations in place:

- All scope values pass through `slugify()`, so `Frappe 15`, `frappe-15`, and
  `FRAPPE  15` collapse to one slug.
- `metadata.domain` is authoritative once set, and is never guessed from vision
  text — an unstable guess fragments recall worse than one shared bucket.

**Open item:** domain currently comes from the Jira project key or falls back to
`general`. Jobs created in the UI without Jira all land in `general`. If domain
separation matters for UI-created jobs, add an explicit domain selector at job
creation and persist it to `jobs.metadata.domain`.

---

## What gets written, and where from

| Memory | Written at | Project | LLM used |
|---|---|---|---|
| `job_outcome` | `run_job_async` terminal status (`llamaindex_web_app.py`) | framework | yes (cheap tier) |
| `reference_doc` | `_save_uploaded_files` | shared | yes (cheap tier) |
| `jira_context` / `jira_epic` | job creation, when `jira_*` metadata present | shared | no (deterministic) |

### Why the post-job hook is not in the workflow

`software_dev_workflow.run()` has five completion/pause exits plus separate epic
and retry completion paths — hooking there would mean five hooks. `run_job_async`
is the single funnel where pauses are already filtered out and terminal status is
decided, so one call site covers build, epic, and retry modes.

### Why Jira memory is written by the backend, not the connector

The connector does not know the job's `owner_id`, so a connector-side write would
land under a different org scope than everything else about the same job —
memories that exist but can never be recalled. The connector's contribution is
the `jira_*` metadata it sends with `create_job`; the backend owns the write.

### No confidence score required

The roadmap coupled the job outcome summary to a confidence score (Phase 3).
That coupling was unnecessary — the summary is built from signals that already
exist and are already persisted: final status, `validation_report.json`, task
validation, `refinements`, `llm_usage`, solutioning pass stats, and
`skill_prefetch.json`. When Phase 3 lands, `confidence_score` is added to the
metadata block; the write point and summary shape do not change.

> The roadmap also cited `artifact_assertions.py` as the artifact-quality source.
> That module is dead code — zero importers, returns error strings rather than
> counts, and does not run during a job. `validation_report.json` is used instead.

### Summaries always exist

Each summary builder tries a cheap LLM call and falls back to a deterministic
template on failure. A template summary still carries framework, status, and
failure counts. Losing the summary because a utility model timed out would be
worse than a plain one. Point `memory.summary_agent_type` at your smallest model
(or `none` to skip LLM summaries entirely).

---

## Seeding history from Jira

The webhook only records issues that arrive after the plane goes live. Backfill
closed issues so recall is useful immediately:

```bash
cd opl-ai-software-team

# Dry run first — always. Writes nothing.
python scripts/seed_jira_memories.py --projects ASSET,BILLING --dry-run

# Then for real
python scripts/seed_jira_memories.py --projects ASSET,BILLING \
    --org-id acme-corp --limit 200
```

Requires `JIRA_BASE_URL` plus either `JIRA_EMAIL` + `JIRA_API_TOKEN` (Cloud) or
`JIRA_PERSONAL_ACCESS_TOKEN` (Server/DC), and `MEMMACHINE_BASE_URL`.

Seeded keys are recorded in `.jira_seed_state.json` and skipped on re-runs.
Delete that file only if you intend to re-seed — re-running without it creates
duplicate episodes.

---

## Operating notes

**Turning it off.** Set `MEMORY_ENABLED=false` and restart the backend. Existing
memories are retained and ignored. To wipe them:
`podman compose -f dev-compose.yml --profile memory down -v`.

**Neo4j is shared with Phase 7.** The tldr code-graph loader will use the same
instance with separate `:CodeFile`/`:Function`/`:CALLS` labels. Sizing accounts
for both.

**Rule decay is not implemented.** The roadmap calls for a compaction job that
marks contradictory or stale memories superseded. Without it the base grows
monotonically. Not urgent at low volume; revisit before a customer passes a few
hundred jobs.

**What is not built yet.** Learned-rule promotion (Phase 5) and golden assets
(Phase 6) both write *profile* memory. Only episodic writes exist today.

### Diagnosing quietly-missing recall

Every failure path logs at WARNING and continues, so an empty recall is silent by
design. In order:

```bash
# 1. Is the plane even on?
podman logs crew-backend-dev 2>&1 | grep -i "context memory"

# 2. Is the client installed?
podman exec crew-backend-dev /app/venv/bin/pip show memmachine-client

# 3. Is the server healthy?
curl http://localhost:8280/api/v2/health

# 4. Are writes landing? (should climb after each job)
podman exec crew-memmachine-postgres \
  psql -U memmachine -d memmachine -c '\dt'
```

If writes succeed but recall returns nothing, suspect scope mismatch first: check
that the `org=… project=… domain=…` in the write log matches the read log. Then
consider `memory.search_score_threshold` being too high.
