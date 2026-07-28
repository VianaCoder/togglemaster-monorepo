package main

import (
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"time"

	_ "github.com/jackc/pgx/v4/stdlib"
	"github.com/joho/godotenv"
	"github.com/XSAM/otelsql"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	"go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/semconv/v1.24.0"
)

// App struct (para injeção de dependência)
type App struct {
	DB        *sql.DB
	MasterKey string
	Logger    *slog.Logger
}

func main() {
	// Carrega o .env para desenvolvimento local. Em produção, isso não fará nada.
	_ = godotenv.Load()

	// Inicializar logger estruturado
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	// Inicializar OpenTelemetry (tracer + meter + resource)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := initOTel(ctx, logger); err != nil {
		logger.Error("Falha ao inicializar OpenTelemetry", slog.Any("error", err))
		os.Exit(1)
	}

	// --- Configuração ---
	port := os.Getenv("PORT")
	if port == "" {
		port = "8001" // Porta padrão
	}

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		logger.Error("DATABASE_URL deve ser definida")
		os.Exit(1)
	}

	masterKey := os.Getenv("MASTER_KEY")
	if masterKey == "" {
		logger.Error("MASTER_KEY deve ser definida")
		os.Exit(1)
	}

	// --- Conexão com o Banco (instrumentada com otelsql) ---
	db, err := connectDB(ctx, databaseURL, logger)
	if err != nil {
		logger.Error("Não foi possível conectar ao banco de dados", slog.Any("error", err))
		os.Exit(1)
	}
	defer db.Close()

	app := &App{
		DB:        db,
		MasterKey: masterKey,
		Logger:    logger,
	}

	// --- Rotas da API ---
	mux := http.NewServeMux()
	mux.HandleFunc("/health", app.healthHandler)
	mux.HandleFunc("/validate", app.validateKeyHandler)
	mux.Handle("/admin/keys", app.masterKeyAuthMiddleware(http.HandlerFunc(app.createKeyHandler)))

	// Wrap mux con otelhttp para auto-instrumentar todos os handlers
	wrappedMux := otelhttp.NewHandler(mux, "auth-service-http",
		otelhttp.WithMeterProvider(otel.GetMeterProvider()),
		otelhttp.WithTracerProvider(otel.GetTracerProvider()),
	)

	logger.Info("Serviço de Autenticação (Go) rodando na porta", slog.String("port", port))
	if err := http.ListenAndServe(":"+port, wrappedMux); err != nil {
		logger.Error("Servidor HTTP falhou", slog.Any("error", err))
		os.Exit(1)
	}
}

// connectDB inicializa e testa a conexão com o PostgreSQL (com otelsql)
func connectDB(ctx context.Context, databaseURL string, logger *slog.Logger) (*sql.DB, error) {
	// Registra o driver pgx com auto-instrumentation via otelsql
	driverName, err := otelsql.Register("pgx",
		otelsql.WithAttributes(
			semconv.DBSystemPostgreSQL,
		),
	)
	if err != nil {
		return nil, err
	}

	db, err := sql.Open(driverName, databaseURL)
	if err != nil {
		return nil, err
	}

	// Context timeout para Ping
	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	if err = db.PingContext(pingCtx); err != nil {
		return nil, err
	}

	logger.Info("Conectado ao PostgreSQL com sucesso")
	return db, nil
}

// initOTel configura tracer + meter + resource para OTLP export
func initOTel(ctx context.Context, logger *slog.Logger) error {
	// Resource: identifica este serviço
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceNameKey.String("auth-service"),
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
		trace.WithSampler(trace.AlwaysSample()), // Em prod: usar tail sampling
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

// healthHandler é um simples endpoint de verificação de saúde
func (a *App) healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

// validateKeyHandler verifica se uma chave de API (enviada via Header) é válida
func (a *App) validateKeyHandler(w http.ResponseWriter, r *http.Request) {
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		a.Logger.Warn("Authorization header not found", slog.String("path", r.RequestURI))
		http.Error(w, "Authorization header não encontrado", http.StatusUnauthorized)
		return
	}

	keyString := authHeader[7:] // Remove "Bearer "
	if keyString == "" {
		http.Error(w, "Authorization header não encontrado", http.StatusUnauthorized)
		return
	}

	// Calcula o hash da chave recebida
	keyHash := hashAPIKey(keyString)

	// Verifica no banco de dados
	var id int
	err := a.DB.QueryRowContext(r.Context(), "SELECT id FROM api_keys WHERE key_hash = $1 AND is_active = true", keyHash).Scan(&id)
	if err != nil {
		a.Logger.Warn("API key validation failed", slog.String("key_hash_prefix", hex.EncodeToString([]byte(keyHash[:6]))), slog.Any("error", err))
		http.Error(w, "Chave de API inválida ou inativa", http.StatusUnauthorized)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"message": "Chave válida"})
}

// createKeyHandler cria uma nova chave de API
func (a *App) createKeyHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Método não permitido", http.StatusMethodNotAllowed)
		return
	}

	var req struct{ Name string }
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		a.Logger.Warn("Invalid request body", slog.Any("error", err))
		http.Error(w, "Corpo da requisição inválido", http.StatusBadRequest)
		return
	}

	if req.Name == "" {
		http.Error(w, "O campo 'name' é obrigatório", http.StatusBadRequest)
		return
	}

	// Gera uma nova chave e seu hash
	newKey, err := generateAPIKey()
	if err != nil {
		a.Logger.Error("Failed to generate API key", slog.Any("error", err))
		http.Error(w, "Erro ao gerar a chave", http.StatusInternalServerError)
		return
	}
	newKeyHash := hashAPIKey(newKey)

	// Salva o hash no banco de dados (com context)
	var newID int
	err = a.DB.QueryRowContext(r.Context(),
		"INSERT INTO api_keys (name, key_hash) VALUES ($1, $2) RETURNING id",
		req.Name, newKeyHash,
	).Scan(&newID)

	if err != nil {
		a.Logger.Error("Failed to save API key", slog.String("name", req.Name), slog.Any("error", err))
		http.Error(w, "Erro ao salvar a chave", http.StatusInternalServerError)
		return
	}

	a.Logger.Info("API key created successfully", slog.Int("id", newID), slog.String("name", req.Name))
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"name":    req.Name,
		"key":     newKey,
		"message": "Guarde esta chave com segurança! Você não poderá vê-la novamente.",
	})
}

// masterKeyAuthMiddleware protege endpoints que só podem ser acessados com a MASTER_KEY
func (a *App) masterKeyAuthMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		if authHeader == "" {
			a.Logger.Warn("Master key auth failed: missing header")
			http.Error(w, "Acesso não autorizado", http.StatusForbidden)
			return
		}

		keyString := authHeader[7:] // Remove "Bearer "
		if keyString != a.MasterKey {
			a.Logger.Warn("Master key auth failed: invalid key")
			http.Error(w, "Acesso não autorizado", http.StatusForbidden)
			return
		}

		next.ServeHTTP(w, r)
	})
}