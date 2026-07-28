#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   GITHUB_TOKEN=<token> \
#   WEBHOOK_SECRET=<same as SELF_HEAL_WEBHOOK_SECRET> \
#   ./scripts/trigger-self-heal-dispatch.sh

OWNER="${OWNER:-VianaCoder}"
REPO="${REPO:-togglemaster-monorepo}"
EVENT_TYPE="${EVENT_TYPE:-self-heal-auth-service}"
NAMESPACE="${NAMESPACE:-ns-auth}"
DEPLOYMENT="${DEPLOYMENT:-auth-service}"
REASON="${REASON:-alert high http 500 rate}"

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${WEBHOOK_SECRET:?WEBHOOK_SECRET is required}"

curl -sS -X POST "https://api.github.com/repos/${OWNER}/${REPO}/dispatches" \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "{\"event_type\":\"${EVENT_TYPE}\",\"client_payload\":{\"secret\":\"${WEBHOOK_SECRET}\",\"namespace\":\"${NAMESPACE}\",\"deployment\":\"${DEPLOYMENT}\",\"status\":\"firing\",\"reason\":\"${REASON}\"}}"

echo "repository_dispatch sent: ${EVENT_TYPE}"
