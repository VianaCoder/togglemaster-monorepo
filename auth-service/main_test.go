package main

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestParseBoolEnv(t *testing.T) {
	tests := []struct {
		name  string
		in    string
		want  bool
	}{
		{name: "true", in: "true", want: true},
		{name: "one", in: "1", want: true},
		{name: "yes", in: "yes", want: true},
		{name: "on", in: "on", want: true},
		{name: "enabled", in: "enabled", want: true},
		{name: "false", in: "false", want: false},
		{name: "zero", in: "0", want: false},
		{name: "empty", in: "", want: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := parseBoolEnv(tc.in)
			if got != tc.want {
				t.Fatalf("parseBoolEnv(%q) = %v, want %v", tc.in, got, tc.want)
			}
		})
	}
}

func TestDemoForce500MiddlewareDisabled(t *testing.T) {
	app := &App{DemoForce500Env: false, Logger: testLogger()}

	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})

	req := httptest.NewRequest(http.MethodGet, "/health?force_500=true", nil)
	rr := httptest.NewRecorder()

	app.demoForce500Middleware(next).ServeHTTP(rr, req)

	if rr.Code != http.StatusNoContent {
		t.Fatalf("expected %d, got %d", http.StatusNoContent, rr.Code)
	}
}

func TestDemoForce500MiddlewareByQueryParam(t *testing.T) {
	app := &App{DemoForce500Env: true, Logger: testLogger()}

	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})

	req := httptest.NewRequest(http.MethodGet, "/health?force_500=true", nil)
	rr := httptest.NewRecorder()

	app.demoForce500Middleware(next).ServeHTTP(rr, req)

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("expected %d, got %d", http.StatusInternalServerError, rr.Code)
	}
}

func TestDemoForce500MiddlewareByHeader(t *testing.T) {
	app := &App{DemoForce500Env: true, Logger: testLogger()}

	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	req.Header.Set("X-Demo-Force-500", "true")
	rr := httptest.NewRecorder()

	app.demoForce500Middleware(next).ServeHTTP(rr, req)

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("expected %d, got %d", http.StatusInternalServerError, rr.Code)
	}
}

func TestValidateKeyHandlerMalformedAuthorization(t *testing.T) {
	app := &App{Logger: testLogger()}

	req := httptest.NewRequest(http.MethodGet, "/validate", nil)
	req.Header.Set("Authorization", "Bearer")
	rr := httptest.NewRecorder()

	app.validateKeyHandler(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("expected %d, got %d", http.StatusUnauthorized, rr.Code)
	}
}

func TestMasterKeyAuthMiddlewareMalformedAuthorization(t *testing.T) {
	app := &App{MasterKey: "secret", Logger: testLogger()}

	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})

	req := httptest.NewRequest(http.MethodPost, "/admin/keys", nil)
	req.Header.Set("Authorization", "Bearer")
	rr := httptest.NewRecorder()

	app.masterKeyAuthMiddleware(next).ServeHTTP(rr, req)

	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected %d, got %d", http.StatusForbidden, rr.Code)
	}
}
