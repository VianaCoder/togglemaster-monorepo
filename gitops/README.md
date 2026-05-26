# GitOps

Estrutura GitOps para deploy continuo com ArgoCD.

## Estrutura

- `gitops/platform`: namespaces, ingress e KEDA
- `gitops/services/*`: manifests dos 5 microsservicos
- `gitops/argocd/applications`: Applications do ArgoCD

## Instalar ArgoCD no EKS

```bash
bash gitops/argocd/install.sh
```

## Criar Applications no ArgoCD

```bash
bash gitops/argocd/bootstrap-apps.sh
```

## Acessar interface do ArgoCD

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Abrir: `https://localhost:8080`

Senha inicial do admin:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Fluxo CD

- CI builda e envia imagem para ECR
- CI atualiza a tag da imagem em `gitops/services/<service>/deployment.yaml`
- ArgoCD detecta mudanca no repositório e sincroniza automaticamente no cluster
