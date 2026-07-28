import os
import sys
import threading
import json
import uuid
import time
import logging
import boto3
from botocore.exceptions import NoCredentialsError, ClientError
from flask import Flask, jsonify
from dotenv import load_dotenv
from pythonjsonlogger import jsonlogger

# OpenTelemetry imports
from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.boto3 import Boto3Instrumentor
from opentelemetry.semconv.resource import ResourceAttributes

# Carrega .env para desenvolvimento local
load_dotenv()

# --- Logger estruturado em JSON ---
logger = logging.getLogger()
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setFormatter(jsonlogger.JsonFormatter())
logger.addHandler(handler)
log = logger

# --- OpenTelemetry Setup ---
def init_otel():
    """Inicializa tracer e meter providers com OTLP export"""
    resource = Resource.create({
        ResourceAttributes.SERVICE_NAME: "analytics-service",
        ResourceAttributes.SERVICE_VERSION: "1.0.0",
    })

    # Trace exporter
    otlp_exporter = OTLPSpanExporter(
        endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "opentelemetry-collector.monitoring.svc.cluster.local:4317"),
        insecure=True,
    )
    trace_provider = TracerProvider(resource=resource)
    trace_provider.add_span_processor(BatchSpanProcessor(otlp_exporter))
    trace.set_tracer_provider(trace_provider)

    # Metric exporter
    metric_exporter = OTLPMetricExporter(
        endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "opentelemetry-collector.monitoring.svc.cluster.local:4317"),
        insecure=True,
    )
    metric_provider = MeterProvider(
        resource=resource,
        metric_readers=[PeriodicExportingMetricReader(metric_exporter)],
    )
    metrics.set_meter_provider(metric_provider)

    log.info("OpenTelemetry initialized")

# Inicializar OTel antes de criar Flask app
init_otel()

app = Flask(__name__)

# --- Auto-instrumentação ---
FlaskInstrumentor().instrument_app(app)
Boto3Instrumentor().instrument()

# --- Configuração ---
AWS_REGION = os.getenv("AWS_REGION")
SQS_QUEUE_URL = os.getenv("AWS_SQS_URL")
DYNAMODB_TABLE_NAME = os.getenv("AWS_DYNAMODB_TABLE")

if not all([AWS_REGION, SQS_QUEUE_URL, DYNAMODB_TABLE_NAME]):
    log.error("AWS_REGION, AWS_SQS_URL, and AWS_DYNAMODB_TABLE must be defined", extra={"critical": True})
    sys.exit(1)

# --- Clientes Boto3 ---
try:
    session = boto3.Session(region_name=AWS_REGION)
    sqs_client = session.client("sqs")
    dynamodb_client = session.client("dynamodb")
    log.info("Boto3 clients initialized", extra={"region": AWS_REGION})
except NoCredentialsError:
    log.error("AWS credentials not found. Check your environment.", extra={"critical": True})
    sys.exit(1)
except Exception as e:
    log.error("Error initializing Boto3", extra={"error": str(e), "critical": True})
    sys.exit(1)


# --- SQS Worker ---

def process_message(message):
    """Processa uma única mensagem SQS e a insere no DynamoDB"""
    try:
        log.info("Processing SQS message", extra={"message_id": message['MessageId']})
        body = json.loads(message['Body'])
        
        # Gera um ID único para o item no DynamoDB
        event_id = str(uuid.uuid4())
        
        # Constrói o item no formato do DynamoDB
        item = {
            'event_id': {'S': event_id},
            'user_id': {'S': body['user_id']},
            'flag_name': {'S': body['flag_name']},
            'result': {'BOOL': body['result']},
            'timestamp': {'S': body['timestamp']}
        }
        
        # Insere no DynamoDB
        dynamodb_client.put_item(
            TableName=DYNAMODB_TABLE_NAME,
            Item=item
        )
        
        log.info("Event saved to DynamoDB", extra={"event_id": event_id, "flag_name": body['flag_name']})
        
        # Se tudo deu certo, deleta a mensagem da fila
        sqs_client.delete_message(
            QueueUrl=SQS_QUEUE_URL,
            ReceiptHandle=message['ReceiptHandle']
        )
        
    except json.JSONDecodeError:
        log.error("Failed to decode JSON from SQS message", extra={"message_id": message['MessageId']})
    except ClientError as e:
        log.error("Boto3 error processing message", extra={"message_id": message['MessageId'], "error": str(e)})
    except Exception as e:
        log.error("Unexpected error processing message", extra={"message_id": message['MessageId'], "error": str(e)})

def sqs_worker_loop():
    """Loop principal do worker que ouve a fila SQS"""
    log.info("Starting SQS worker")
    while True:
        try:
            # Long-polling: espera até 20s por mensagens
            response = sqs_client.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20
            )
            
            messages = response.get('Messages', [])
            if not messages:
                # Nenhuma mensagem, continua o loop
                continue
                
            log.info(f"Recebidas {len(messages)} mensagens.")
            
            for message in messages:
                process_message(message)
                
        except ClientError as e:
            log.error(f"Erro do Boto3 no loop principal do SQS: {e}")
            time.sleep(10) # Pausa antes de tentar novamente
        except Exception as e:
            log.error(f"Erro inesperado no loop principal do SQS: {e}")
            time.sleep(10)

# --- Servidor Flask (Apenas para Health Check) ---

app = Flask(__name__)

@app.route('/health')
def health():
    # Uma verificação de saúde real poderia checar a conexão com o DynamoDB/SQS
    return jsonify({"status": "ok"})

# --- Inicialização ---

def start_worker():
    """ Inicia o worker SQS em uma thread separada """
    worker_thread = threading.Thread(target=sqs_worker_loop, daemon=True)
    worker_thread.start()

# Inicia o worker SQS em uma thread de background
# Isso garante que ele inicie tanto com 'flask run' quanto com 'gunicorn'
start_worker()

if __name__ == '__main__':
    port = int(os.getenv("PORT", 8005))
    app.run(host='0.0.0.0', port=port, debug=False)