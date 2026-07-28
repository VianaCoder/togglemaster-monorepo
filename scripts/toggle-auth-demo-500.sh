#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ns-auth}"
DEPLOYMENT="${DEPLOYMENT:-auth-service}"
ENABLE="${ENABLE:-true}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found in PATH"
  exit 1
fi

case "$ENABLE" in
  true|false)
    ;;
  *)
    echo "Invalid ENABLE value: $ENABLE (use true or false)"
    exit 1
    ;;
esac

echo "Setting DEMO_FORCE_500_ENABLED=${ENABLE} on ${NAMESPACE}/${DEPLOYMENT}"
kubectl -n "$NAMESPACE" set env deploy/"$DEPLOYMENT" DEMO_FORCE_500_ENABLED="$ENABLE" >/dev/null

kubectl -n "$NAMESPACE" rollout status deploy/"$DEPLOYMENT" --timeout=300s

echo "Done"
echo "DEMO_FORCE_500_ENABLED=${ENABLE}"

echo "Test command:"
echo "curl -sk \"https://api.gvianalourenco.xyz/auth/health?force_500=true\" -w \"\\nHTTP=%{http_code}\\n\""
