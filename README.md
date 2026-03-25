# ToggleMaster Monorepo

Plataforma de Feature Flags baseada em microsservicos, com avaliacao em baixa latencia e pipeline assincrono de analytics.

## Visao Geral

O projeto e composto por cinco servicos principais:

- auth-service (Go): cria e valida API keys
- flag-service (Python): CRUD de feature flags
- targeting-service (Python): regras de segmentacao por flag
- evaluation-service (Go): endpoint de avaliacao com cache Redis e publicacao em SQS
- analytics-service (Python): worker que consome SQS e persiste eventos no DynamoDB

Infra de suporte:

- PostgreSQL para auth-service
- PostgreSQL para flag-service e targeting-service
- Redis para evaluation-service
- LocalStack (SQS + DynamoDB) para ambiente local

## Arquitetura

```text
Cliente
  -> evaluation-service
      -> Redis (cache)
      -> flag-service
      -> targeting-service
      -> SQS (evento)
          -> analytics-service
              -> DynamoDB

Admin
  -> auth-service
  -> flag-service
  -> targeting-service
```

## Estrutura

```text
.
|-- docker-compose.yml
|-- auth-service/
|-- flag-service/
|-- targeting-service/
|-- evaluation-service/
|-- analytics-service/
|-- k8s/
`-- scripts/
```

## Rodando Local com Docker Compose

### 1) Pre-requisitos

- Docker + Docker Compose
- curl
- bash (para os scripts em scripts/)

### 2) Subir o ambiente

```bash
docker compose up --build
```

Servicos locais:

- http://localhost:8001 (auth-service)
- http://localhost:8002 (flag-service)
- http://localhost:8003 (targeting-service)
- http://localhost:8004 (evaluation-service)
- http://localhost:8005 (analytics-service)

### 3) Criar chave para o evaluation-service

O evaluation-service precisa de uma API key para consultar flag-service e targeting-service.

```bash
curl -s -X POST http://localhost:8001/admin/keys \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer local-master-key-dev" \
  -d '{"name":"evaluation-service-key"}'
```

Depois, reinicie o evaluation-service com a chave recebida:

```bash
SERVICE_API_KEY="SUA_CHAVE" docker compose up -d --no-deps --force-recreate evaluation-service
```

## Teste End-to-End Local

Script principal:

- scripts/test-full-flow.sh

O fluxo valida:

- health checks de todos os servicos
- criacao e validacao de API key
- CRUD de flags
- CRUD de regras de targeting
- avaliacoes no evaluation-service
- validacao de cache no Redis
- verificacao de SQS e DynamoDB no LocalStack

Execucao:

```bash
MASTER_KEY=local-master-key-dev bash scripts/test-full-flow.sh
```

## Kubernetes / EKS

Os manifests ficam em k8s/ e estao separados por namespace/servico.

Namespaces:

- ns-auth
- ns-flag
- ns-targeting
- ns-evaluation
- ns-analytics

### Ingress

Rotas principais configuradas:

- /auth/* -> auth-service
- /flags* -> flag-service
- /targeting* -> targeting-service
- /evaluation -> evaluation-service
- /analytics/* -> analytics-service

### KEDA

O analytics-service utiliza autoscaling por fila SQS com ScaledObject:

- minReplicaCount: 0
- maxReplicaCount: 10

## Endpoints Principais

### auth-service

- GET /health
- POST /admin/keys
- GET /validate

### flag-service

- GET /health
- GET /flags
- POST /flags
- GET /flags/{name}
- PUT /flags/{name}

### targeting-service

- GET /health
- POST /rules
- GET /rules/{flag_name}
- PUT /rules/{flag_name}

### evaluation-service

- GET /health
- GET /evaluate?user_id=<id>&flag_name=<name>

### analytics-service

- GET /health
- worker assincrono de consumo da fila SQS

## Variaveis de Ambiente (Resumo)

### auth-service

- DATABASE_URL
- MASTER_KEY
- PORT

### flag-service

- DATABASE_URL
- AUTH_SERVICE_URL
- PORT

### targeting-service

- DATABASE_URL
- AUTH_SERVICE_URL
- PORT

### evaluation-service

- REDIS_URL
- FLAG_SERVICE_URL
- TARGETING_SERVICE_URL
- SERVICE_API_KEY
- AWS_SQS_URL
- AWS_REGION
- AWS_ENDPOINT_URL (local)
- PORT

### analytics-service

- AWS_SQS_URL
- AWS_DYNAMODB_TABLE
- AWS_REGION
- AWS_ENDPOINT_URL (local)
- AWS_ACCESS_KEY_ID
- AWS_SECRET_ACCESS_KEY
- PORT

## Seguranca

Recomendacoes para publicacao:

- Nunca commitar credenciais reais
- Usar placeholders em arquivos de configuracao versionados
- Rotacionar chaves e tokens se houver exposicao previa
- Proteger branches principais com review e secret scanning

## Licenca

Defina a licenca do projeto antes de publicar (exemplo: MIT).
