# Integração do Grafana/Prometheus com PagerDuty

## Pré-requisitos

1. **Conta PagerDuty ativa** com ao menos um serviço criado
2. **Integration Key** do PagerDuty (Events API v2)

## Passo 1: Obter a Integration Key do PagerDuty

1. Acesse https://pagerduty.com
2. Vá em **Services** → selecione seu serviço (ou crie um novo)
3. Clique em **Integrations** → **Add Integration**
4. Escolha **Events API v2**
5. Copie a **Integration Key** (formato: `xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`)

## Passo 2: Criar o Secret no Kubernetes

Execute no seu cluster:

```bash
kubectl create secret generic alertmanager-pagerduty \
  -n monitoring \
  --from-literal=integration-key='<SUA_PAGERDUTY_INTEGRATION_KEY>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Passo 3: Aplicar a Configuração do Alertmanager

O arquivo `alertmanager-pagerduty-config.yaml` já está no repositório. Aplique-o:

```bash
kubectl apply -f gitops/monitoring/config/alertmanager-pagerduty-config.yaml
```

## Passo 4: Atualizar o Alertmanager do kube-prometheus-stack

O Alertmanager precisa ler a configuração que criamos. Vá para o terminal e patch:

```bash
kubectl patch secret alertmanager-kube-prometheus-stack \
  -n monitoring \
  -p "{\"data\":{\"alertmanager.yaml\":$(cat gitops/monitoring/config/alertmanager-pagerduty-config.yaml | base64)}}"
```

**OU** atualize o `values.yaml` do kube-prometheus-stack para incluir:

```yaml
alertmanager:
  configSecretName: alertmanager-config
  alertmanagerSpec:
    volumes:
      - name: pagerduty-secret
        secret:
          secretName: alertmanager-pagerduty
      - name: discord-secret
        secret:
          secretName: alertmanager-discord  # opcional
    volumeMounts:
      - name: pagerduty-secret
        mountPath: /etc/alertmanager/secrets/pagerduty
        readOnly: true
      - name: discord-secret
        mountPath: /etc/alertmanager/secrets/discord
        readOnly: true
```

## Passo 5: Verificar a Integração

1. Acesse **Grafana** → **Alerting** → **Alert Rules**
2. Confirme que os rules estão sendo avaliados
3. Trigger um alerta teste (ex: escalando a latência de forma artificial)
4. Verifique no **PagerDuty Console** se o incidente foi criado

## Passo 6: (Opcional) Integrar Grafana Contact Points com PagerDuty

Se quiser também usar os alertas nativos do Grafana (não apenas Prometheus):

1. Grafana → **Administration** → **Contact points** → **Add contact point**
2. Type: **PagerDuty**
3. Integration Key: (mesma do passo 1)
4. Salve

Depois crie **Notification policies** em **Alerting** → **Notification policies** para rotear alertas para esse contact point.

## Regras de Alerta Configuradas

### `HighHTTP500RateIngress` (CRÍTICO)
- **Condição**: >0.05 req/s com status 5xx por 2 minutos
- **Ação**: Envia imediatamente para PagerDuty, escalação cada 1h
- **Grupos por**: ingress, service, namespace

### `HTTP500RateWarning` (WARNING)
- **Condição**: >0.01 req/s com status 5xx por 5 minutos
- **Ação**: Envia para Discord (aviso prevencional)

### Inibição de Alertas
- WARNING é inibido se há CRITICAL do mesmo job
- Todos os alertas de pod são inibidos se o nó estiver NotReady

## Monitoramento

**Verifique o status do Alertmanager:**
```bash
# Logs
kubectl logs -n monitoring alertmanager-kube-prometheus-stack-0 -f

# Acessar UI do Alertmanager
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
# Acesse http://localhost:9093
```

## Troubleshooting

| Problema | Solução |
|----------|---------|
| Alerta não chega ao PagerDuty | Verifique a Integration Key no Secret (`kubectl get secret alertmanager-pagerduty -n monitoring -o yaml`) |
| Alertas agrupados demais / pouco | Ajuste `group_wait` e `repeat_interval` na seção `route` |
| PagerDuty recebe spam | Aumente `group_wait` ou use `inhibit_rules` para agrupar |
| Alertmanager não reinicia | Valide YAML com `kubectl apply -f --dry-run=client` |

