# Infra

Terraform para a infraestrutura AWS do projeto.

## Estrutura

- `terraform/environments/dev/`: composicao do ambiente.
- `terraform/modules/`: modulos reutilizaveis.

## Recursos principais

- VPC e rede.
- EKS.
- RDS.
- ElastiCache Redis.
- SQS.
- DynamoDB.
- ECR.

## Uso

```bash
cd infra/terraform/environments/dev
terraform init
terraform plan
terraform apply
```

## Outputs uteis

```bash
terraform output eks_cluster_name
terraform output rds_endpoints
terraform output redis_endpoint
```

## Observacoes

- Nao commitar `*.tfstate`, `.terraform/` ou planos salvos.
- Revisar sempre o `terraform plan` antes de aplicar.
- O estado remoto fica configurado em `backend.tf`.

