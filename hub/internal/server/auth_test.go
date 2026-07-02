package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// okHandler responde 200 "ok"; usado para observar se o middleware deixou passar.
func okHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
}

func TestRequireAuthAllowsValidBearer(t *testing.T) {
	h := requireAuth("secret", okHandler())
	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
}

func TestRequireAuthAllowsValidQueryToken(t *testing.T) {
	h := requireAuth("secret", okHandler())
	req := httptest.NewRequest(http.MethodGet, "/x?token=secret", nil)
	rec := httptest.NewRecorder()

	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (token via query)", rec.Code)
	}
}

func TestRequireAuthRejectsMissingToken(t *testing.T) {
	h := requireAuth("secret", okHandler())
	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	rec := httptest.NewRecorder()

	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, quero 401", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, quero \"application/json\"", ct)
	}
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("resposta não é JSON: %v", err)
	}
	if body["error"] != "unauthorized" {
		t.Errorf("error = %q, quero \"unauthorized\"", body["error"])
	}
}

func TestRequireAuthRejectsWrongToken(t *testing.T) {
	h := requireAuth("secret", okHandler())
	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.Header.Set("Authorization", "Bearer errado")
	rec := httptest.NewRecorder()

	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, quero 401", rec.Code)
	}
}

func TestRequireAuthRejectsMalformedHeader(t *testing.T) {
	h := requireAuth("secret", okHandler())
	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.Header.Set("Authorization", "secret") // sem prefixo "Bearer "
	rec := httptest.NewRecorder()

	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, quero 401 (header sem prefixo Bearer)", rec.Code)
	}
}
