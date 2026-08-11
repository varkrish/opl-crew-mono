# OPL Crew — System Architecture

How the pieces fit together: services, data stores, the job lifecycle, and the
six knowledge planes that feed the agents.

Everything here is drawn from the running code and `dev-compose.yml`. Where a
component is planned rather than built, it says so.

**Related:** [`context-memory-plane.md`](context-memory-plane.md) for the memory
plane in depth, and `../opl-crew-enhancements.md` for the Release 3 roadmap.

---

## 1. Services at a glance

The monorepo is a set of Git submodules composed together. Only three services
are core; the rest are opt-in compose profiles, so a default `up` is small.

| Service | Repo / source | Profile | Host port | Role |
|---|---|---|---|---|
| `backend` | `opl-ai-software-team` | core | 8080 | API + the whole agent pipeline |
| `frontend` | `opl-studio-ui` | core | 3000 | Studio UI (React) |
| `validator` | `crew-code-validator` | core | 8181 | Out-of-process code validation |
| `keycloak` | upstream | core | 8180 | OIDC identity provider |
| `skills-service` | `skills-service` | `skills` | 8090 | Org coding standards (P4) |
| `skill-manager` | `skill-manager` | `skills` | 8091 | Skills marketplace |
| `connector` | `crew_jira_connector` | `jira` | 8082 | Jira webhook bridge |
| `jira` | upstream | `jira` | 8081 | Local Jira for testing |
| `memmachine-app` | upstream | `memory` | 8280 | Context memory plane (P3) |
| `memmachine-postgres` | pgvector | `memory` | 55432 | Profile/semantic memory |
| `memmachine-neo4j` | neo4j | `memory` | 7474 / 7687 | Episodic graph + future code graph |
| `memmachine-config` | init container | `memory` | — | Renders MemMachine config from env |
| `headroom` | upstream | `headroom` | 8787 | Token-compression proxy |
| Sandbox API | `podman-sandbox-api2` | **not in compose** | 18080 | Runs generated code in containers |

> **The Sandbox API runs on the host, not as a compose service.** It drives the
> podman CLI directly, so the backend reaches it through
> `host.docker.internal:18080`. Set `SMOKE_TEST_BACKEND=sandbox_api` to route
> smoke tests and the feature test bed through it instead of static analysis.

Port choices worth knowing: Keycloak takes 8180 and the backend 8080, which is
why MemMachine — whose container port is 8080 and whose upstream compose
suggests 8180 — is published on **8280** here.

```
                            ┌───────────────┐
                            │  Studio UI    │  :3000
                            │ opl-studio-ui │
                            └───────┬───────┘
                                    │ REST + SSE
                    ┌───────────────▼───────────────┐
   Jira ─webhook──► │           backend             │ :8080
   :8081            │  FastAPI (asgi_app)           │
   via connector    │  + Flask fallback (WSGI mount)│
   :8082            │  + agent pipeline in-process  │
                    └──┬────┬────┬────┬────┬────┬───┘
                       │    │    │    │    │    │
        ┌──────────────┘    │    │    │    │    └──────────────┐
        ▼                   ▼    │    ▼    ▼                   ▼
  ┌───────────┐      ┌──────────┐│┌────────────┐        ┌────────────┐
  │ validator │      │  skills  │││ Sandbox API│        │ MemMachine │ :8280
  │  :8181    │      │  :8090   │││  host:18080│        │  (P3)      │
  └───────────┘      └──────────┘│└────────────┘        └─────┬──────┘
                                 │                            │
                    ┌────────────▼────────────┐      ┌────────┴────────┐
                    │ crew_jobs.db (SQLite)   │      ▼                 ▼
                    │ workspace/{job_id}/     │  Postgres          Neo4j
                    └─────────────────────────┘  (pgvector)      (episodic +
                                                                  code graph)
```

**Auth.** Keycloak issues OIDC tokens. The backend validates them and derives
`owner_id` / `team_id`, which become the memory plane's customer scope. nginx
generates `/env.js` at container start so the frontend picks up
`AUTH_ENABLED` without an image rebuild. Set `AUTH_ENABLED=false` for a
passwordless demo.

---

## 2. The backend is two apps in one process

This trips people up, so it is worth stating plainly. `crew_studio/asgi_app.py`
is the FastAPI application and the real entrypoint
(`uvicorn crew_studio.asgi_app:app`). The older Flask app in
`crew_studio/llamaindex_web_app.py` is mounted underneath it as a WSGI fallback.

