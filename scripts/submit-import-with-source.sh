#!/usr/bin/env bash
# Import & iterate: attach existing source (ZIP and/or GitHub clone), then run import analysis.
# After analysis completes, use the Studio Files / Refine UI (or refinement API) for file edits.
#
# Requires backend with import_flow (Flask): register_blueprint(import_bp), mode=import in create_job.
# If you only run opl-ai-software-team without that code, merge from crew-coding-bots or use UI once wired.
#
# Usage:
#   export CREW_API_URL=http://localhost:8080
#   export SOURCE_ZIP=./my-app.zip        # optional if GITHUB_URL set
#   export GITHUB_URL=https://github.com/org/repo
#   export VISION="Optional context for the team"
#   ./scripts/submit-import-with-source.sh

set -euo pipefail
API="${CREW_API_URL:-http://localhost:8080}"

VISION="${VISION:-[Import] Existing codebase}"

if [[ -z "${SOURCE_ZIP:-}" && -z "${GITHUB_URL:-}" ]]; then
  echo "Set SOURCE_ZIP and/or GITHUB_URL" >&2
  exit 1
fi

args=( -sS -X POST "${API}/api/jobs" )
args+=( -F "vision=${VISION}" )
args+=( -F "mode=import" )
args+=( -F "backend=opl-ai-team" )
[[ -n "${SOURCE_ZIP:-}" ]] && args+=( -F "source_archive=@${SOURCE_ZIP}" )
[[ -n "${GITHUB_URL:-}" ]] && args+=( -F "github_urls=${GITHUB_URL}" )

echo "POST ${API}/api/jobs (multipart, mode=import)"
resp="$(curl "${args[@]}")"
echo "${resp}" | python3 -m json.tool 2>/dev/null || echo "${resp}"

JOB_ID="$(echo "${resp}" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])")"
echo ""
echo "Start import analysis (tech stack + index):"
echo "  curl -sS -X POST '${API}/api/jobs/${JOB_ID}/analyze'"
echo ""
echo "Then open Files / Refine for job ${JOB_ID} in the UI."
