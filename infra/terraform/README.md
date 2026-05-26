# ToggleMaster Terraform (Fase 3)

Estrutura Terraform separada para provisionar toda a infraestrutura AWS exigida na Fase 3:

- Networking: VPC, subnets publicas/privadas, Internet Gateway e route tables
- EKS: cluster e node groups (com IAM criado via Terraform para conta pessoal)
- Bancos: 3 RDS PostgreSQL, 1 ElastiCache Redis, 1 DynamoDB
- Mensageria: 1 fila SQS
- Repositorios: 5 repositórios ECR
- Estado remoto: backend S3 (com use_lockfile habilitado)

## Estrutura

- `environments/dev`: composicao do ambiente dev
- `modules/networking`: VPC e rede base
- `modules/eks`: cluster EKS e node groups
- `modules/rds`: 3 instancias PostgreSQL
- `modules/elasticache`: Redis
- `modules/dynamodb`: tabela de analytics
- `modules/sqs`: fila de eventos
- `modules/ecr`: repositórios de imagem

## Como usar

1. Edite `environments/dev/backend.tf` com bucket e caminho reais do state remoto.
2. Copie `environments/dev/terraform.tfvars.example` para um arquivo `terraform.tfvars` local e ajuste valores de regiao/tags.
3. Execute:

```bash
cd infra/terraform/environments/dev
terraform init
terraform validate
terraform plan
terraform apply
```

## Observacoes importantes

- Conta pessoal (padrao deste projeto):
  - `create_iam_roles = true` cria automaticamente as roles do EKS e node group.
  - Se preferir usar roles ja existentes, defina `create_iam_roles = false` e preencha `cluster_role_arn` e `node_role_arn`.
- RDS:
  - O modulo usa `manage_master_user_password = true`, evitando senha em texto plano no Terraform.
  - Os ARNs dos segredos gerados ficam no output `rds_master_user_secret_arns`.
- NAT Gateway:
  - `enable_nat_gateway = false` por padrao para reduzir custo fixo mensal.
  - Para manter o cluster funcional sem NAT, os nodes ficam em subnet publica por padrao (`use_public_node_group_subnets = true`).

## Perfil de custo minimo aplicado

- EKS com node group inicial de 1 no `t3.small`
- NAT Gateway desabilitado por padrao
- RDS com classe `db.t3.micro`
- Backup do RDS reduzido para 1 dia no ambiente dev
