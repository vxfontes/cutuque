package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/registry"
)

// testDeps monta config (dev, com token) e um registry vazio para os testes.
func testDeps() (config.Config, *registry.Registry) {
	return config.Config{Env: "dev", Token: "secret"}, registry.New()
}

func TestHealthHandlerReturnsOK(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	HealthHandler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}

	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("resposta não é JSON válido: %v", err)
	}
	if body["status"] != "ok" {
		t.Errorf("status = %q, quero \"ok\"", body["status"])
	}
	if body["service"] != "cutuque-hub" {
		t.Errorf("service = %q, quero \"cutuque-hub\"", body["service"])
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, quero \"application/json\"", ct)
	}
}

func TestRouterServesHealth(t *testing.T) {
	cfg, reg := testDeps()
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /health via Router = %d, quero 200", rec.Code)
	}
}

func TestHealthNeedsNoAuth(t *testing.T) {
	cfg, reg := testDeps() // token "secret", mas /health não exige
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /health sem token = %d, quero 200", rec.Code)
	}
}
