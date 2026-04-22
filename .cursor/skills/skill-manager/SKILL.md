---
name: skill-manager
description: >-
  Install, search, scan, and delete skills via the Skill Manager service.
  Use when the user asks to find new skills from marketplaces, install skills
  from GitHub repos, browse installed skills, or manage the skills library.
tags:
  - skills
  - marketplace
  - install
  - github
---

# Skill Manager — Agent Integration

The Skill Manager (port **8091**) handles all write operations for the skills
ecosystem: marketplace search, GitHub repo scanning, skill installation, and
deletion. It has its own embedded UI at `http://localhost:8091/`.

The read-only Skills Service (port 8090) handles querying — see the
`skills-service-query` skill for that.

**Container hostname**: `skill-manager` (inside compose network)
**Local hostname**: `localhost`

---

## API Reference

Base URL: `http://localhost:8091`

### Health Check

```bash
curl http://localhost:8091/api/health
```

Returns: `{"status": "ok", "service": "skill-manager", "version": "0.2.0"}`

---

### Search Marketplace (agentskill.sh)

Browse 107,000+ skills from [agentskill.sh](https://agentskill.sh).

```bash
curl "http://localhost:8091/api/marketplace/search?q=kubernetes&page=1&limit=20&sort=trending"
```

| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `q` | string | `""` | Search query (empty = browse all) |
| `page` | int | `1` | Page number (1-indexed) |
| `limit` | int | `20` | Results per page (max 100) |
| `sort` | string | `""` | `trending`, `top`, `hot`, `latest` |
| `category` | string | `""` | `development`, `marketing`, `data-science`, etc. |

**Response:**

```json
{
  "results": [
    {
      "slug": "k8s-operator",
      "name": "Kubernetes Operator Skills",
      "description": "...",
      "owner": "hawkli-1994",
      "repo": "k8s-operator-skills",
      "installCount": 42,
      "contentQualityScore": 85,
      "securityScore": 90,
      "category": "development",
      "tags": ["kubernetes", "operator"],
      "githubPath": "skill.md",
      "marketplaceUrl": "https://agentskill.sh/@hawkli-1994/k8s-operator"
    }
  ],
  "total": 107000,
  "page": 1,
  "totalPages": 5350,
  "hasMore": true
}
```

---

### Install a Skill from Marketplace

Async operation — returns a job ID immediately.

```bash
curl -X POST http://localhost:8091/api/marketplace/install \
  -H "Content-Type: application/json" \
  -d '{
    "owner": "hawkli-1994",
    "repo": "k8s-operator-skills",
    "slug": "k8s-operator",
    "github_path": "skill.md"
  }'
```

**Response:** `{"job_id": "abc-123", "slug": "k8s-operator", "status": "accepted"}`

The manager fetches SKILL.md from GitHub, saves it to the marketplace
directory, and triggers a reindex on the skills service.

---

### Scan a GitHub Repo for Skills

Finds all SKILL.md files in a GitHub repository.

```bash
curl "http://localhost:8091/api/github/scan?repo_url=https://github.com/owner/repo"
```

Accepts full GitHub URLs or `owner/repo` format.

**Response:**

```json
{
  "owner": "owner",
  "repo": "repo",
  "skills": [
    {
      "slug": "my-skill",
      "path": "skills/my-skill/SKILL.md",
      "raw_url": "https://raw.githubusercontent.com/owner/repo/main/skills/my-skill/SKILL.md",
      "installed": false
    }
  ],
  "count": 3
}
```

---

### Bulk Install from GitHub Scan

Install multiple skills from a scanned repo concurrently. Uses `raw_url`
directly from scan results to avoid re-scanning GitHub.

```bash
curl -X POST http://localhost:8091/api/github/install-bulk \
  -H "Content-Type: application/json" \
  -d '{
    "owner": "owner",
    "repo": "repo",
    "skills": [
      {"slug": "skill-a", "raw_url": "https://raw.githubusercontent.com/..."},
      {"slug": "skill-b", "raw_url": "https://raw.githubusercontent.com/..."}
    ]
  }'
```

**Response:** `{"job_id": "def-456", "total": 2, "status": "accepted"}`

---

### Poll Job Status

All install operations are async. Poll the job endpoint:

```bash
curl http://localhost:8091/api/jobs/{job_id}
```

**Response:**

```json
{
  "id": "abc-123",
  "state": "done",
  "total": 1,
  "installed": ["k8s-operator"],
  "failed": [],
  "message": ""
}
```

| State | Meaning |
|-------|---------|
| `pending` | Queued, not started |
| `running` | Fetching and installing |
| `done` | Completed (check `installed` and `failed` lists) |
| `failed` | Fatal error |

---

### List Installed Skills

```bash
curl http://localhost:8091/api/installed
```

**Response:**

```json
{
  "skills": [
    {
      "slug": "k8s-operator",
      "name": "Kubernetes Operator Skills",
      "description": "...",
      "size": 4523
    }
  ],
  "count": 1
}
```

---

### Delete a Skill

```bash
curl -X DELETE http://localhost:8091/api/installed/k8s-operator
```

Returns `204 No Content` on success. Triggers a reindex automatically.

---

## Embedded UI

Open `http://localhost:8091/` in a browser for a visual interface with:

- **Marketplace tab**: Search agentskill.sh with pagination, sorting, and
  category filtering. Install skills with one click.
- **GitHub tab**: Paste a GitHub repo URL, scan for skills, and bulk install.
- **Installed tab**: View and delete installed skills.

---

## Typical Workflow

```
1. Search marketplace    →  GET  /api/marketplace/search?q=react
2. Install a skill       →  POST /api/marketplace/install {owner, repo, slug}
3. Poll until done       →  GET  /api/jobs/{job_id}
4. Query the skill       →  POST http://localhost:8090/query  (skills-service)
```

Or for GitHub repos:

```
1. Scan repo             →  GET  /api/github/scan?repo_url=...
2. Bulk install           →  POST /api/github/install-bulk {owner, repo, skills}
3. Poll until done       →  GET  /api/jobs/{job_id}
4. Skills are now queryable via the skills service (port 8090)
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SKILLS_SERVICE_URL` | `http://skills-service:8090` | URL of the read-only skills service (for reindex trigger) |
| `SKILLS_MARKETPLACE_DIR` | `/app/skills/marketplace` | Directory where installed skills are stored |
| `GITHUB_TOKEN` | (none) | Optional GitHub token for higher API rate limits |
