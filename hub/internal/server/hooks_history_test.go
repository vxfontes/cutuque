package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/event"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// histSpy é um engine.HistoryWriter de teste: guarda o que o Engine mandou
// gravar. Protegido por mutex porque a escrita vem da goroutine do histórico.
type histSpy struct {
	mu      sync.Mutex
	eventos []event.Event
	sessoes []session.Session
}

func (h *histSpy) AppendEvent(_ context.Context, ev event.Event) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.eventos = append(h.eventos, ev)
	return nil
}

func (h *histSpy) UpsertSession(_ context.Context, s session.Session) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.sessoes = append(h.sessoes, s)
	return nil
}

func (h *histSpy) snapshot() ([]event.Event, []session.Session) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]event.Event(nil), h.eventos...), append([]session.Session(nil), h.sessoes...)
}

// TestHookGravaHistoricoComEngineInjetado é o regressor do defeito: o Router
// criava um engine.New(reg) local e os hooks aplicavam transições por ele, sem
// write-through — todo evento que chegava por /hooks/claude sumia do Postgres.
// Com WithEngine, os hooks usam o MESMO Engine dos runners (o com histórico).
func TestHookGravaHistoricoComEngineInjetado(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 8, 13, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})

	spy := &histSpy{}
	eng := engine.NewWithHistory(reg, spy)

	body := `{"session_id":"s","hook_event_name":"Notification","message":"posso rodar rm?"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil, WithEngine(eng)).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	// Close drena a fila: nada de sleep, o histórico é assíncrono mas determinístico
	// no fim do shutdown.
	eng.Close()

	eventos, sessoes := spy.snapshot()
	if len(eventos) != 1 {
		t.Fatalf("eventos gravados = %d, quero 1: %+v", len(eventos), eventos)
	}
	if eventos[0].SessionID != "s" || eventos[0].Type != event.NeedsInput {
		t.Errorf("evento gravado errado: %+v", eventos[0])
	}
	if len(sessoes) != 1 {
		t.Fatalf("sessões gravadas = %d, quero 1", len(sessoes))
	}
	if sessoes[0].State != session.StateNeedsYou {
		t.Errorf("sessão gravada com State = %q, quero \"needs_you\"", sessoes[0].State)
	}
}

// TestHookSemWithEngineSegueFuncionando: o fallback tem de continuar de pé —
// testes e hub sem CUTUQUE_DATABASE_URL não passam a opção, e ainda assim o
// estado tem de mudar (só não vai para histórico nenhum).
func TestHookSemWithEngineSegueFuncionando(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 8, 13, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"Stop"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if s, _ := reg.Get("s"); s.State != session.StateDone {
		t.Errorf("State = %q, quero \"done\" (fallback do Engine local)", s.State)
	}
}
