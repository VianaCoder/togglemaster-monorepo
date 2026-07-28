#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-VianaCoder/togglemaster-monorepo}"
NAMESPACE="${NAMESPACE:-ns-auth}"
SA_TOKEN_SECRET="${SA_TOKEN_SECRET:-self-heal-runner-token}"
OUT_FILE="${OUT_FILE:-/tmp/self-heal-kubeconfig.yaml}"

token="$(kubectl -n "$NAMESPACE" get secret "$SA_TOKEN_SECRET" -o jsonpath='{.data.token}' | base64 -d)"
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"

cat > "$OUT_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: tm-eks
  cluster:
    server: ${server}
    insecure-skip-tls-verify: true
contexts:
- name: self-heal
  context:
    cluster: tm-eks
    namespace: ${NAMESPACE}
    user: self-heal-runner
current-context: self-heal
users:
- name: self-heal-runner
  user:
    token: ${token}
EOF

if [ ! -s "$OUT_FILE" ]; then
  echo "kubeconfig file is empty"
  exit 1
fi

kube_b64="$(base64 -w0 "$OUT_FILE")"
printf "%s" "$kube_b64" | gh secret set KUBE_CONFIG_B64 --repo "$REPO"

echo "KUBE_CONFIG_B64 updated for $REPO"
echo "kubeconfig bytes: $(wc -c < "$OUT_FILE")"
echo "base64 length: ${#kube_b64}"
