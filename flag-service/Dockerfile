FROM python:3.11-slim

WORKDIR /app

# Install dependencies first for optimal layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# OpenTelemetry environment variables
ENV OTEL_EXPORTER_OTLP_ENDPOINT="opentelemetry-collector.monitoring.svc.cluster.local:4317"
ENV OTEL_EXPORTER_OTLP_INSECURE="true"
ENV OTEL_SERVICE_NAME="flag-service"
ENV OTEL_LOG_LEVEL="info"

EXPOSE 8002

CMD ["gunicorn", "--bind", "0.0.0.0:8002", "--workers", "2", "--timeout", "60", "app:app"]
