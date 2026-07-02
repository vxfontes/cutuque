package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

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
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /health via Router = %d, quero 200", rec.Code)
	}
}
