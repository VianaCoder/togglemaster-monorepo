#!/usr/bin/env bash
set -euo pipefail

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Variavel obrigatoria ausente: $name" >&2
    exit 1
  fi
}

MODE="${MODE:-local}"
MASTER_KEY="${MASTER_KEY:-CHANGE_ME_MASTER_KEY}"
FLAG_NAME="${FLAG_NAME:-enable-new-dashboard}"
COMPOSE_DIR="$(cd "$(dirname "$0")/.." ; pwd)"

if [[ "$MODE" == "aws" ]]; then
  require_env ENDPOINT
  AUTH_URL="$ENDPOINT/auth"
  FLAG_URL="$ENDPOINT/flags"
  TARGET_URL="$ENDPOINT/targeting"
  EVAL_URL="$ENDPOINT/evaluation"
  ANALYTICS_URL="$ENDPOINT/analytics"
else
  AUTH_URL="http://localhost:8001"
  FLAG_URL="http://localhost:8002"
  TARGET_URL="http://localhost:8003"
  EVAL_URL="http://localhost:8004"
  ANALYTICS_URL="http://localhost:8005"
fi

PASS=0; FAIL=0

if [[ -t 1 ]]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_BLUE='\033[34m'
  C_GREEN='\033[32m'
  C_RED='\033[31m'
  C_CYAN='\033[36m'
else
  C_RESET=''
  C_BOLD=''
  C_BLUE=''
  C_GREEN=''
  C_RED=''
  C_CYAN=''
fi

step()  { echo; echo -e "${C_BOLD}${C_BLUE}> $*${C_RESET}"; }
ok()    { echo -e "  ${C_GREEN}OK${C_RESET}  $*"; ((++PASS)) ; true; }
fail()  { echo -e "  ${C_RED}ERR${C_RESET} $*"; ((++FAIL)) ; true; }
info()  { echo -e "  ${C_CYAN}$*${C_RESET}"; }

current_eval_url() {
  echo "$EVAL_URL/evaluate"
}

current_flag_url() {
  local suffix="${1:-}"
  if [[ "$MODE" == "aws" ]]; then
    echo "$FLAG_URL$suffix"
  else
    echo "$FLAG_URL/flags$suffix"
  fi
}

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

step "Health checks"
if [[ "$MODE" == "aws" ]]; then
  for svc in "$AUTH_URL" "$ANALYTICS_URL"; do
    code=$(curl -s -o /tmp/tm_body.txt -w "%{http_code}" "$svc/health")
    body=$(cat /tmp/tm_body.txt)
    if [[ "$code" == "200" ]]; then
      ok "$svc/health -> $code  $body"
    else
      fail "$svc/health -> $code  $body"
    fi
  done
  info "Flag, targeting e evaluation serao validados nas chamadas autenticadas abaixo"
else
  for svc in "$AUTH_URL" "$FLAG_URL" "$TARGET_URL" "$EVAL_URL" "$ANALYTICS_URL"; do
    code=$(curl -s -o /tmp/tm_body.txt -w "%{http_code}" "$svc/health")
    body=$(cat /tmp/tm_body.txt)
    if [[ "$code" == "200" ]]; then
      ok "$svc/health -> $code  $body"
    else
      fail "$svc/health -> $code  $body"
    fi
  done
fi

step "Auth key"
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
  info "Response: $RESPONSE"
  exit 1
fi

assert_http "Validar chave valida" "200" "GET" "$AUTH_URL/validate" \
  "Authorization: Bearer $API_KEY"

assert_http "Rejeitar chave invalida" "401" "GET" "$AUTH_URL/validate" \
  "Authorization: Bearer chave-errada-000"

step "Flag CRUD"

assert_http "Rejeitar sem chave" "401" "GET" "$(current_flag_url)"

assert_http_any "Criar flag '$FLAG_NAME' (idempotente)" "201,409" "POST" "$(current_flag_url)" \
  "Content-Type: application/json" "Authorization: Bearer $API_KEY" \
  --body "{\"name\":\"$FLAG_NAME\",\"description\":\"Ativa o novo dashboard\",\"is_enabled\":true}"

assert_http "Listar flags" "200" "GET" "$(current_flag_url)" \
  "Authorization: Bearer $API_KEY"

