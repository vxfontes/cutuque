// Package integration exercita o fluxo completo da Fase 2:
// Runner (fixture) → State Engine → Registry → Command API (WebSocket).
package integration

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/server"
	"github.com/vxfontes/cutuque/hub/internal/session"

	"net/http/httptest"
)

// fileTarget implementa claudecode.Target lendo uma fixture do disco.
type fileTarget struct {
	name string
	path string
}

func (f fileTarget) Name() string { return f.name }
func (f fileTarget) Start(ctx context.Context, prompt string) (io.ReadCloser, error) {
	return os.Open(f.path)
}

func TestRunnerToRegistryToWebSocket(t *testing.T) {
	const sessionID = "815b221e-73ff-4703-a264-2ac11bcb46c4" // da fixture-tooluse

	reg := registry.New()
	eng := engine.New(reg)
	cfg := config.Config{Env: "dev", Token: "secret"}

	srv := httptest.NewServer(server.Router(cfg, reg))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws?token=secret"
	c, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer c.CloseNow()

	// Snapshot inicial (registry vazio).
	var snap struct {
		Type     string            `json:"type"`
		Sessions []session.Session `json:"sessions"`
	}
	if err := wsjson.Read(ctx, c, &snap); err != nil {
		t.Fatalf("lendo snapshot: %v", err)
	}
	if snap.Type != "snapshot" || len(snap.Sessions) != 0 {
		t.Fatalf("snapshot = %+v, quero vazio", snap)
	}

	// Coleta mensagens do WS em background.
	type wsMsg struct {
		Type      string          `json:"type"`
		SessionID string          `json:"session_id"`
		Data      string          `json:"data"`
		Session   session.Session `json:"session"`
	}
	msgs := make(chan wsMsg, 64)
	go func() {
		for {
			var m wsMsg
			if err := wsjson.Read(ctx, c, &m); err != nil {
				return
			}
			msgs <- m
		}
	}()

	// Roda o Runner com a fixture real do Claude Code.
	r := claudecode.NewRunner(eng, reg)
	tgt := fileTarget{
		name: "macbook",
		path: filepath.Join("..", "adapter", "claudecode", "testdata", "fixture-tooluse.jsonl"),
	}
	if err := r.Run(ctx, tgt, "rode o echo cutuque-teste no bash"); err != nil {
		t.Fatalf("Run: %v", err)
	}

	// --- Registry: sessão em done com output disponível ---
	s, ok := reg.Get(sessionID)
	if !ok {
		t.Fatalf("sessão %q não está no registry", sessionID)
	}
	if s.State != session.StateDone {
		t.Errorf("State = %q, quero \"done\"", s.State)
	}
	if s.Machine != "macbook" || s.Agent != "claude-code" {
		t.Errorf("metadados = machine=%q agent=%q, quero macbook/claude-code", s.Machine, s.Agent)
	}
	out := reg.Output(sessionID)
	if len(out) == 0 {
		t.Errorf("output vazio, quero chunks da sessão")
	}

	// --- WebSocket: mensagens corretas recebidas ---
	deadline := time.After(2 * time.Second)
	var sawSessionUpdatedDone, sawOutputChunk bool
	var sawRunning bool
collect:
	for {
		select {
		case m := <-msgs:
			switch m.Type {
			case "session_updated":
				if m.Session.ID == sessionID {
					switch m.Session.State {
					case session.StateRunning:
						sawRunning = true
					case session.StateDone:
						sawSessionUpdatedDone = true
					}
				}
			case "output_chunk":
				if m.SessionID == sessionID && m.Data != "" {
					sawOutputChunk = true
				}
			}
			if sawRunning && sawOutputChunk && sawSessionUpdatedDone {
				break collect
			}
		case <-deadline:
			break collect
		}
	}

	if !sawRunning {
		t.Errorf("não recebeu session_updated running via WS")
	}
	if !sawOutputChunk {
		t.Errorf("não recebeu output_chunk via WS")
	}
	if !sawSessionUpdatedDone {
		t.Errorf("não recebeu session_updated done via WS")
	}
}
