---
name: skills-service-query
description: >-
  Query the OPL Skills Service to discover framework-specific coding patterns,
  conventions, and architecture guidelines before designing or implementing code.
  Use when working with Frappe, React, Python, or any indexed framework.
tags:
  - skills
  - query
  - frappe
  - architecture
  - patterns
---

# Skills Service — Agent Integration

The Skills Service indexes SKILL.md documents and provides **semantic search**
over coding patterns, framework conventions, and architecture guidelines.

**Always query skills before** designing, architecting, or implementing any
feature — the results contain framework-specific ground truth (folder structures,
DocType patterns, API conventions, etc.) that prevents you from inventing
incorrect patterns.

## Service Endpoints

| Endpoint | Port | Protocol |
|----------|------|----------|
| REST API | `8090` | HTTP JSON |
| MCP      | `8090/mcp` | MCP (FastMCP / streamable HTTP — mounted in [skills-service `src/main.py`](https://github.com/varkrish/skills-service/blob/main/src/main.py) via `api.mount("/mcp", mcp_asgi)`) |

**MCP URL (local):** `http://localhost:8090/mcp` — same process as the REST API; only the path differs (`/query`, `/skills`, `/mcp`, …).

**Container hostname**: `skills-service` (inside docker/podman compose network)
**Local hostname**: `localhost`

---

## Option 1: REST API (HTTP)

### Query Skills (semantic search)

```bash
curl -X POST http://localhost:8090/query \
  -H "Content-Type: application/json" \
  -d '{"query": "Frappe DocType folder structure conventions", "top_k": 3}'
```

**Request body:**

```json
{
  "query": "natural language question about coding patterns",
  "top_k": 3,
  "tags": ["frappe", "python"]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `query` | string | yes | Semantic search query |
| `top_k` | int | no | Max results (default: 3) |
| `tags` | string[] | no | Filter by tags (e.g. `["frappe"]`, `["react"]`) |

**Response:**

```json
{
  "results": [
    {
      "skill_name": "frappe-app-scaffold",
      "content": "# Frappe App Scaffold — Canonical Folder Structure\n...",
      "tags": ["frappe", "python", "scaffold"]
    }
  ]
}
```

### List All Skills

```bash
curl http://localhost:8090/skills
```

Returns all indexed skills with name, description, tags, and file count.

### Reload Index

```bash
curl -X POST http://localhost:8090/reload
```

Triggers a background re-index after adding/editing/removing SKILL.md files.
Returns `202 Accepted` with `{"status": "rebuilding"}`.

### Health Check

```bash
curl http://localhost:8090/health        # basic liveness
curl http://localhost:8090/health/ready   # index ready (503 if still building)
```

---

## Option 2: MCP (Model Context Protocol)

For MCP-compatible agents, connect to the SSE endpoint:

```
http://localhost:8090/mcp
```

### Available MCP Tools

| Tool | Description |
|------|-------------|
| `query_skills` | Semantic search. Args: `query` (string), `top_k` (int, default 3), `tags` (comma-separated string, e.g. `"frappe,python"`) |
| `list_skills` | List all available skills with names, descriptions, and tags. No args. |
| `reload_index` | Re-index all skill documents. No args. |

### MCP Configuration Example

For agents that accept MCP server config (e.g. Claude Desktop, Cursor, Hermes):

```json
{
  "mcpServers": {
    "skills-service": {
      "url": "http://localhost:8090/mcp",
      "transport": "sse"
    }
  }
}
```

Inside a compose network, replace `localhost` with `skills-service`.

---

## When to Query

Query skills **before** any of these tasks:

| Task | Example Query |
|------|--------------|
| Designing a Frappe app | `"Frappe DocType design patterns architecture"` |
| Defining a tech stack | `"Frappe app folder structure scaffold conventions"` |
| Writing a controller | `"Frappe controller hooks validate on_submit"` |
| Building a web form | `"Frappe web form builder patterns"` |
| Writing tests | `"Frappe unit test patterns pytest"` |
| Creating a Containerfile | `"Frappe app containerfile deployment"` |
| React component design | `"React component architecture patterns"` |
| API design | `"REST API handler patterns conventions"` |

### Query Tips

- Include the **framework name** (Frappe, React, FastAPI, etc.)
- Add the **concept** you need (folder structure, DocType, hooks, testing)
- Use `tags` to filter when you know the framework: `"tags": ["frappe"]`
- `top_k: 5` if you want broader coverage; `top_k: 2` for focused results

---

## Using Results

The response `content` field contains the full SKILL.md text. Use it as
**ground truth** for:

1. **Folder structures** — copy the exact layout, do not invent your own
2. **File naming** — use the naming conventions shown in the skill
3. **Code patterns** — follow the controller, hook, and test patterns exactly
4. **What NOT to do** — skills often list common mistakes to avoid

### Example: Integrating into an Agent Workflow

```python
import httpx

def get_skill_context(vision: str, tags: list[str] | None = None) -> str:
    """Fetch relevant skills before designing or implementing."""
    resp = httpx.post(
        "http://skills-service:8090/query",
        json={"query": vision, "top_k": 3, "tags": tags},
        timeout=15,
    )
    resp.raise_for_status()
    results = resp.json().get("results", [])
    return "\n\n---\n\n".join(
        f"[Skill: {r['skill_name']}]\n{r['content']}" for r in results
    )
```

---

## Currently Indexed Skill Categories

| Tag | Examples |
|-----|----------|
| `frappe` | frappe-app-scaffold, frappe-doctype-builder, frappe-controller, frappe-api-handler, frappe-web-form-builder, frappe-tdd-tests |
| `python` | frappe-controller, frappe-unit-test-generator, frappe-secure-endpoint |
| `scaffold` | frappe-app-scaffold, frappe-microservice-scaffold |
| `testing` | frappe-tdd-tests, frappe-unit-test-generator |
| `devops` | frappe-containerfile-generator, frappe-compose-dev-generator |

Run `GET /skills` or MCP `list_skills` to see the full current list.
