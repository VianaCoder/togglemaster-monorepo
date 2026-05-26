# GitOps

Este diretorio concentra os manifests do cluster.

## Estrutura

- `argocd/applications/`: Applications do Argo CD.
- `platform/`: namespaces, ingress e KEDA.
- `services/`: manifests por microsservico.

## Uso

Aplicar applications:

```bash
kubectl apply -f gitops/argocd/applications/
```

Aplicar recursos compartilhados:

```bash
kubectl apply -f gitops/platform/
```

## Segredos

Os valores reais nao ficam no repositorio.

- Os manifests mantem apenas a estrutura.
- Os secrets reais devem ser aplicados por CI/CD ou operacao manual controlada.
- As Applications usam `RespectIgnoreDifferences` para nao sobrescrever `data` e `stringData`.

## Fluxo

- CI publica imagem no ECR.
- CI atualiza tag em `gitops/services/<servico>/deployment.yaml`.
- Argo CD sincroniza no cluster.

## Comandos uteis

```bash
kubectl get application -n argocd
kubectl get application <name> -n argocd -o wide
kubectl logs -n argocd deployment/argocd-application-controller
```
