#!/usr/bin/env bash
set -euo pipefail

# Demo script: intentionally creates a short auth-service outage to generate 5xx,
# so Grafana/Alertmanager/PagerDuty + self-healing can be demonstrated.
#
# Usage:
#   ./scripts/demo-auth-incident.sh
#
# Optional env vars:
#   ENDPOINT=https://api.gvianalourenco.xyz
#   TARGET_PATH=/auth/health
#   NAMESPACE=ns-auth
#   DEPLOYMENT=auth-service
#   AWS_REGION=us-east-1
#   EKS_CLUSTER_NAME=togglemaster-dev-eks
#   OUTAGE_SECONDS=150
#   QPS=20
#   FORCE=true
#   AUTO_RESTORE=false

ENDPOINT="${ENDPOINT:-https://api.gvianalourenco.xyz}"
TARGET_PATH="${TARGET_PATH:-/auth/health}"
NAMESPACE="${NAMESPACE:-ns-auth}"
DEPLOYMENT="${DEPLOYMENT:-auth-service}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-togglemaster-dev-eks}"
OUTAGE_SECONDS="${OUTAGE_SECONDS:-150}"
QPS="${QPS:-20}"
FORCE="${FORCE:-false}"
AUTO_RESTORE="${AUTO_RESTORE:-false}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found in PATH"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found in PATH"
  exit 1
fi

ensure_kubectl_auth() {
  if kubectl auth can-i get deployments -n "$NAMESPACE" >/dev/null 2>&1; then
    return
  fi

  echo "kubectl auth expired or unavailable. Refreshing kubeconfig for ${EKS_CLUSTER_NAME}..."

  if ! command -v aws >/dev/null 2>&1; then
    echo "aws CLI not found in PATH"
    exit 1
  fi

  aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

  if ! kubectl auth can-i get deployments -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Unable to authenticate kubectl for ${EKS_CLUSTER_NAME}"
    echo "Run manually: aws eks update-kubeconfig --name ${EKS_CLUSTER_NAME} --region ${AWS_REGION}"
    exit 1
  fi
}

ensure_kubectl_auth

if [ "$FORCE" != "true" ]; then
  cat <<MSG
This script is DISRUPTIVE and will scale ${NAMESPACE}/${DEPLOYMENT} to 0 temporarily
for ~${OUTAGE_SECONDS}s to generate real 5xx for incident demo.

Run again with FORCE=true to continue.
MSG
  exit 1
fi

ORIGINAL_REPLICAS="$(kubectl -n "$NAMESPACE" get deploy "$DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
if [ -z "$ORIGINAL_REPLICAS" ]; then
  echo "Could not read original replica count"
  exit 1
fi

RESTORED=false
restore() {
  if [ "$RESTORED" = true ]; then
    return
  fi
  echo "[restore] Scaling ${NAMESPACE}/${DEPLOYMENT} back to ${ORIGINAL_REPLICAS}"
  kubectl -n "$NAMESPACE" scale deploy "$DEPLOYMENT" --replicas="$ORIGINAL_REPLICAS" >/dev/null
  kubectl -n "$NAMESPACE" rollout status deploy/"$DEPLOYMENT" --timeout=300s >/dev/null || true
  RESTORED=true
}

if [ "$AUTO_RESTORE" = "true" ]; then
  trap restore EXIT INT TERM
fi

echo "[1/5] Current replicas: ${ORIGINAL_REPLICAS}"
echo "[2/5] Scaling ${NAMESPACE}/${DEPLOYMENT} to 0"
kubectl -n "$NAMESPACE" scale deploy "$DEPLOYMENT" --replicas=0 >/dev/null
kubectl -n "$NAMESPACE" rollout status deploy/"$DEPLOYMENT" --timeout=180s >/dev/null || true

echo "[3/5] Generating outage traffic for ${OUTAGE_SECONDS}s at ~${QPS} req/s"
START_TS="$(date +%s)"
TOTAL=0
ERR5XX=0
declare -A CODES=()

while true; do
  NOW_TS="$(date +%s)"
  ELAPSED=$((NOW_TS - START_TS))
  if [ "$ELAPSED" -ge "$OUTAGE_SECONDS" ]; then
    break
  fi

  i=0
  while [ "$i" -lt "$QPS" ]; do
    code="$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
      "${ENDPOINT}${TARGET_PATH}" || true)"
    if [ -z "$code" ]; then
      code="000"
    fi
    TOTAL=$((TOTAL + 1))
    CODES["$code"]=$(( ${CODES["$code"]:-0} + 1 ))
    if [ "$code" -ge 500 ] 2>/dev/null && [ "$code" -lt 600 ] 2>/dev/null; then
      ERR5XX=$((ERR5XX + 1))
    fi
    i=$((i + 1))
  done

  sleep 1
done

if [ "$AUTO_RESTORE" = "true" ]; then
  echo "[4/5] Restoring deployment"
  restore
else
  echo "[4/5] Not restoring deployment. Waiting for self-healing automation."
fi

echo "[5/5] Demo finished"
if [ "$TOTAL" -gt 0 ]; then
  RATE="$(awk -v e="$ERR5XX" -v t="$TOTAL" 'BEGIN { printf "%.2f", (e/t)*100 }')"
else
  RATE="0.00"
fi

echo "Requests sent: ${TOTAL}"
echo "5xx responses: ${ERR5XX}"
echo "Approx 5xx rate: ${RATE}%"
echo "Response code breakdown:"
for k in "${!CODES[@]}"; do
  echo "  ${k}: ${CODES[$k]}"
done | sort

if [ "$ERR5XX" -eq 0 ]; then
  echo ""
  echo "No 5xx observed. Try one of these options:"
  echo "- Increase OUTAGE_SECONDS to 240 and QPS to 40"
  echo "- Change TARGET_PATH to another auth route mapped in ingress"
  echo "- Check if the ingress path for auth differs from ${TARGET_PATH}"
  echo "- Confirm the alert is watching 5xx (especially 503), not only 500"
fi

