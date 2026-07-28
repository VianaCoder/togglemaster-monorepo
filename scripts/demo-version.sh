#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${ENDPOINT:-https://api.gvianalourenco.xyz}"

# --- 1. Pega a MASTER_KEY do cluster ---
echo "Buscando MASTER_KEY do cluster..."
MASTER_KEY=$(kubectl get secret auth-secret -n ns-auth \
  -o jsonpath='{.data.MASTER_KEY}' | base64 -d)

# --- 2. Cria uma API key ---
echo ""
echo "==> Criando API key..."
curl -si -X POST "$ENDPOINT/auth/admin/keys" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name": "demo-version-key"}'

API_KEY=$(curl -sf -X POST "$ENDPOINT/auth/admin/keys" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name": "demo-version-key2"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")

# --- 3. Testa o endpoint /version ---
echo ""
echo "==> GET $ENDPOINT/flags/version"
curl -si "$ENDPOINT/flags/version"

# --- 4. Testa um endpoint autenticado ---
echo ""
echo "==> GET $ENDPOINT/flags (autenticado)"
curl -si "$ENDPOINT/flags" \
  -H "Authorization: Bearer $API_KEY"