Routes defined in FastAPI win. Routes that exist only in Flask (for example the
multipart document upload endpoints) fall through to it. **Some paths exist in
both** — `POST /api/jobs` is the important one — and there the FastAPI handler
serves the request. Any cross-cutting hook has to be attached to whichever
handler actually runs, which is a mistake that has already been made once and
fixed (see the memory plane's Jira hook).

---

## 3. Job lifecycle

```
POST /api/jobs  (Studio UI, or Jira connector, or CLI)
    │  create job row, workspace/{job_id}/, save docs, write Jira memory
    ▼
run_job_async  ──►  build_runner.run_build_pipeline  ──►  SoftwareDevWorkflow.run()
    │
    ├─ phases resolved per solutioning_path (see below)
    ├─ each phase updates jobs.current_phase / progress → UI polls or streams
    ├─ agents call the LLM through GenericLlamaLLM; tokens land in llm_usage
    └─ verifiers write validation_issues
    │
    ├── pauses ──► pending_solution_review / pending_review / pending_approval
    │                └─ human responds → refine_solution / refine_plan → resume
    │
    └── terminal ──► completed | partially_completed | failed
                      │
                      ├─ push to GitHub (import jobs open a PR)
                      ├─ write job outcome summary  → memory plane
                      └─ write corrections          → memory plane
```

### Phase pipelines

Defined in `workflow_resolver.FALLBACK_PIPELINES`, overridable from
`config.yaml` under `workflows:`. The `adaptive` path picks one at runtime via
`smart_router.decide_workflow_phases()` and stores the result on the job so a
resume is deterministic.

| Path | Phases |
|---|---|
| `full` | meta → stack_contract → product_owner → designer → tech_architect → qa → **parallel**(development, frontend, devops) |
| `fast` | meta → stack_contract → seed_minimal_artifacts → **parallel**(development, frontend) |
| `edit` | meta → qa → refinement |
| `refactor` | meta → stack_contract → tech_architect → qa → refinement |

### Modes

`build` (greenfield), `import` / `fix` (analyse an existing codebase, then
auto-refine), `migration` (MTA-report driven), `refactor`, and `epic` (decompose
a Jira epic into stories and run them in sequence). Migration, refactor, and
import park the job in an `awaiting_*` phase at creation and are started by their
own endpoint rather than the build pipeline.

### The two inner loops

Both persist state to `jobs.metadata["loop_state"]` so a critique survives a
restart and the agents do not re-derive it:

- **Solutioning loop** (`solutioning_loop.py`) — Research → Architect → Critique,
  up to `max_passes`. Exits when the critique approves. Produces
  `solution_spec.md`, the single contract downstream agents read.
- **Feature test bed loop** — run container-isolated tests, and if red, DevAgent
  fixes with the critique and retests, up to `MAX_TEST_ITERATIONS`.

---

## 4. Data stores

| Store | Location | Holds | Lifetime |
|---|---|---|---|
| Job DB | `crew_jobs.db` (SQLite, WAL) | jobs, refinements, validation_issues, llm_usage, tool_usage, mcp_configs, per-user LLM/Jira/GitHub config | Persistent |
| Workspace | `workspace/{job_id}/` | generated source, artifacts, `solution_spec.md`, critique passes, `validation_report.json`, `execution.log` | Per job |
| Job-local RAG | `workspace/index_{job_id}/` | LlamaIndex embeddings of uploaded docs | Per job |
| Memory plane | MemMachine Postgres + Neo4j | cross-job summaries and corrections | Persistent, domain-scoped |
| Skills | marketplace volume | org standards, framework patterns | Persistent |

**SQLite, no ORM, no migration framework.** Schema lives in
`JobDatabase._init_schema` as `CREATE TABLE IF NOT EXISTS` plus idempotent
`ALTER TABLE ... ADD COLUMN` in try/except. New columns follow that pattern.

**The job DB is the loop's durable spine** — `current_phase` answers where a job
is, `metadata["loop_state"]` holds the iteration count and current critique,
`last_message` is a rolling 50-entry phase log, `validation_issues` is what the
verifier rejected, and `llm_usage` is the budget tracker.

---

## 5. The six knowledge planes

Each answers a question no other plane can. This is the core design idea: agents
should retrieve rather than guess.

| Plane | Source | Question | Status |
|---|---|---|---|
| **P1** structural (your code) | llm-tldr on the workspace | What exists? Who calls what? What breaks if I change X? | **Built** — structure map injected into refinement prompts; `code_impact` wired in |
| **P2** domain / semantic | Hyper-Extract MCP | What are the business entities and rules across our docs? | Not built (Phase 8) |
| **P3** historical | MemMachine | What did we decide before? What failed review? What did reviewers correct? | **Built** — see [`context-memory-plane.md`](context-memory-plane.md) |
| **P4** normative | skills-service | How does our org expect code to be written? | **Built** — wired into Designer, TechArchitect, DevOps via `prefetch_skills()` |
| **P5** framework API | Context7 MCP | What is the exact annotation/import for this framework version? | Deferred (Phase 2) — needs prefetch-inject for TechArchitect, which drops extra tools by design |
| **P6** framework structural | llm-tldr on framework source → Neo4j | How does the framework work internally? | Not built (Phase 7) — would share the MemMachine Neo4j instance |

**Compression sits above all six.** headroom is an OpenAI-compatible proxy in
front of the configured LLM endpoint. Point `LLM_API_BASE_URL` at
`http://headroom:8787/v1` and give headroom the real upstream in
`OPENAI_TARGET_API_URL`. Caveat: per-user BYOK base URLs bypass it entirely, so
only server-default traffic is compressed.

### How the planes reach the agents

```
Solutioning research phase
   ├─ MemMachine .search()   → past outcomes + corrections   ─┐
   ├─ skills-service         → conventions for the stack      ├─► solution_spec.md
   ├─ llm-tldr               → what the attached code is       │
   └─ GitHub search          → reference implementations      ─┘
                                                                │
   PO → Designer → TechArch → Developer → DevOps  ◄─────────────┘
   (they read solution_spec.md; they do not query the planes themselves)
```

Isolating retrieval from generation means one recall per job instead of one per
agent, and a single contract to review when the output is wrong.

---

## 6. LLM access

All LLM traffic goes through `GenericLlamaLLM` (`utils/llm_config.py`), a
LlamaIndex `FunctionCallingLLM` that posts OpenAI-compatible JSON via `httpx`.
There is **no in-process LiteLLM** despite the dependency being declared — a
detail that matters whenever someone proposes a "just add a LiteLLM callback"
integration.

Three model tiers — `manager`, `worker`, `reviewer` — are chosen per agent.
Memory summaries deliberately use the cheapest tier. Token counts flow from
LlamaIndex's `TokenCountingHandler` through `budget_tracker.record_usage()` into
the `llm_usage` table, which is also the budget cap check.

`supports_react` decides between ReAct tool loops and single-shot structured
output; it is auto-inferred from the model name and can be forced off for small
models. **TechArchitect deliberately runs with no tools** — the ReAct parser
fails on its large trimmed contexts — so anything that agent needs must be
prefetched and injected as text.

**BYOK.** Per-user model, key, and base URL come from `user_llm_configs` and are
applied for the duration of a job via `user_llm_context`.

---

## 7. Extending the system

**MCP servers.** `McpBridge` bridges stdio and SSE MCP servers into agent tool
lists. Users register their own via Settings; configs are stored per-user in
`mcp_configs` and merged into the runtime config by `config_for_job_owner`.
Security today is env scrubbing plus SSRF validation on SSE URLs; full container
isolation is Phase 2.5, which would extend the existing `podman-sandbox-api2`
rather than build a new sidecar.

**Tools.** Native tools are Python factories; MCP tools are bridged. Both attach
per agent role via `config.tools.agent_tools[<role>]`, with `global_tools`
applying to every agent.

**Adding a service.** Give it a compose profile so a default `up` stays small,
put its URL behind an env var with a container-internal default, and make the
backend's use of it fail-open — the memory plane, skills service, and validator
all degrade to no-ops rather than failing a job.

---

## 8. Running it

```bash
cp .env.example .env      # then set LLM_API_KEY

# Core: backend + validator + frontend + keycloak
podman compose -f dev-compose.yml up -d

# Optional stacks
podman compose -f dev-compose.yml --profile skills up -d
podman compose -f dev-compose.yml --profile jira up -d
podman compose -f dev-compose.yml --profile memory up -d
podman compose -f dev-compose.yml --profile headroom up -d

# Or combine
COMPOSE_PROFILES=skills,memory podman compose -f dev-compose.yml up -d
```

Dev compose bind-mounts source and caches Python venvs in named volumes, so the
first run is slow (a few minutes of dependency install) and later runs start in
seconds. `down -v` resets everything including those caches.
