#!/usr/bin/env bash
# Refactor job: architect + executor pipeline toward a new *target_stack*.
# For **Import & iterate** (existing repo → analyze → Refine/file edits), use instead:
#   scripts/submit-import-with-source.sh
#
# Prerequisites: backend with Flask multipart create_job + refactor blueprint.
#
# Usage:
#   export CREW_API_URL=http://localhost:8080
#   export SOURCE_ZIP=./my-java-app.zip          # optional if GITHUB_URL set
#   export GITHUB_URL=https://github.com/org/repo # optional if SOURCE_ZIP set
#   ./scripts/submit-refactor-with-source.sh
#
# After 201, start refactor (target_stack is required by the API):
#   curl -sS -X POST "${CREW_API_URL}/api/jobs/${JOB_ID}/refactor" \
#     -H 'Content-Type: application/json' \
#     -d '{"target_stack": "Java 17 + Maven; add JUnit 5 and SLF4J as described in vision"}'

set -euo pipefail
API="${CREW_API_URL:-http://localhost:8080}"

VISION="${VISION:-Refactor and improve this codebase per team standards. Preserve behavior; add tests and structured logging where appropriate.}"

if [[ -z "${SOURCE_ZIP:-}" && -z "${GITHUB_URL:-}" ]]; then
  echo "Set SOURCE_ZIP and/or GITHUB_URL" >&2
  exit 1
fi

# curl -F for multipart (Flask create_job)
args=( -sS -X POST "${API}/api/jobs" )
args+=( -F "vision=${VISION}" )
args+=( -F "mode=refactor" )
args+=( -F "backend=opl-ai-team" )
[[ -n "${SOURCE_ZIP:-}" ]] && args+=( -F "source_archive=@${SOURCE_ZIP}" )
[[ -n "${GITHUB_URL:-}" ]] && args+=( -F "github_urls=${GITHUB_URL}" )

echo "POST ${API}/api/jobs (multipart, mode=refactor)"
resp="$(curl "${args[@]}")"
echo "${resp}" | python3 -m json.tool 2>/dev/null || echo "${resp}"

JOB_ID="$(echo "${resp}" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])")"
echo ""
echo "Job ${JOB_ID} is waiting at phase awaiting_refactor with source in workspace."
echo "Start refactor runner:"
echo "  curl -sS -X POST '${API}/api/jobs/${JOB_ID}/refactor' -H 'Content-Type: application/json' \\"
echo "    -d '{\"target_stack\": \"Describe target stack and goals here\"}'"
