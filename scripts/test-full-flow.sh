#!/usr/bin/env bash
set -euo pipefail

AUTH_URL="http://localhost:8001"
FLAG_URL="http://localhost:8002"
TARGET_URL="http://localhost:8003"
EVAL_URL="http://localhost:8004"
ANALYTICS_URL="http://localhost:8005"
MASTER_KEY="${MASTER_KEY:-CHANGE_ME_MASTER_KEY}"
FLAG_NAME="enable-new-dashboard"
COMPOSE_DIR="$(cd "$(dirname "$0")/.." ; pwd)"

PASS=0; FAIL=0

step()  { echo; echo "> $*"; }
ok()    { echo "  OK  $*"; ((++PASS)) ; true; }
fail()  { echo "  ERR $*"; ((++FAIL)) ; true; }
info()  { echo "  $*"; }

assert_http() {
  local label="$1" expected="$2" method="$3" url="$4"
  shift 4
  local args=(-s -o /tmp/tm_body.txt -w "%{http_code}" -X "$method" "$url")
  while [[ $# -gt 0 && "$1" != "--body" ]]; do
    args+=(-H "$1"); shift
  done
  if [[ $# -gt 0 && "$1" == "--body" ]]; then
    shift
    args+=(-d "$1")
  fi
  local got; got=$(curl "${args[@]}")
  if [[ "$got" == "$expected" ]]; then
    ok "$label -> HTTP $got"
    cat /tmp/tm_body.txt
    echo
  else
    fail "$label -> esperado HTTP $expected, obteve HTTP $got"
    info "Body: $(cat /tmp/tm_body.txt)"
  fi
}

assert_http_any() {
  local label="$1" expected_csv="$2" method="$3" url="$4"
  shift 4
  local args=(-s -o /tmp/tm_body.txt -w "%{http_code}" -X "$method" "$url")
  while [[ $# -gt 0 && "$1" != "--body" ]]; do
    args+=(-H "$1"); shift
  done
  if [[ $# -gt 0 && "$1" == "--body" ]]; then
    shift
    args+=(-d "$1")
  fi

  local got; got=$(curl "${args[@]}")
  if [[ ",$expected_csv," == *",$got,"* ]]; then
    ok "$label -> HTTP $got"
    cat /tmp/tm_body.txt
    echo
  else
    fail "$label -> esperado HTTP um de [$expected_csv], obteve HTTP $got"
    info "Body: $(cat /tmp/tm_body.txt)"
  fi
}

step "1/7 Health checks"
for svc in "$AUTH_URL" "$FLAG_URL" "$TARGET_URL" "$EVAL_URL" "$ANALYTICS_URL"; do
  code=$(curl -s -o /tmp/tm_body.txt -w "%{http_code}" "$svc/health")
  body=$(cat /tmp/tm_body.txt)
  if [[ "$code" == "200" ]]; then
    ok "$svc/health -> $code  $body"
  else
    fail "$svc/health -> $code  $body"
  fi
done

step "2/7 Auth key"
RESPONSE=$(curl -s -X POST "$AUTH_URL/admin/keys" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -d '{"name":"integration-test-key"}')
info "Auth response received"

API_KEY=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['key'])" 2>/dev/null ; true)
if [[ -n "$API_KEY" ]]; then
  ok "Key criada: ${API_KEY:0:20}..."
else
  fail "Nao foi possivel extrair a chave"
  exit 1
fi

assert_http "Validar chave valida" "200" "GET" "$AUTH_URL/validate" \
  "Authorization: Bearer $API_KEY"

assert_http "Rejeitar chave invalida" "401" "GET" "$AUTH_URL/validate" \
  "Authorization: Bearer chave-errada-000"

step "3/7 Flag CRUD"

assert_http "Rejeitar sem chave" "401" "GET" "$FLAG_URL/flags"

assert_http_any "Criar flag '$FLAG_NAME' (idempotente)" "201,409" "POST" "$FLAG_URL/flags" \
  "Content-Type: application/json" "Authorization: Bearer $API_KEY" \
  --body "{\"name\":\"$FLAG_NAME\",\"description\":\"Ativa o novo dashboard\",\"is_enabled\":true}"

assert_http "Listar flags" "200" "GET" "$FLAG_URL/flags" \
  "Authorization: Bearer $API_KEY"

assert_http "Buscar flag por nome" "200" "GET" "$FLAG_URL/flags/$FLAG_NAME" \
  "Authorization: Bearer $API_KEY"

assert_http "Desativar flag (PUT)" "200" "PUT" "$FLAG_URL/flags/$FLAG_NAME" \
  "Content-Type: application/json" "Authorization: Bearer $API_KEY" \
  --body '{"is_enabled":false}'

assert_http "Reativar flag (PUT)" "200" "PUT" "$FLAG_URL/flags/$FLAG_NAME" \
  "Content-Type: application/json" "Authorization: Bearer $API_KEY" \
  --body '{"is_enabled":true}'

step "4/7 Targeting rules"

assert_http_any "Criar regra PERCENTAGE 50% (idempotente)" "201,409" "POST" "$TARGET_URL/rules" \
  "Content-Type: application/json" "Authorization: Bearer $API_KEY" \
  --body "{\"flag_name\":\"$FLAG_NAME\",\"is_enabled\":true,\"rules\":{\"type\":\"PERCENTAGE\",\"value\":50}}"

assert_http "Buscar regra" "200" "GET" "$TARGET_URL/rules/$FLAG_NAME" \
  "Authorization: Bearer $API_KEY"

assert_http "Atualizar regra para 75%" "200" "PUT" "$TARGET_URL/rules/$FLAG_NAME" \
  "Content-Type: application/json" "Authorization: Bearer $API_KEY" \
  --body '{"rules":{"type":"PERCENTAGE","value":75}}'

step "5/7 Evaluation"
info "Reiniciando evaluation-service com SERVICE_API_KEY"
cd "$COMPOSE_DIR"
if SERVICE_API_KEY="$API_KEY" docker compose up -d --no-deps --force-recreate evaluation-service >/tmp/tm_eval_restart.log 2>&1; then
  ok "evaluation-service reiniciado"
else
  fail "Falha ao reiniciar evaluation-service"
  tail -n 20 /tmp/tm_eval_restart.log | sed 's/^/    /'
  exit 1
fi

sleep 2

USERS=("user-alpha" "user-beta" "user-gamma" "user-delta" "user-epsilon" "user-123" "user-abc" "user-xyz")
for uid in "${USERS[@]}"; do
  code=$(curl -s -o /tmp/tm_body.txt -w "%{http_code}" \
    "$EVAL_URL/evaluate?user_id=$uid&flag_name=$FLAG_NAME")
  body=$(cat /tmp/tm_body.txt)
  result=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result','?'))" 2>/dev/null || echo "erro")
  if [[ "$code" == "200" ]]; then
    ok "user=$uid -> result=$result"
  else
    fail "user=$uid -> HTTP $code  $body"
  fi
done

step "5b/7 Cache Redis validation"
redis_key="flag_info:$FLAG_NAME"

code=$(curl -s -o /tmp/tm_body.txt -w "%{http_code}" \
  "$EVAL_URL/evaluate?user_id=user-alpha&flag_name=$FLAG_NAME")
body=$(cat /tmp/tm_body.txt)
ok "Chamada 1 (prime lookup) -> HTTP $code  $body"

cached=$(docker exec tm-redis redis-cli get "$redis_key" 2>/dev/null || echo "")
if [[ -n "$cached" ]]; then
  ok "Redis key preenchida: '$redis_key'"
else
  fail "Redis key ausente: '$redis_key'"
fi

code=$(curl -s -o /tmp/tm_body.txt -w "%{http_code}" \
  "$EVAL_URL/evaluate?user_id=user-alpha&flag_name=$FLAG_NAME")
ok "Chamada 2 (cached metadata expected) -> HTTP $code  $body"

step "6/7 Analytics health"
assert_http "Health analytics" "200" "GET" "$ANALYTICS_URL/health"

step "7/7 LocalStack SQS + DynamoDB"

info "SQS attributes:"
SQS_ATTRS=$(curl -s "http://localhost:4566/000000000000/toggle-master-events?Action=GetQueueAttributes&AttributeName.1=ApproximateNumberOfMessages")
echo "    $SQS_ATTRS" | grep -o 'ApproximateNumberOfMessages[^<]*' | head -5 ; \
  true

info "DynamoDB count:"
docker exec tm-localstack awslocal dynamodb scan \
  --table-name ToggleMasterAnalytics \
  --select COUNT 2>/dev/null | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(f'    {d.get(\"Count\",0)} item(s)')" \
  2>/dev/null || info "DynamoDB sem itens ainda"

echo
echo "RESULTADO"
echo "PASS=$PASS"
echo "FAIL=$FAIL"
if [[ $FAIL -eq 0 ]]; then
  echo "Todos os testes passaram"
else
  echo "Alguns testes falharam"
fi
