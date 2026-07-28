import os
import sys
import psycopg2
import requests
import json
import logging
from psycopg2.extras import RealDictCursor, Json
from psycopg2.pool import SimpleConnectionPool
from flask import Flask, request, jsonify
from dotenv import load_dotenv
from functools import wraps
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
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor
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
        ResourceAttributes.SERVICE_NAME: "targeting-service",
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
RequestsInstrumentor().instrument()
Psycopg2Instrumentor().instrument()

# --- Configuração ---
DATABASE_URL = os.getenv("DATABASE_URL")
AUTH_SERVICE_URL = os.getenv("AUTH_SERVICE_URL")

if not DATABASE_URL or not AUTH_SERVICE_URL:
    log.error("DATABASE_URL and AUTH_SERVICE_URL must be defined", extra={"critical": True})
    sys.exit(1)

# --- Pool de Conexão com o Banco ---
try:
    pool = SimpleConnectionPool(1, 5, dsn=DATABASE_URL)
    log.info("PostgreSQL connection pool initialized (targeting)")
except psycopg2.OperationalError as e:
    log.error("Fatal error: failed to connect to PostgreSQL", extra={"error": str(e), "critical": True})
    sys.exit(1)

# --- Middleware de Autenticação ---
def require_auth(f):
    """Middleware para validar a chave de API contra o auth-service"""
    @wraps(f)
    def decorated(*args, **kwargs):
        auth_header = request.headers.get("Authorization")
        if not auth_header:
            log.warning("Missing Authorization header")
            return jsonify({"error": "Authorization header obrigatório"}), 401
        
        try:
            validate_url = f"{AUTH_SERVICE_URL}/validate"
            response = requests.get(validate_url, headers={"Authorization": auth_header}, timeout=3)
            
            if response.status_code != 200:
                log.warning("API key validation failed", extra={"status_code": response.status_code})
                return jsonify({"error": "Chave de API inválida"}), 401
        
        except requests.exceptions.Timeout:
            log.error("Timeout connecting to auth-service")
            return jsonify({"error": "Serviço de autenticação indisponível (timeout)"}), 504
        except requests.exceptions.RequestException as e:
            log.error("Error connecting to auth-service", extra={"error": str(e)})
            return jsonify({"error": "Serviço de autenticação indisponível"}), 503

        return f(*args, **kwargs)
    return decorated

# --- Endpoints da API ---

@app.route('/health')
def health():
    return jsonify({"status": "ok"})


@app.route('/version')
def version():
    return jsonify({"service": "targeting-service", "version": "1.1.0"})

@app.route('/rules', methods=['POST'])
@require_auth
def create_rule():
    """Cria uma nova regra de segmentação para uma flag"""
    data = request.get_json()
    if not data or 'flag_name' not in data or 'rules' not in data:
        return jsonify({"error": "'flag_name' e 'rules' (JSON) são obrigatórios"}), 400
    
    flag_name = data['flag_name']
    rules_obj = data['rules']
    is_enabled = data.get('is_enabled', True)
    
    conn = None
    cur = None
    try:
        conn = pool.getconn()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute(
            "INSERT INTO targeting_rules (flag_name, is_enabled, rules, created_at, updated_at) "
            "VALUES (%s, %s, %s, NOW(), NOW()) RETURNING *",
            (flag_name, is_enabled, Json(rules_obj))
        )
        new_rule = cur.fetchone()
        conn.commit()
        log.info("Targeting rule created", extra={"flag_name": flag_name})
        return jsonify(new_rule), 201
    except psycopg2.IntegrityError:
        if conn: conn.rollback()
        log.warning("Duplicate targeting rule creation attempted", extra={"flag_name": flag_name})
        return jsonify({"error": f"Regra para a flag '{flag_name}' já existe"}), 409
    except Exception as e:
        if conn: conn.rollback()
        log.error("Error creating targeting rule", extra={"flag_name": flag_name, "error": str(e)})
        return jsonify({"error": "Erro interno do servidor", "details": str(e)}), 500
    finally:
        if cur: cur.close()
        if conn: pool.putconn(conn)

@app.route('/rules/<string:flag_name>', methods=['GET'])
@require_auth
def get_rule(flag_name):
    """Busca uma regra de segmentação pelo nome da flag"""
    conn = None
    cur = None
    try:
        conn = pool.getconn()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("SELECT * FROM targeting_rules WHERE flag_name = %s", (flag_name,))
        rule = cur.fetchone()
        if not rule:
            return jsonify({"error": "Regra não encontrada"}), 404
        return jsonify(rule)
    except Exception as e:
        log.error(f"Erro ao buscar regra '{flag_name}': {e}")
        return jsonify({"error": "Erro interno do servidor", "details": str(e)}), 500
    finally:
        if cur: cur.close()
        if conn: pool.putconn(conn)

@app.route('/rules/<string:flag_name>', methods=['PUT'])
@require_auth
def update_rule(flag_name):
    """ Atualiza a regra de segmentação de uma flag """
    data = request.get_json()
    if not data:
        return jsonify({"error": "Corpo da requisição obrigatório"}), 400

    fields = []
    values = []
    
    if 'rules' in data:
        fields.append("rules = %s")
        values.append(Json(data['rules'])) # Serializa o JSON
    if 'is_enabled' in data:
        fields.append("is_enabled = %s")
        values.append(data['is_enabled'])
    
    if not fields:
        return jsonify({"error": "Pelo menos um campo ('rules', 'is_enabled') é obrigatório"}), 400
    
    values.append(flag_name) # Adiciona o 'flag_name' para a cláusula WHERE
    
    query = f"UPDATE targeting_rules SET {', '.join(fields)} WHERE flag_name = %s RETURNING *"
    
    conn = None
    cur = None
    try:
        conn = pool.getconn()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute(query, tuple(values))
        
        if cur.rowcount == 0:
            return jsonify({"error": "Regra não encontrada"}), 404
            
        updated_rule = cur.fetchone()
        conn.commit()
        log.info(f"Regra para '{flag_name}' atualizada com sucesso.")
        return jsonify(updated_rule), 200
    except Exception as e:
        if conn: conn.rollback()
        log.error(f"Erro ao atualizar regra '{flag_name}': {e}")
        return jsonify({"error": "Erro interno do servidor", "details": str(e)}), 500
    finally:
        if cur: cur.close()
        if conn: pool.putconn(conn)

@app.route('/rules/<string:flag_name>', methods=['DELETE'])
@require_auth
def delete_rule(flag_name):
    """ Deleta a regra de segmentação de uma flag """
    conn = None
    cur = None
    try:
        conn = pool.getconn()
        cur = conn.cursor()
        cur.execute("DELETE FROM targeting_rules WHERE flag_name = %s", (flag_name,))
        
        if cur.rowcount == 0:
            return jsonify({"error": "Regra não encontrada"}), 404
            
        conn.commit()
        log.info(f"Regra para '{flag_name}' deletada com sucesso.")
        return "", 204 # 204 No Content
    except Exception as e:
        if conn: conn.rollback()
        log.error(f"Erro ao deletar regra '{flag_name}': {e}")
        return jsonify({"error": "Erro interno do servidor", "details": str(e)}), 500
    finally:
        if cur: cur.close()
        if conn: pool.putconn(conn)

if __name__ == '__main__':
    port = int(os.getenv("PORT", 8003))
    app.run(host='0.0.0.0', port=port, debug=False)