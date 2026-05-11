#!/usr/bin/env bash
# GREENFIELD ONLY: mode=build runs the full "new project" pipeline. It does NOT read
# your existing Java repo from disk. Wording like "we already have..." in the vision
# is still treated as requirements for a *new* codebase.
#
# To work on a real existing tree (Import & iterate): use
#   scripts/submit-import-with-source.sh
# then POST /api/jobs/{id}/analyze, then Refine in the UI.
#
# Usage:
#   export CREW_API_URL=http://localhost:8080   # optional
#   ./scripts/submit-java-small-project-update-job.sh

set -euo pipefail
API="${CREW_API_URL:-http://localhost:8080}"

BODY='{
  "vision": "Build a small Java 17 Maven app from scratch: Main class, tiny domain package, JUnit 5 tests for core logic, SLF4J + Logback (no System.out), README with mvn build/test instructions, conventional src/main/java and src/test/java layout.",
  "mode": "build",
  "backend": "opl-ai-team",
  "metadata": { "sample": "java-small-project-update" }
}'

echo "POST ${API}/api/jobs"
resp="$(curl -sS -X POST "${API}/api/jobs" \
  -H 'Content-Type: application/json' \
  -d "${BODY}")"

echo "${resp}" | python3 -m json.tool 2>/dev/null || echo "${resp}"

job_id="$(echo "${resp}" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])")"
echo ""
echo "Track: GET ${API}/api/jobs/${job_id}"
echo "UI:    http://localhost:3000/dashboard (look for job ${job_id})"
