# OPL Crew — Release 3 Roadmap

> **Status:** Release 3 planning — v2.0.0 shipped, roadmap below targets v3.0.0  
> **Last updated:** July 2026  
> **Related docs:** `enterprise-context-plane-architecture.html`, `telemetry-and-performance.html`, `context-plane-impact-measurement.html`
>
> **Key design decisions (July 2026):**
> - **MemMachine** ([github.com/MemMachine/MemMachine](https://github.com/MemMachine/MemMachine)) replaces custom memsearch/Milvus as the cross-job memory layer (P3 — Historical plane)
> - MemMachine's **Neo4j instance is shared** with llm-tldr code graph storage (P6) — one graph DB serves both episodic memory and code structure
> - **lean-ctx dropped** — headroom (token compression) + llm-tldr (impact analysis) already cover its capabilities without an additional sidecar
> - **llm-tldr remains** the code indexer/parser — its `code_impact` tool is already wired into RefinementAgent
> - **MemMachine summary writes** — job outcomes, Jira context, and user doc summaries are written at lifecycle hooks; raw files stay per-job in local RAG
> - **MCP sandbox** — user-configured MCP servers will run as throwaway containers (podman `--rm --network=none`) via a dedicated sandbox sidecar API; `_connect_stdio` env scrubbing + SSRF validation is the interim security layer until the sandbox is built
>
> ---
>
> **✅ Shipped in v2.0.0 (July 2026):**
> - **Loop Engineering** — solutioning loop (`solutioning_loop.py`: Research → Architect → Critique, configurable passes), feature test bed loop (run tests → DevAgent fix → retest, up to N iterations), loop state persistence in `jobs.metadata["loop_state"]`
> - **MCP infrastructure** — `McpBridge` (stdio + SSE transports), per-user MCP config API (`GET/POST/DELETE /api/mcp/configs`), `mcp_configs` table, Settings UI tab, target-agent scoping
> - **MCP security** — env scrubbing (`_safe_env`: empty-base allowlist, substring-match blocking of secrets), SSRF protection (`_validate_sse_url`: loopback + private IP + scheme checks), validation at save time + connect time; 27 automated security tests
> - **TLDR codebase intelligence** — compact structure map injected into single-file refinement prompts; auto-warm on stale/missing cache; TLDR settings exposed in Workflow Settings UI; `code_search` empty-result redirect to `file_reader`
> - **TDD-first pipeline** — Gherkin BDD scenarios specced first; tests generated before implementation; language-agnostic test-file pairing; parallel Developer execution; smoke test strategy pattern
> - **Solution review UI** — plan/solution review panel correctly reads `solution_spec.md` from `artifacts`; calls `/refine-solution` endpoint; inline refinement chat docked in Files workspace
> - **Auth runtime configuration** — nginx generates `/env.js` at startup; `OAuthProvider` reads `window.__ENV__`; `AUTH_ENABLED` flows from `.env` to both backend and frontend without image rebuild
> - **BYOK LLM settings** — model, API key, and base URL configurable via Settings UI; model pricing stored in `model_context_windows` DB table
> - **Jira integration** — issue picker in job creation; encrypted per-user token storage; `GET /api/jira/issues` search endpoint; webhook bridge (Jira Connector service)
> - **Installer overhaul** — one-line `curl | bash`; rootless podman socket auto-detection on Linux; all 8 services start by default (no `--profile` flags); idempotent re-installs; TTY-safe pipe-install mode
> - **Output parser fixes** — spaces in file paths normalized; `Scenario Outline`, `Background`, `Rule`, `But` Gherkin keywords accepted

---

## Contents

1. [Post-Job Hook](#1-post-job-hook)
2. [Confidence Score Algorithm](#2-confidence-score-algorithm)
3. [Loop Engineering — The Feedback Cycle](#3-loop-engineering--the-feedback-cycle)
4. [Enterprise Context Plane Integration](#4-enterprise-context-plane-integration)
5. [Implementation Roadmap](#5-implementation-roadmap)

---

## 1. Post-Job Hook

### What it is

A hook that fires automatically when a job reaches a terminal state. It computes a confidence score, stores the result, and triggers the feedback loop.

### When it fires

| Event | Status transition | Purpose |
|---|---|---|
| Job completes | `running` → `completed` or `partially_completed` | Full confidence score across all four components |
| Plan approved | `pending_review` → approved | Plan-time confidence score — early signal before coding starts (feature coverage vs vision only) |

### Trigger point in the codebase

The hook attaches at the end of `software_dev_workflow.py` `run()` method, just before the final `return` dict with `"status": "completed"` (line ~748). For partial completions and refactor/migration modes, the same pattern applies at their respective completion points.

### Inputs available at hook time

| Input | Source |
|---|---|
| Original vision text | `jobs.vision` in job DB |
| Generated feature files | `workspace/features/*.feature` |
| All planning artifacts | `workspace/user_stories.md`, `design_spec.md`, `tech_stack.md` |
| Artifact assertion results | Return value of `artifact_assertions.validate_*()` |
| Skill prefetch debug data | `workspace/skill_prefetch.json` (skill names + relevance scores) |
| Refinement count | `refinements` table — count rows by `job_id` |
| LLM token usage | `llm_usage` table — sum input/output tokens by `job_id` |

### Output

- `confidence_score` (0–100) stored in `jobs.metadata.confidence_score`
- `missing_features` list stored in `jobs.metadata.missing_features`
- Entry in a new `quality_scores` table: `job_id`, `score`, `component_breakdown`, `missing_features`, `computed_at`
- **Job outcome summary** written to MemMachine (episodic memory) — see [MemMachine summary writes](#memmachine-summary-writes)

---

## 2. Confidence Score Algorithm

### Formula

```
confidence_score = (feature_coverage × 0.40)
                 + (artifact_quality  × 0.25)
                 + (framework_fidelity × 0.20)
                 + (refinement_score  × 0.15)
```

### Component definitions

#### Feature Coverage (40%)

An LLM call comparing the original vision to the generated Gherkin features. Uses a fast/small model — not the main frontier model — to keep cost low.

```
Prompt:
  Vision: <original vision text>
  Generated features: <content of features/*.feature files>

  Score 0–100: what percentage of features requested in the vision
  are covered by the generated feature files?
  List any explicitly requested features that are missing.

Output: { "coverage_score": 78, "missing_features": ["depreciation workflow", "email notification"] }
```

The `missing_features` list is the primary input for headroom learn and MemMachine rule proposals.

#### Artifact Quality (25%)

Pass rate from `artifact_assertions.py` checks already run during the job:

```
artifact_quality = (passed_checks / total_checks) × 100

Checks: requirements.md exists + valid, user_stories.md valid,
        features/*.feature valid Gherkin, design_spec.md valid,
        tech_stack.md contains framework terms, source files ≥ 40 bytes,
        no raw agent dumps, no placeholder feature names
```

#### Framework Fidelity (20%)

Whether the generated artifacts use correct framework-specific terminology, as evidenced by:

- `tech_stack.md` contains terms from the used skills (e.g. "doctype", "bench", "frappe" for Frappe jobs)
- Top relevance score from `skill_prefetch.json` — if `top_score < 0.50`, fidelity is penalised

```
framework_fidelity = (term_match_score × 0.6) + (skill_relevance_score × 0.4)
```

#### Refinement Score (15%)

```
refinement_score = max(0, 100 - (refinement_count × 20))

0 refinements → 100
1 refinement  → 80
2 refinements → 60
3 refinements → 40
4+            → 0
```

### Decision thresholds

| Score range | Action |
|---|---|
| ≥ 85 and refinement_count ≤ 1 | Propose golden asset promotion (human confirms) |
| 70–84 | Flag for review — do not promote automatically |
| < 70 | Trigger headroom learn on this session; propose MemMachine rules for human review |

---

## 3. Loop Engineering

### What it is

Loop Engineering (Cobus Greyling, Addy Osmani, Boris Cherny) is the discipline of **designing the system that prompts your agents rather than writing prompts yourself**.

> "You shouldn't be prompting coding agents anymore. You should be designing loops that prompt your agents." — Peter Steinberger  
> "I don't prompt Claude anymore. I have loops running that prompt Claude and figuring out what to do. My job is to write loops." — Boris Cherny, Head of Claude Code at Anthropic

A **loop** is a recursive goal: define a purpose, and the system **continuously iterates** — with sub-agents, verification, and external state — until the goal is verifiably met or the loop decides to hand off to a human. The loop does not run once and stop. The verifier drives re-runs. The loop runs until done.

Reference: [cobusgreyling/loop-engineering](https://github.com/cobusgreyling/loop-engineering)

---

### The five building blocks + memory

| Primitive | Job in the loop | OPL Crew mapping |
|---|---|---|
| **Automations / Scheduling** | Heartbeat — without scheduling you just have a one-off agent run | Job submission via API; post-job hook; cadence-triggered re-runs until verifier passes |
| **Worktrees** | Parallelism without chaos — each agent gets an isolated working directory | `workspace/{job_id}/` — each job is an isolated worktree; parallel jobs never collide |
| **Skills** | Persistent intent — without skills the loop re-derives everything from scratch (intent debt) | `skills-service` — org coding standards, framework patterns, pre-indexed per customer |
| **Plugins & Connectors** | Reach into real tools (MCP) | Context7, Hyper-Extract, MemMachine MCP, Jira connector |
| **Sub-agents** | Maker / checker split — the agent that wrote the code is a terrible judge of its own work | MetaAgent → PO → Designer → TechArch → Developer → DevOps (makers) + validator + confidence scorer (checkers) |
| **+ Memory / State** | Durable spine outside any conversation — the loop must read and write something that survives restarts | **Already built**: SQLite `jobs` DB — `current_phase`, `last_message` (rolling log), `metadata` JSON (loop state), `llm_usage` (token tracking), `validation_issues`, `refinements`. Cross-job memory via **MemMachine** (episodic + profile memory, Neo4j + Postgres). |

---

### The continuous refinement loop

This is the core insight: **the loop iterates until the verifier passes, not just once**.

**Implemented:** Two loops now operate in the workflow:
1. **Solutioning loop** (`solutioning_loop.py`) — Research → Architect → Critique, iterates up to `max_passes` (default 3). Exits when Critique approves or max reached.
2. **Feature test bed loop** (`_run_feature_test_bed_loop`) — Run container-isolated tests → if RED → DevAgent fixes with critique → retest, up to `MAX_TEST_ITERATIONS` (default 3). Loop state (`current_critique`, `test_iteration`, `failures`) persisted to `jobs.metadata["loop_state"]`.

Both loops write `validation_issues` on exhaust and feed critique back through the DB — matching the loop-engineered pattern described below.

```
Job submitted (vision + optional source)
    │
    ▼
┌─────────────────────────────────────────────┐
│  LOOP (iterate until verifier passes)        │
│                                             │
│  Read loop state from DB                    │
│   jobs.metadata["loop_state"]:              │
│   - iteration_count                         │
│   - last_verifier_result                    │
│   - current_critique                        │
│   jobs.last_message: rolling run log        │
│                                             │
│  Query Context Plane                        │
│   - MemMachine: past decisions + rules      │
│   - skills-service: conventions             │
│   - Context7: framework API (version-pinned)│
│                                             │
│  Implementer Sub-agents (makers)            │
│   PO → Designer → TechArch → Developer      │
│   → DevOps (each reads critique from DB)    │
│                                             │
│  Verifier Sub-agents (checkers)             │
│   - artifact_assertions.py                  │
│   - crew-code-validator                     │
│   - validation_issues table updated         │
│   - confidence score computed               │
│                                             │
│  Write loop state to DB                     │
│   jobs.metadata["loop_state"] updated       │
│   jobs.last_message appended                │
│   llm_usage rows inserted                   │
│                                             │
│  Budget check: sum(llm_usage.cost) vs cap   │
│                                             │
└──────────────┬──────────────────────────────┘
               │
    ┌──────────▼──────────┐
    │  Verifier passed?   │
    │  (score ≥ threshold │
    │   OR max_iter hit)  │
    └──────────┬──────────┘
               │
       ┌───────┴───────┐
       │               │
    PASSED           FAILED / BUDGET
       │             │
       ▼             ▼
   Produce       Escalate to human
   final         with full context from DB:
   artifacts     - all iteration history
       │           (jobs.last_message)
       ▼         - all validation issues
   Post-Job Hook   - token spend summary
```

**The job DB is the loop's durable state spine.** It already answers all the questions STATE.md would:
- `jobs.current_phase` — what phase is the job in right now?
- `jobs.metadata["loop_state"]` — iteration count, last critique, verifier result
- `jobs.last_message` — rolling 50-message run log (each phase transition appended)
- `validation_issues` table — exactly what the verifier rejected and why
- `llm_usage` table — token spend per agent per iteration, the budget tracker
- `refinements` table — human-initiated refinement history

Without persisting critique between iterations (intent debt within a job), agents re-derive from scratch every pass. Writing `current_critique` to `jobs.metadata` after each verifier run is the minimal change needed to enable continuous refinement.

---

### Anatomy of the OPL Crew job loop (full)

```
API trigger (POST /api/jobs)
    │
    ▼
Triage — MetaAgent
 reads jobs.metadata (empty on first run)
 queries MemMachine: past jobs on this domain
 queries skills-service: target framework conventions
 queries Context7: framework version API
 writes jobs.metadata["loop_state"] = {iteration: 0, critique: null}
    │
    ▼
Solutioning loop (inner loop — 2-3 passes)
 SolutionArchitect proposes solution_spec.md
 SolutionCritique reviews it
 If critique finds gaps → Architect revises → Critique re-checks
 Exits when Critique approves or max_passes reached
    │
    ▼
Build loop (outer loop — up to N iterations)
 Makers: PO → Designer → TechArch → Developer → DevOps
 Checkers: artifact_assertions + crew-code-validator
 → writes validation_issues rows (already built)
 → If verifier rejects:
     critique written to jobs.metadata["loop_state"]["current_critique"]
     iteration_count incremented
     loop back to makers
 → llm_usage rows inserted each iteration (already built)
 → token budget = sum(llm_usage.cost) vs cap in jobs.metadata["budget"]
    │
    ▼
Human gate (plan review / approval)
 Triggered when: verifier passes AND plan_review_enabled
 Escalated when: max_iter hit OR budget exhausted
 Human sees: jobs.last_message (full iteration log),
             validation_issues (what failed),
             confidence score + missing_features,
             llm_usage summary (total tokens + cost)
    │
    ▼
Post-job hook (see Section 1 + 2)
    │
    ├── score ≥ 85 → Propose golden asset promotion
    └── score < 70 → headroom learn → propose MemMachine rules
            │
            ▼
    MemMachine + Neo4j updated (human confirmed)
            │
            ▼
    Next job on this domain starts with richer context
    → fewer iterations needed → higher score → better output
```

---

### Phased rollout (L1 → L2 → L3)

| Level | What the loop does | Human involvement | OPL Crew status |
|---|---|---|---|
| **L1 — Report only** | Job runs once, score logged, no re-runs | Human reads score dashboard, manually refines | **Current target** — confidence score (Phase 3 roadmap) completes this level |
| **L2 — Assisted** | Loop iterates (2–3 passes), verifier drives re-runs, critique fed back, score < 70 triggers rule proposals | Human reviews proposals, confirms promotions | **Partially built** — solutioning loop + test bed loop implement iteration; confidence score + MemMachine needed to close the feedback arm |
| **L3 — Unattended** | Loop runs until verifier passes or max_iter; allowlisted asset types auto-promoted; risky assets escalate | Human reviews escalations only | After L2 track record per customer is clean |

**Never skip levels.** L3 without L1/L2 baseline means auto-promoting with no quality history.

---

### Budget and observability

Every loop run must track token spend. Without this, sub-agent loops can exhaust budget silently.

**Already built in the DB:**

| Table / field | What it tracks | How the loop uses it |
|---|---|---|
| `llm_usage` rows | Tokens + cost per agent per iteration | `SELECT SUM(cost) FROM llm_usage WHERE job_id = ?` — compare against cap |
| `jobs.metadata["budget"]` | Max cost cap for this job | Set at job creation; loop harness checks after each iteration |
| `jobs.last_message` | Rolling 50-entry phase log | Loop appends `{iteration, phase, verifier_result, tokens}` each pass |
| `validation_issues` | What the verifier rejected and why | Agents read pending issues at loop start to build critique |
| `jobs.current_phase` | Current loop phase | Already updated by `update_progress()` — visible in Studio UI live |

**CLI tools (supplement only — not a replacement for the DB):**

```bash
# Estimate token budget before running at L2 (planning / pre-job)
npx @cobusgreyling/loop-cost --pattern ci-sweeper --cadence per-job

# Audit a job workspace for loop readiness (checks for run log, budget, state)
npx @cobusgreyling/loop-audit workspace/{job_id}/ --suggest
```

---

### Cross-job memory (the feedback loop)

After the job loop exits, the memory arm runs. This is a **longer-cadence loop** (per-job, not per-iteration) that makes future jobs on the same domain start with better context:

```
Post-job hook
    │
    ├── Compute confidence score → jobs.metadata + quality_scores table
    ├── Write job outcome summary → MemMachine (episodic)
    │
    ├── score ≥ 85, refinements ≤ 1
    │   → Propose golden asset promotion → human confirms
    │   → workspace packed → MemMachine (profile memory pointer)
    │   → Code graph synced to Neo4j (tldr → Neo4j loader)
    │   Future jobs: agents assemble from validated parts, not from scratch
    │
    └── score < 70
        → headroom learn mines session logs
        → proposes rules tagged: framework + domain + customer_id
        → Human Review Gate (Studio UI)
        → approved rules stored in MemMachine (profile memory)
        → next job on this domain: rules retrieved at triage via memory.search()
        → fewer iterations needed → higher score → loop self-improves
```

**Intent debt vs MemMachine.** Without persistent cross-job memory, every new job re-derives the same conventions, the same framework patterns, the same past mistakes — this is "intent debt". MemMachine eliminates it. The more jobs run and are reviewed, the less re-derivation is needed, and the fewer iterations the build loop requires.

**AGENTS.md does not scale.** For one developer, AGENTS.md works. For multiple customers and frameworks at enterprise scale, rules go into MemMachine — domain-scoped, customer-isolated, queryable by relevance, never injected wholesale.

**Domain tagging via MemMachine hierarchy:**
- `org_id` = `customer_id` (e.g. "acme-corp")
- `project_id` = `framework` (e.g. "frappe-15", "spring-boot-3")
- `group_id` = `domain` (e.g. "asset-management", "invoicing", "auth")
- `agent_id` = which agent stored it (e.g. "tech_architect")

This gives natural scoping — a Frappe job for Acme only retrieves memories from that customer's Frappe projects. A Spring Boot rule never leaks into a Frappe job.

**Rule decay.** A periodic compaction job queries MemMachine for contradictory or stale memories and marks them superseded. The rule base does not accumulate stale guidance over years.

### MemMachine summary writes

MemMachine is only effective if the system **writes structured summaries** at the right lifecycle points. Raw files stay per-job; MemMachine holds compact, searchable recall text scoped by customer/framework/domain.

**Three storage layers for user-provided content:**

| Layer | What | Where | Lifetime |
|---|---|---|---|
| Raw files | Uploaded `.md`, PDFs, MTA reports | `workspace/{job_id}/docs/` | Per job |
| Job-local RAG | Chunked embeddings for this job's agents | `workspace/{job_id}/index_{job_id}/` (LlamaIndex) | Per job |
| Cross-job recall | LLM-generated summaries + outcomes + rules | MemMachine (episodic + profile) | Persistent, domain-scoped |

User docs are **not** copied wholesale into MemMachine. A cheap LLM call produces a 2–3 sentence summary that future jobs can retrieve without re-upload.

#### Three summary types

| Summary type | MemMachine type | When written | Write point in codebase |
|---|---|---|---|
| **Job outcome** | Episodic | Job completes or partially completes | Post-job hook — end of `software_dev_workflow.py` `run()` |
| **Jira context** | Episodic | Jira webhook creates a job | `crew_jira_connector/webhook_handler.py` after successful `create_job()` |
| **Reference doc** | Episodic | User uploads via API/UI | `_save_uploaded_files()` in `llamaindex_web_app.py` |
| **Learned rule** | Profile | Human approves rule proposal (score < 70) | Studio UI promotion flow (Phase 5) |
| **Golden asset** | Profile | Human confirms promotion (score ≥ 85) | Golden asset workflow (Phase 6) |

#### Job outcome summary (post-job hook)

Generated by a fast/cheap model (same tier as confidence score — not the frontier model):

```
Prompt:
  Summarize this job outcome in 2–3 sentences for future recall.
  Vision: <jobs.vision[:500]>
  Framework/domain: <from jobs.metadata or tech_stack.md>
  Score: <confidence_score>
  Missing features: <missing_features>
  Top validation issues: <validation_issues, top 5>
  Refinement count: <refinements count>
  Key artifact: <solution_spec.md first 300 chars if present>

Output → memory.add(summary, metadata={
  "type": "job_outcome",
  "job_id": job_id,
  "score": confidence_score,
  "framework": framework,
  "domain": domain,
  "customer_id": owner_id
})
```

#### Jira context summary (webhook)

Today the Jira connector passes `summary + description` as vision and forgets it. After job creation, write:

```
memory.add(
  f"Jira {issue_key}: {summary}. Type: {issue_type}. "
  f"Mode: {classification.mode}. Repo: {repo_url or 'none'}. "
  f"Gherkin provided: {has_gherkin}.",
  metadata={"type": "jira_context", "issue_key": issue_key, "project_key": project_key}
)
```

For **epics**, also store parent context — epic vision + child story keys — so sibling stories recall what's already built:

```
memory.add(
  f"Epic {epic_key}: {epic_summary}. "
  f"Child stories: {story_keys}. Mode: build.",
  metadata={"type": "jira_epic", "epic_key": epic_key}
)
```

**Jira history seeding (Phase 4):** One-time backfill script queries Jira REST API for closed/completed issues in configured projects → generates summaries → bulk `memory.add()`. Same format as webhook writes.

#### Reference doc summary (upload)

When a user uploads docs at job creation or via `POST /api/jobs/{id}/documents`:

1. Save raw file to `workspace/{job_id}/docs/` (existing)
2. Index into local RAG via `DocumentIndexer` (existing)
3. **New:** LLM summary → MemMachine:

```
memory.add(
  f"Reference doc '{original_name}' for {domain}: {llm_summary}",
  metadata={"type": "reference_doc", "filename": original_name, "job_id": job_id}
)
```

Next job in the same domain recalls "customer previously provided MTA report showing 47 Java EE issues in auth module" without re-upload.

#### Read side (solutioning loop + triage)

At MetaAgent triage and solutioning research, query MemMachine before build starts:

```python
results = memory.search(
    f"What happened in past {framework} {domain} jobs? "
    f"What Jira issues relate to this vision? "
    f"What reference docs exist for this domain?"
)
# Scoped via hierarchy: org_id=customer_id, project_id=framework, group_id=domain
```

Returned context is injected into solutioning research prompt and optionally into `solution_spec.md` provenance section.

#### End-to-end write flow

```
Jira webhook fires
    ├── Create OPL job (existing)
    └── Write Jira context summary → MemMachine (episodic)

User uploads docs
    ├── Save to workspace/docs/ (existing)
    ├── Index into local RAG (existing)
    └── Write doc summary → MemMachine (episodic) [cheap LLM]

Job completes
    ├── Compute confidence score
    ├── Write job outcome summary → MemMachine (episodic)
    ├── Write learned rules (if score < 70) → MemMachine (profile) [after human review]
    └── Write golden asset pointer (if score ≥ 85) → MemMachine (profile) [after human confirm]
```

### Golden asset library

| Asset type | Example | MemMachine `memory.search()` query |
|---|---|---|
| Pipeline YAML | Tekton pipeline for Frappe on OpenShift | "tekton pipeline frappe" |
| Containerfile | UBI9-based Frappe container with bench | "containerfile frappe bench" |
| Auth module | OIDC integration with Keycloak | "auth oidc keycloak" |
| DocType scaffold | Standard Frappe DocType with audit fields | "doctype audit frappe" |

MemMachine stores the metadata and description of each golden asset. The actual artifact files live in object storage or the promoted workspace filesystem — MemMachine holds pointers with semantic search over descriptions.

At customer onboarding, their approved repos are pre-indexed. After each approved job, the workspace can be promoted. Over time, agents assemble from validated parts — fewer iterations, higher scores, lower token cost per job.

---

## 4. Enterprise Context Plane Integration

### The six knowledge planes

The context plane provides six distinct types of knowledge. Each answers a question no other plane can.

| Plane | Tool | Question answered | Status |
|---|---|---|---|
| P1 — Your code structural | llm-tldr (on workspace) | "What exists in our codebase? Who calls what? What breaks if I change X?" | **✅ Partially built (v2.0.0)** — structure map injected into refinement prompts; auto-warm; TLDR settings in UI. Needs wiring into RefactorArchitect + MigrationRunner. |
| P2 — Domain / semantic | Hyper-Extract MCP | "What are the business entities, rules, and compound workflows across our enterprise docs?" | **Not built.** Register in `config.example.yaml` MCP servers block. McpBridge infrastructure (v2.0.0) is ready — Phase 8. |
| P3 — Historical | MemMachine (episodic + profile memory) | "What did the team decide before? What failed in review? What Jira issues relate? What docs did the customer provide?" | **Not built.** Requires MemMachine stack + summary writes at post-job hook, Jira webhook, and doc upload. Phase 4. |
| P4 — Normative | skills-service | "How does our org expect code to be written — our patterns, our security baselines?" | **✅ Built (v2.0.0).** Wired into Designer, TechArchitect, DevOps via `prefetch_skills()`. Skills marketplace via skill-manager service. |
| P5 — Framework API | Context7 MCP | "What is the exact annotation, import, and method signature for Spring Boot 3.4 / Frappe 15?" | **Infrastructure ready (v2.0.0).** McpBridge supports SSE transport; per-user MCP config UI lets users register Context7. Wiring into TechArch + Developer agent tool lists = Phase 2. |
| P6 — Framework structural | llm-tldr (on framework source) → shared Neo4j | "How does the framework itself work internally? How does @Transactional propagate? How does Frappe's before_submit fire?" | **Not built.** Offline indexing job needed: clone Spring/Frappe source → run tldr → sync `call_graph.json` into Neo4j (shared with MemMachine). Phase 7. |

### Why P5 and P6 are both needed

Context7 (P5) gives you the API surface — what annotations and imports to use. The framework source graph (P6) gives you the internal call graph — why those patterns are required, and what happens if you use them incorrectly. An agent with both doesn't need to guess from training data, which may lag the actual version by months.

### Compression layer (horizontal — not a knowledge plane)

Token compression sits above all six planes, making context delivery cheaper without changing the knowledge content:

**headroom** (`pip install headroom-ai[all]`):
- One-line LiteLLM integration: `litellm.callbacks = [HeadroomCallback()]`
- Compresses every LLM call: message history, tool outputs, file reads, RAG chunks
- Proven 60–95% token reduction on real agent workloads
- Accuracy preserved: tool-calling at 97% accuracy with 32% compression (BFCL benchmark)
- `headroom learn`: mines failed sessions → proposes rules → feeds Loop Engineering

**Impact analysis** (already built via llm-tldr):
- `code_impact` tool: reverse call graph — finds all callers before rename/delete
- `code_structure`: project map of classes, functions, exports
- Wired into RefinementAgent + simple-mode prefetch today
- No additional sidecar needed — runs as subprocess, caches in `.tldr/cache/`

### Solutioning loop (implemented)

Before any job's build pipeline starts, a solutioning loop queries the context plane and produces `solution_spec.md` — the single contract all downstream agents read. This isolates knowledge retrieval from code generation.

**Implementation:** `solutioning_loop.py` with `SolutionResearchAgent`, `SolutionArchitectAgent`, `SolutionCritiqueAgent`. Configurable via `config.solutioning.enabled`, `max_passes`, `max_github_searches`. Wired into `software_dev_workflow.py` at line ~840 (before PO phase). Job pauses for solution review when enabled.

```
Solutioning Loop (Step 2 of vision flow):
  MemMachine    → past job outcomes, Jira context, reference doc summaries (memory.search)
  Hyper-Extract → "what business rules apply?" (future — Phase 8)
  llm-tldr      → "what does the attached legacy code look like?"
  skills-service → "what conventions apply for the target framework?"
  Context7       → "what APIs should we target at this version?"
  
  SolutionArchitect synthesises → solution_spec.md
  SolutionCritique reviews      → flags missing scope, wrong patterns
  
  Downstream agents (PO, Designer, TechArch, Developer) read solution_spec.md only.
  They do not query the context plane directly.
```

---

## 5. Implementation Roadmap — Release 3 (v3.0.0)

Ordered by effort-to-value ratio. Each phase is independently deployable.

| Phase | What | Effort | Status | Value delivered |
|---|---|---|---|---|
| 1 | headroom LiteLLM callback (`litellm.callbacks = [HeadroomCallback()]`) | 1 line | **Pending** | Immediate 60–95% token reduction on all LLM calls, zero agent changes |
| 2 | Context7 wired into TechArch + Developer via McpBridge | 1 day | **Pending** (McpBridge ready in v2.0.0) | Version-accurate framework annotations (jakarta vs javax, etc.) |
| 2.5 | MCP sandbox sidecar API — run user MCP servers as throwaway podman containers (`--rm --network=none --memory=256m`) | 3–4 days | **Pending** (env scrubbing + SSRF validation shipped in v2.0.0 as interim) | Full process isolation: user MCP configs can't access backend secrets, can't exhaust container resources, can't SSRF internal services |
| 3 | Post-job hook + confidence score + job outcome summary → MemMachine | 2–3 days | **Pending** | Measurement foundation — every job gets a score, missing features logged, outcome stored for recall |
| 4 | MemMachine deploy + summary writes (job outcome, Jira, doc upload) + Jira history seeding | 4–5 days | **Pending** | Historical truth plane — past decisions, Jira context, and doc summaries recalled at job start |
| 5 | headroom learn → MemMachine rule promotion UI in Studio | 3–4 days | **Pending** | Feedback loop closes — failed jobs teach future jobs |
| 6 | Golden asset promotion workflow | 2–3 days | **Pending** | Reusable asset library — agents assemble from validated parts |
| 7 | llm-tldr on framework source → Neo4j loader (shared Neo4j instance) | 1 week | **Pending** | Framework structural truth — why patterns are correct, not just what they are |
| 8 | Hyper-Extract for domain docs | 1–2 weeks | **Pending** | Domain truth plane — compound business rules from Confluence/ADRs |

### Phase 2.5 — MCP Sandbox Sidecar API (detail)

The sandbox API replaces `McpBridge._connect_stdio` for user-configured servers. The backend calls a dedicated sidecar instead of spawning subprocesses directly:

```
McpBridge._connect_stdio (current)
  └─► subprocess in backend container → shared env, shared PID space ❌

McpBridge._connect_container (Phase 2.5)
  └─► POST http://mcp-sandbox:8095/run { image, command, args, env }
        └─► sandbox sidecar: podman run --rm -i \
                               --network=none \
                               --memory=256m --cpus=0.5 \
                               --pids-limit=50 \
                               <image> <command>
              └─► stdio piped back as JSON stream ✅
```

**Compose addition** (`dev-compose.yml` + `compose.yml`):
```yaml
mcp-sandbox:
  container_name: crew-mcp-sandbox
  image: quay.io/varkrish/crew-mcp-sandbox:latest
  volumes:
    - /run/user/1000/podman/podman.sock:/run/podman/podman.sock:z
  environment:
    - ALLOWED_IMAGES=${MCP_ALLOWED_IMAGES:-}   # empty = any; set to restrict
    - MAX_MEMORY=256m
    - MAX_CPUS=0.5
  networks:
    - crew-net
```

**`McpToolEntry` schema addition:**
```python
image: Optional[str] = None   # if set → sandbox; if None → legacy stdio
```

The interim env scrubbing + SSRF protection shipped in v2.0.0 remains active for legacy stdio configs that don't yet specify an image.

### MemMachine stack (Phase 4 detail)

MemMachine deploys as 3 containers in `dev-compose.yml` (under a `memory` profile):

| Container | Image | Role |
|---|---|---|
| `memmachine-app` | `memmachine/memmachine` | API server (port 8180) + MCP server |
| `memmachine-postgres` | `pgvector/pgvector:pg16` | Profile memory (SQL + vectors) |
| `memmachine-neo4j` | `neo4j:5.23-community` | Episodic graph memory + code graph (shared with Phase 7) |

**Integration points:**
- LlamaIndex integration (`memmachine-client` pip package) wired into solutioning loop and post-job hook
- MCP server mode (`memmachine-mcp-http`) registered in `config.example.yaml` under `mcp_servers`
- Neo4j shared: MemMachine manages its own labels; Phase 7 tldr loader uses separate `:CodeFile`/`:Function`/`:CALLS` labels

**Summary write integration (Phase 4):**

| Component | File | Action |
|---|---|---|
| `MemMachineClient` wrapper | New: `crew_studio/memmachine_client.py` | Thin wrapper around `memmachine-client`; resolves hierarchy from job metadata |
| Post-job hook | `software_dev_workflow.py` | Job outcome summary after confidence score |
| Jira webhook | `crew_jira_connector/webhook_handler.py` | Jira/epic context summary after `create_job()` |
| Doc upload | `llamaindex_web_app.py` `_save_uploaded_files()` | Doc summary after save + RAG index |
| Jira backfill | New script: `scripts/seed_jira_memories.py` | One-time bulk seed from Jira REST API |
| Solutioning read | `solutioning_loop.py` | `memory.search()` in research phase before architect |

**Hierarchy mapping:**
```
org_id     = customer_id
project_id = framework (frappe-15, spring-boot-3)
group_id   = domain (asset-management, invoicing)
agent_id   = storing agent (tech_architect, solution_architect)
```

### The compounding effect

After Phase 5, the system enters a compounding improvement cycle:
- Each job writes a **job outcome summary** to MemMachine — future jobs recall what worked and what failed
- Jira issues and uploaded docs leave **persistent summaries** — no re-derivation when the same domain runs again
- Each job either contributes a golden asset (score ≥ 85) or a MemMachine rule (score < 70)
- The golden asset library grows with each approved job
- The rule base grows with each corrected failure
- Subsequent jobs on similar domains start with richer MemMachine context and fewer errors
- After 50 jobs, a customer has a proprietary knowledge base a competitor starting fresh cannot replicate
- Neo4j accumulates both episodic memory (MemMachine) and code structure graphs (tldr) — one infrastructure, two knowledge domains

This compounding is the primary commercial differentiator — the platform gets better with use in a way that is specific to each customer's domain and cannot be copied.
