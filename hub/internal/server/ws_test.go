package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

func wsURL(httpURL string) string {
	return "ws" + strings.TrimPrefix(httpURL, "http") + "/ws?token=secret"
}

func TestWSSendsSnapshotThenUpdates(t *testing.T) {
	cfg, reg := testDeps()
	base := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "a", Machine: "macbook", Agent: "claude-code", Title: "t1", State: session.StateRunning, CreatedAt: base, UpdatedAt: base})

	srv := httptest.NewServer(Router(cfg, reg, nil))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	c, _, err := websocket.Dial(ctx, wsURL(srv.URL), nil)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer c.CloseNow()

	// Primeira mensagem: snapshot com o estado atual.
	var snap struct {
		Type     string            `json:"type"`
		Sessions []session.Session `json:"sessions"`
	}
	if err := wsjson.Read(ctx, c, &snap); err != nil {
		t.Fatalf("lendo snapshot: %v", err)
	}
	if snap.Type != "snapshot" {
		t.Errorf("type = %q, quero \"snapshot\"", snap.Type)
	}
	if len(snap.Sessions) != 1 || snap.Sessions[0].ID != "a" {
		t.Fatalf("snapshot.sessions = %+v, quero 1 sessão \"a\"", snap.Sessions)
	}

	// Ao mudar o registry, o cliente recebe session_updated.
	if err := reg.UpdateState("a", session.StateDone); err != nil {
		t.Fatalf("UpdateState: %v", err)
	}

	var upd struct {
		Type    string          `json:"type"`
		Session session.Session `json:"session"`
	}
	if err := wsjson.Read(ctx, c, &upd); err != nil {
		t.Fatalf("lendo session_updated: %v", err)
	}
	if upd.Type != "session_updated" {
		t.Errorf("type = %q, quero \"session_updated\"", upd.Type)
	}
	if upd.Session.ID != "a" || upd.Session.State != session.StateDone {
		t.Errorf("session = %+v, quero id=a state=done", upd.Session)
	}
}

func TestWSNewSessionBroadcasts(t *testing.T) {
	cfg, reg := testDeps()
	srv := httptest.NewServer(Router(cfg, reg, nil))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	c, _, err := websocket.Dial(ctx, wsURL(srv.URL), nil)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer c.CloseNow()

	// Consome o snapshot (vazio).
	var snap map[string]any
	if err := wsjson.Read(ctx, c, &snap); err != nil {
		t.Fatalf("lendo snapshot: %v", err)
	}

	// Add depois de conectado deve ser broadcastado.
	now := time.Date(2026, 7, 2, 11, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "novo", Machine: "desktop-win", Agent: "codex", Title: "t", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})

	var upd struct {
		Type    string          `json:"type"`
		Session session.Session `json:"session"`
	}
	if err := wsjson.Read(ctx, c, &upd); err != nil {
		t.Fatalf("lendo session_updated: %v", err)
	}
	if upd.Type != "session_updated" || upd.Session.ID != "novo" {
		t.Errorf("recebido %+v, quero session_updated de \"novo\"", upd)
	}
}

// Garante que o heartbeat de ping não quebra o stream: com um intervalo curto,
// vários pings disparam e o cliente ainda recebe session_updated normalmente.
func TestWSSurvivesPingTicks(t *testing.T) {
	saved := wsPingInterval
	wsPingInterval = 20 * time.Millisecond
	defer func() { wsPingInterval = saved }()

	cfg, reg := testDeps()
	base := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "a", Machine: "macbook", Agent: "claude-code", Title: "t1", State: session.StateRunning, CreatedAt: base, UpdatedAt: base})

	srv := httptest.NewServer(Router(cfg, reg, nil))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	c, _, err := websocket.Dial(ctx, wsURL(srv.URL), nil)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer c.CloseNow()

	var snap map[string]any
	if err := wsjson.Read(ctx, c, &snap); err != nil {
		t.Fatalf("lendo snapshot: %v", err)
	}

	// Deixa vários ciclos de ping passarem antes de gerar um evento.
	time.Sleep(100 * time.Millisecond)
	if err := reg.UpdateState("a", session.StateDone); err != nil {
		t.Fatalf("UpdateState: %v", err)
	}

	var upd struct {
		Type    string          `json:"type"`
		Session session.Session `json:"session"`
	}
	if err := wsjson.Read(ctx, c, &upd); err != nil {
		t.Fatalf("lendo session_updated após pings: %v", err)
	}
	if upd.Type != "session_updated" || upd.Session.State != session.StateDone {
		t.Errorf("recebido %+v, quero session_updated done", upd)
	}
}

func TestWSSendsOutputChunk(t *testing.T) {
	cfg, reg := testDeps()
	srv := httptest.NewServer(Router(cfg, reg, nil))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	c, _, err := websocket.Dial(ctx, wsURL(srv.URL), nil)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer c.CloseNow()

	var snap map[string]any
	if err := wsjson.Read(ctx, c, &snap); err != nil {
		t.Fatalf("lendo snapshot: %v", err)
	}

	reg.AppendOutput("s1", "assistant", "saída ao vivo")

	var msg struct {
		Type      string `json:"type"`
		SessionID string `json:"session_id"`
		Kind      string `json:"kind"`
		Data      string `json:"data"`
	}
	if err := wsjson.Read(ctx, c, &msg); err != nil {
		t.Fatalf("lendo output_chunk: %v", err)
	}
	if msg.Type != "output_chunk" || msg.SessionID != "s1" || msg.Kind != "assistant" || msg.Data != "saída ao vivo" {
		t.Errorf("msg = %+v, quero output_chunk s1 assistant \"saída ao vivo\"", msg)
	}
}

func TestWSRequiresAuth(t *testing.T) {
	cfg, reg := testDeps()
	srv := httptest.NewServer(Router(cfg, reg, nil))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Sem token na query.
	noTokenURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	c, resp, err := websocket.Dial(ctx, noTokenURL, nil)
	if err == nil {
		c.CloseNow()
		t.Fatal("Dial sem token deveria falhar")
	}
	if resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status = %v, quero 401", resp)
	}
}
