# =============================================================================
# Stage 1: Builder
# =============================================================================
FROM golang:1.25-alpine AS builder

WORKDIR /app

# Copy only the module manifest first to cache the download layer.
# Note: auth-service has no go.sum — go mod download will create it.
COPY go.mod ./
RUN go mod download

# Copy source and compile a static binary
COPY . .
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o auth-service .

# =============================================================================
# Stage 2: Runtime (minimal image)
# =============================================================================
FROM alpine:3.19

# ca-certificates is needed for outbound TLS calls; tzdata for correct timestamps
RUN apk --no-cache add ca-certificates tzdata

WORKDIR /app

COPY --from=builder /app/auth-service .

# OpenTelemetry environment variables (can be overridden at pod runtime)
ENV OTEL_EXPORTER_OTLP_ENDPOINT="opentelemetry-collector.monitoring.svc.cluster.local:4317"
ENV OTEL_EXPORTER_OTLP_INSECURE="true"
ENV OTEL_SERVICE_NAME="auth-service"
ENV OTEL_LOG_LEVEL="info"

EXPOSE 8001

CMD ["./auth-service"]
