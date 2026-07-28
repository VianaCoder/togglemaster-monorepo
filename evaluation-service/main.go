package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sqs"
	"github.com/go-redis/redis/v8"
	"github.com/joho/godotenv"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	"go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/semconv/v1.27.0/semconv"
)

// Contexto global para o Redis
var ctx = context.Background()

// App struct para injeção de dependência
type App struct {
	RedisClient         *redis.Client
	SqsSvc              *sqs.SQS
	SqsQueueURL         string
	HttpClient          *http.Client
	FlagServiceURL      string
	TargetingServiceURL string
	Logger              *slog.Logger
}

func main() {
	_ = godotenv.Load() // Carrega .env para dev local

	// Inicializar logger estruturado
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	// Inicializar OpenTelemetry
	otelCtx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := initOTel(otelCtx, logger); err != nil {
		logger.Error("Falha ao inicializar OpenTelemetry", slog.Any("error", err))
		os.Exit(1)
	}

	// --- Configuração ---
	port := os.Getenv("PORT")
	if port == "" {
		port = "8004"
	}

	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		logger.Error("REDIS_URL deve ser definida (ex: redis://localhost:6379)")
		os.Exit(1)
	}

	flagSvcURL := os.Getenv("FLAG_SERVICE_URL")
	if flagSvcURL == "" {
		logger.Error("FLAG_SERVICE_URL deve ser definida")
		os.Exit(1)
	}

	targetingSvcURL := os.Getenv("TARGETING_SERVICE_URL")
	if targetingSvcURL == "" {
		logger.Error("TARGETING_SERVICE_URL deve ser definida")
		os.Exit(1)
	}

	// SQS é opcional no dev local, mas obrigatório em prod
	sqsQueueURL := os.Getenv("AWS_SQS_URL")
	awsRegion := os.Getenv("AWS_REGION")
	awsEndpoint := os.Getenv("AWS_ENDPOINT_URL")
	awsAccessKeyID := os.Getenv("AWS_ACCESS_KEY_ID")
	awsSecretAccessKey := os.Getenv("AWS_SECRET_ACCESS_KEY")
	if sqsQueueURL == "" {
		logger.Warn("Atenção: AWS_SQS_URL não definida. Eventos não serão enviados.")
	}
	if awsRegion == "" && sqsQueueURL != "" {
		logger.Error("AWS_REGION deve ser definida para usar SQS")
		os.Exit(1)
	}

	// --- Inicializa Clientes ---

	// Cliente Redis
	opt, err := redis.ParseURL(redisURL)
	if err != nil {
		logger.Error("Não foi possível parsear a URL do Redis", slog.Any("error", err))
		os.Exit(1)
	}
	rdb := redis.NewClient(opt)
	if _, err := rdb.Ping(ctx).Result(); err != nil {
		logger.Error("Não foi possível conectar ao Redis", slog.Any("error", err))
		os.Exit(1)
	}
	logger.Info("Conectado ao Redis com sucesso")

	// Cliente SQS (AWS SDK)
	var sqsSvc *sqs.SQS
	if sqsQueueURL != "" {
		awsCfg := &aws.Config{Region: aws.String(awsRegion)}

		// LocalStack support for local development.
		if awsEndpoint != "" {
			awsCfg.Endpoint = aws.String(awsEndpoint)
			if strings.HasPrefix(awsEndpoint, "http://") {
				awsCfg.DisableSSL = aws.Bool(true)
			}
			if awsAccessKeyID != "" && awsSecretAccessKey != "" {
				awsCfg.Credentials = credentials.NewStaticCredentials(awsAccessKeyID, awsSecretAccessKey, "")
			}
		}

		sess, err := session.NewSession(awsCfg)
		if err != nil {
			logger.Error("Não foi possível criar sessão AWS", slog.Any("error", err))
			os.Exit(1)
		}
		sqsSvc = sqs.New(sess)
		logger.Info("Cliente SQS inicializado com sucesso")
	}

	// Cliente HTTP instrumentado com otelhttp (com timeout)
	httpClient := &http.Client{
		Timeout:   5 * time.Second,
		Transport: otelhttp.NewTransport(http.DefaultTransport),
	}

	// Cria a instância da App
	app := &App{
		RedisClient:         rdb,
		SqsSvc:              sqsSvc,
		SqsQueueURL:         sqsQueueURL,
		HttpClient:          httpClient,
		FlagServiceURL:      flagSvcURL,
		TargetingServiceURL: targetingSvcURL,
		Logger:              logger,
	}

	// --- Rotas ---
	mux := http.NewServeMux()
	mux.HandleFunc("/health", app.healthHandler)
	mux.HandleFunc("/evaluate", app.evaluationHandler)

	// Wrap mux com otelhttp para auto-instrumentar todos os handlers
	wrappedMux := otelhttp.NewHandler(mux, "evaluation-service-http",
		otelhttp.WithMeterProvider(otel.GetMeterProvider()),
		otelhttp.WithTracerProvider(otel.GetTracerProvider()),
	)

	logger.Info("Serviço de Avaliação (Go) rodando na porta", slog.String("port", port))
	if err := http.ListenAndServe(":"+port, wrappedMux); err != nil {
		logger.Error("Servidor HTTP falhou", slog.Any("error", err))
		os.Exit(1)
	}
}

// initOTel configura tracer + meter + resource para OTLP export
func initOTel(ctx context.Context, logger *slog.Logger) error {
	// Resource: identifica este serviço
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceNameKey.String("evaluation-service"),
			semconv.ServiceVersionKey.String("1.0.0"),
			semconv.ServiceInstanceIDKey.String(os.Getenv("HOSTNAME")),
		),
	)
	if err != nil {
		return err
	}

	// OTLP Trace Exporter (gRPC ao OTel Collector)
	traceExporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(getOTelCollectorEndpoint()),
		otlptracegrpc.WithInsecure(),
	)
	if err != nil {
		return err
	}

	// Tracer Provider
	tp := trace.NewTracerProvider(
		trace.WithResource(res),
		trace.WithBatcher(traceExporter),
		trace.WithSampler(trace.AlwaysSample()),
	)
	otel.SetTracerProvider(tp)

	// OTLP Metric Exporter (gRPC ao OTel Collector)
	metricExporter, err := otlpmetricgrpc.New(ctx,
		otlpmetricgrpc.WithEndpoint(getOTelCollectorEndpoint()),
		otlpmetricgrpc.WithInsecure(),
	)
	if err != nil {
		return err
	}

	// Meter Provider
	mp := metric.NewMeterProvider(
		metric.WithResource(res),
		metric.WithReader(metric.NewPeriodicReader(metricExporter)),
	)
	otel.SetMeterProvider(mp)

	logger.Info("OpenTelemetry inicializado com sucesso")
	return nil
}

// getOTelCollectorEndpoint retorna o endpoint do OTel Collector
func getOTelCollectorEndpoint() string {
	if endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT"); endpoint != "" {
		return endpoint
	}
	// Default no cluster Kubernetes
	return "opentelemetry-collector.monitoring.svc.cluster.local:4317"
}