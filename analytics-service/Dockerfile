FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
# Install dependencies, then upgrade boto3 to a version (>=1.28) that natively
# supports the AWS_ENDPOINT_URL environment variable — required for LocalStack.
RUN pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir "boto3>=1.28.0,<2.0.0"

COPY . .

# OpenTelemetry environment variables
ENV OTEL_EXPORTER_OTLP_ENDPOINT="opentelemetry-collector.monitoring.svc.cluster.local:4317"
ENV OTEL_EXPORTER_OTLP_INSECURE="true"
ENV OTEL_SERVICE_NAME="analytics-service"
ENV OTEL_LOG_LEVEL="info"

EXPOSE 8005

# Single worker: the app spawns a background SQS-polling thread at startup;
# multiple workers would create duplicate polling threads.
CMD ["gunicorn", "--bind", "0.0.0.0:8005", "--workers", "1", "--timeout", "120", "app:app"]
