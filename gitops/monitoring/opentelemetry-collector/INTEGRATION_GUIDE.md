# OpenTelemetry Collector — Integration Guide

## Overview

The OpenTelemetry Collector runs in the `monitoring` namespace and provides a single ingestion point for all telemetry from ToggleMaster microservices.

## Service Endpoints

| Protocol | Port | Use Case |
|----------|------|----------|
| **OTLP gRPC** | 4317 | Primary protocol — metrics, logs, spans (from SDKs) |
| **OTLP HTTP** | 4318 | Alternative for HTTP-only clients |
| **Prometheus** | 8889 | Prometheus scrapes OTel's own metrics |
| **collector metrics** | 8888 | Internal OTel metrics (optional scrape) |

## Service Names

```
# Internal to cluster (within Kubernetes DNS):
opentelemetry-collector.monitoring.svc.cluster.local:4317
opentelemetry-collector.monitoring.svc.cluster.local:4318
```

## How to Integrate (done in Req 3)

### For Go Services (auth-service, evaluation-service)

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/metric"
    "go.opentelemetry.io/otel/sdk/trace"
)

// Metrics exporter
metricExporter, _ := otlpmetricgrpc.New(ctx,
    otlpmetricgrpc.WithEndpoint("opentelemetry-collector.monitoring.svc.cluster.local:4317"),
)
meterProvider := metric.NewMeterProvider(metric.WithReader(
    metric.NewPeriodicReader(metricExporter),
))

// Traces exporter
traceExporter, _ := otlptracegrpc.New(ctx,
    otlptracegrpc.WithEndpoint("opentelemetry-collector.monitoring.svc.cluster.local:4317"),
)
tracerProvider := trace.NewTracerProvider(
    trace.WithBatcher(traceExporter),
)

otel.SetMeterProvider(meterProvider)
otel.SetTracerProvider(tracerProvider)
```

### For Python Services (flag-service, targeting-service, analytics-service)

```python
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

# Metrics
metric_exporter = OTLPMetricExporter(
    endpoint="opentelemetry-collector.monitoring.svc.cluster.local:4317"
)
metrics.set_meter_provider(MeterProvider(
    metric_readers=[PeriodicExportingMetricReader(metric_exporter)]
))

# Traces
trace_exporter = OTLPSpanExporter(
    endpoint="opentelemetry-collector.monitoring.svc.cluster.local:4317"
)
tracer_provider = TracerProvider()
tracer_provider.add_span_processor(BatchSpanProcessor(trace_exporter))
trace.set_tracer_provider(tracer_provider)
```

## Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│ ToggleMaster Microservices (ns-auth, ns-flag, etc.)         │
│ ├─ auth-service                                              │
│ ├─ evaluation-service                                        │
│ ├─ flag-service                                              │
│ ├─ targeting-service                                         │
│ └─ analytics-service                                         │
└──────────────┬──────────────────────────────────────────────┘
               │
               │ OTLP/gRPC (port 4317)
               │ OTLP/HTTP (port 4318)
               ↓
┌─────────────────────────────────────────────────────────────┐
│ OpenTelemetry Collector (monitoring namespace)              │
│ ├─ Receivers: otlp (gRPC, HTTP)                             │
│ ├─ Processors: batch, memory_limiter, resourcedetection     │
│ └─ Exporters:                                                │
│    ├─ prometheus (→ :8889, scrape by Prometheus)            │
│    ├─ otlp/loki (→ Loki on port 4317)                       │
│    └─ otlp/traces (→ APM backend in Req 3)                  │
└──────────────┬──────────────────────────────────────────────┘
               │
       ┌───────┼───────┬──────────────┐
       │       │       │              │
       ↓       ↓       ↓              ↓
   Prometheus  Loki   APM           Logging
   (metrics)  (logs) (traces)      (debug)
```

## Configuration Update in Req 3

When APM is onboarded (New Relic or Datadog), update the `otlp/traces` exporter in [values.yaml](../opentelemetry-collector/values.yaml#L67) from `localhost:4317` to the actual APM backend:

```yaml
exporters:
  otlp/traces:
    client:
      endpoint: otlp.nr-data.net:4317  # New Relic example
      # or: endpoint: api.datadoghq.eu:443  # Datadog example
```

Then re-apply the Argo CD Application to redeploy the collector with the new endpoint.

## Verification

```bash
# Check OTel Collector pod status
kubectl -n monitoring get pods -l app.kubernetes.io/name=opentelemetry-collector

# View OTel Collector logs
kubectl -n monitoring logs -f deployment/opentelemetry-collector

# Port-forward to test local access
kubectl -n monitoring port-forward svc/opentelemetry-collector 4317:4317

# Check Prometheus scrape config
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# Visit http://localhost:9090/targets → Look for "opentelemetry-collector"

# Check that metrics are flowing into Prometheus
# Query: up{job="opentelemetry-collector"}
```

## Kubernetes Service Details

```yaml
# Service auto-created by Helm chart:
apiVersion: v1
kind: Service
metadata:
  name: opentelemetry-collector
  namespace: monitoring
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: opentelemetry-collector
  ports:
    - name: otlp-grpc
      port: 4317
      protocol: TCP
    - name: otlp-http
      port: 4318
      protocol: TCP
    - name: prometheus
      port: 8889
      protocol: TCP
    - name: metrics
      port: 8888
      protocol: TCP
```

## Troubleshooting Connection Issues

If microservices fail to connect:

1. **Check Pod Network**: `kubectl -n monitoring logs -f deployment/opentelemetry-collector` for receiver errors
2. **Verify DNS**: From a service pod, run `nslookup opentelemetry-collector.monitoring.svc.cluster.local`
3. **Check Firewall/NetworkPolicy**: Ensure no egress restrictions block port 4317 from service namespaces to monitoring namespace
4. **Port Conflicts**: `kubectl get svc -n monitoring -o wide` to see all ports