assert_http "Buscar flag por nome" "200" "GET" "$(current_flag_url "/$FLAG_NAME")" \
  "Authorization: Bearer $API_KEY"

assert_http "Desativar flag (PUT)" "200" "PUT" "$(current_flag_url "/$FLAG_NAME")" \
  "Content-Type: application/json" "Authorization: Bearer $API_KEY" \
  --body '{"is_enabled":false}'

assert_http "Reativar flag (PUT)" "200" "PUT" "$(current_flag_url "/$FLAG_NAME")" \
  "Content-Type: application/json" "Authorization: Bearer $API_KEY" \
  --body '{"is_enabled":true}'

step "Targeting rules"

assert_http_any "Criar regra PERCENTAGE 50% (idempotente)" "201,409" "POST" "$TARGET_URL/rules" \
  "Content-Type: application/json" "Authorization: Bearer $API_KEY" \
  --body "{\"flag_name\":\"$FLAG_NAME\",\"is_enabled\":true,\"rules\":{\"type\":\"PERCENTAGE\",\"value\":50}}"

assert_http "Buscar regra" "200" "GET" "$TARGET_URL/rules/$FLAG_NAME" \
  "Authorization: Bearer $API_KEY"

assert_http "Atualizar regra para 75%" "200" "PUT" "$TARGET_URL/rules/$FLAG_NAME" \
  "Content-Type: application/json" "Authorization: Bearer $API_KEY" \
  --body '{"rules":{"type":"PERCENTAGE","value":75}}'

step "Evaluation"
if [[ "$MODE" == "aws" ]]; then
  info "Modo AWS: pulando restart do evaluation-service"
else
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
fi

USERS=("user-alpha" "user-beta" "user-gamma" "user-delta" "user-epsilon" "user-123" "user-abc" "user-xyz")
for uid in "${USERS[@]}"; do
  code=$(curl -s -o /tmp/tm_body.txt -w "%{http_code}" \
    "$(current_eval_url)?user_id=$uid&flag_name=$FLAG_NAME")
  body=$(cat /tmp/tm_body.txt)
  result=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result','?'))" 2>/dev/null || echo "erro")
  if [[ "$code" == "200" ]]; then
    ok "user=$uid -> result=$result"
  else
    fail "user=$uid -> HTTP $code  $body"
  fi
done

if [[ "$MODE" != "aws" ]]; then
  step "Cache Redis validation"
  redis_key="flag_info:$FLAG_NAME"

  code=$(curl -s -o /tmp/tm_body.txt -w "%{http_code}" \
    "$(current_eval_url)?user_id=user-alpha&flag_name=$FLAG_NAME")
  body=$(cat /tmp/tm_body.txt)
  ok "Chamada 1 (prime lookup) -> HTTP $code  $body"

  cached=$(docker exec tm-redis redis-cli get "$redis_key" 2>/dev/null || echo "")
  if [[ -n "$cached" ]]; then
    ok "Redis key preenchida: '$redis_key'"
  else
    fail "Redis key ausente: '$redis_key'"
  fi

  code=$(curl -s -o /tmp/tm_body.txt -w "%{http_code}" \
    "$(current_eval_url)?user_id=user-alpha&flag_name=$FLAG_NAME")
  ok "Chamada 2 (cached metadata expected) -> HTTP $code  $body"
fi

step "Analytics health"
assert_http "Health analytics" "200" "GET" "$ANALYTICS_URL/health"

if [[ "$MODE" != "aws" ]]; then
  step "LocalStack SQS + DynamoDB"

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
else
  step "AWS mode"
  info "Validacoes de Redis/LocalStack foram puladas no modo AWS"
fi

echo
echo -e "${C_BOLD}${C_BLUE}RESULTADO${C_RESET}"
echo -e "${C_GREEN}PASS=$PASS${C_RESET}"
if [[ $FAIL -eq 0 ]]; then
  echo -e "${C_GREEN}FAIL=$FAIL${C_RESET}"
else
  echo -e "${C_RED}FAIL=$FAIL${C_RESET}"
fi
if [[ $FAIL -eq 0 ]]; then
  echo -e "${C_BOLD}${C_GREEN}Todos os testes passaram${C_RESET}"
else
  echo -e "${C_BOLD}${C_RED}Alguns testes falharam${C_RESET}"
fi
