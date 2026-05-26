# GitOps

Estrutura GitOps para deploy continuo com ArgoCD.

## Estrutura

- `gitops/platform`: namespaces, ingress e KEDA
- `gitops/services/*`: manifests dos 5 microsservicos
- `gitops/argocd/applications`: Applications do ArgoCD

## Instalar ArgoCD no EKS

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd -n argocd --set server.service.type=LoadBalancer
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-application-controller --timeout=300s
```

## Criar Applications no ArgoCD

```bash
kubectl apply -f gitops/argocd/applications/platform.yaml
kubectl apply -f gitops/argocd/applications/auth-service.yaml
kubectl apply -f gitops/argocd/applications/flag-service.yaml
kubectl apply -f gitops/argocd/applications/targeting-service.yaml
kubectl apply -f gitops/argocd/applications/evaluation-service.yaml
kubectl apply -f gitops/argocd/applications/analytics-service.yaml
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
