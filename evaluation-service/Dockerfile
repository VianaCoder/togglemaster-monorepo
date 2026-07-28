# =============================================================================
# Stage 1: Builder
# =============================================================================
FROM golang:1.25-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o evaluation-service .

# =============================================================================
# Stage 2: Runtime (minimal image)
# =============================================================================
FROM alpine:3.19

RUN apk --no-cache add ca-certificates tzdata

WORKDIR /app

COPY --from=builder /app/evaluation-service .

# OpenTelemetry environment variables (can be overridden at pod runtime)
ENV OTEL_EXPORTER_OTLP_ENDPOINT="opentelemetry-collector.monitoring.svc.cluster.local:4317"
ENV OTEL_EXPORTER_OTLP_INSECURE="true"
ENV OTEL_SERVICE_NAME="evaluation-service"
ENV OTEL_LOG_LEVEL="info"

EXPOSE 8004

CMD ["./evaluation-service"]
