package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

func addRunning(reg interface {
	Add(session.Session)
}, id string) {
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: id, Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})
}

func TestSessionOutputReturnsChunks(t *testing.T) {
	cfg, reg := testDeps()
	addRunning(reg, "s")
	reg.AppendOutput("s", "assistant", "linha 1")
	reg.AppendOutput("s", "tool", "linha 2")

	req := httptest.NewRequest(http.MethodGet, "/sessions/s/output", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	var body struct {
		Chunks []struct {
			Kind string `json:"kind"`
			Text string `json:"text"`
		} `json:"chunks"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("resposta não é JSON: %v", err)
	}
	if len(body.Chunks) != 2 ||
		body.Chunks[0].Kind != "assistant" || body.Chunks[0].Text != "linha 1" ||
		body.Chunks[1].Kind != "tool" || body.Chunks[1].Text != "linha 2" {
		t.Errorf("chunks = %+v, quero [{assistant,linha 1},{tool,linha 2}]", body.Chunks)
	}
}

func TestSessionOutputEmptyIsArray(t *testing.T) {
	cfg, reg := testDeps()
	addRunning(reg, "s")

	req := httptest.NewRequest(http.MethodGet, "/sessions/s/output", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	var raw map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("resposta não é JSON: %v", err)
	}
	if string(raw["chunks"]) != "[]" {
		t.Errorf("chunks = %s, quero []", raw["chunks"])
	}
}

func TestSessionOutputUnknownReturns404(t *testing.T) {
	cfg, reg := testDeps()

	req := httptest.NewRequest(http.MethodGet, "/sessions/fantasma/output", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, quero 404", rec.Code)
	}
}

func TestSessionOutputRequiresAuth(t *testing.T) {
	cfg, reg := testDeps()
	addRunning(reg, "s")

	req := httptest.NewRequest(http.MethodGet, "/sessions/s/output", nil)
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, quero 401", rec.Code)
	}
}
