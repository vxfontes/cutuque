// Package integration exercita o fluxo completo da Fase 3:
// REST (POST /sessions, /approve) → Launcher → Runner (fake) → State Engine →
// Registry → Command API (WebSocket), incluindo o control_response de aprovação.
package integration

import (
	"bufio"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/launcher"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/server"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

const (
	sid   = "int-sess-1"
	reqID = "int-req-1"
)

// scriptTarget é um Target fake que emite init + control_request, espera o
// control_response e então emite o result — simulando um Claude Code que pede
// permissão e prossegue após a aprovação.
type scriptTarget struct{ name string }

func (s scriptTarget) Name() string { return s.name }
func (s scriptTarget) Start(_ context.Context, _, _ string) (*claudecode.Handle, error) {
	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()
	go func() {
		defer stdoutW.Close()
		in := bufio.NewReader(stdinR)
		_, _ = in.ReadString('\n') // prompt inicial
		_, _ = io.WriteString(stdoutW, `{"type":"system","subtype":"init","session_id":"`+sid+`"}`+"\n")
		_, _ = io.WriteString(stdoutW, `{"type":"control_request","request_id":"`+reqID+`","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"touch cutuque-int.txt","description":"probe"},"description":"probe"}}`+"\n")
		_, _ = in.ReadString('\n') // aguarda o control_response
		_, _ = io.WriteString(stdoutW, `{"type":"result","subtype":"success","is_error":false,"result":"feito"}`+"\n")
	}()
	return &claudecode.Handle{Stdout: stdoutR, Stdin: stdinW}, nil
}

func TestLaunchApproveFlowEndToEnd(t *testing.T) {
	reg := registry.New()
	eng := engine.New(reg)
	lch := launcher.New(eng, reg, map[string]claudecode.Target{"macbook": scriptTarget{name: "macbook"}})
	cfg := config.Config{Env: "dev", Token: "secret"}

	srv := httptest.NewServer(server.Router(cfg, reg, lch))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// WS conectado antes do launch, para observar toda a evolução.
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws?token=secret"
	c, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer c.CloseNow()

	type wsMsg struct {
		Type    string          `json:"type"`
		Session session.Session `json:"session"`
	}
	msgs := make(chan wsMsg, 128)
	go func() {
		for {
			var m wsMsg
			if err := wsjson.Read(ctx, c, &m); err != nil {
				return
			}
			msgs <- m
		}
	}()

	// 1) Lança pela REST.
	launchBody := `{"machine":"macbook","agent":"claude-code","prompt":"crie um arquivo de prova"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/sessions", strings.NewReader(launchBody))
	req.Header.Set("Authorization", "Bearer secret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST /sessions: %v", err)
	}
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("launch status = %d, quero 201", resp.StatusCode)
	}
	resp.Body.Close()

	// 2) Espera needs_you com pending_prompt (invariante: exibir antes de aprovar).
	waitState(t, reg, sid, session.StateNeedsYou)
	got, _ := reg.Get(sid)
	if got.PendingPrompt == "" || !strings.HasPrefix(got.PendingPrompt, "Bash:") {
		t.Fatalf("PendingPrompt = %q, quero o resumo do pedido", got.PendingPrompt)
	}

	// 3) Aprova pela REST.
	areq, _ := http.NewRequest(http.MethodPost, srv.URL+"/sessions/"+sid+"/approve", nil)
	areq.Header.Set("Authorization", "Bearer secret")
	aresp, err := http.DefaultClient.Do(areq)
	if err != nil {
		t.Fatalf("POST approve: %v", err)
	}
	if aresp.StatusCode != http.StatusOK {
		t.Fatalf("approve status = %d, quero 200", aresp.StatusCode)
	}
	aresp.Body.Close()

	// 4) Após aprovar: running → done, pending limpo.
	waitState(t, reg, sid, session.StateDone)
	final, _ := reg.Get(sid)
	if final.PendingPrompt != "" {
		t.Errorf("PendingPrompt = %q, quero vazio ao terminar", final.PendingPrompt)
	}

	// 5) WS deve ter mostrado a evolução, incluindo needs_you COM pending_prompt.
	deadline := time.After(3 * time.Second)
	var sawRunning, sawNeedsYouWithPrompt, sawDone bool
collect:
	for {
		select {
		case m := <-msgs:
			if m.Type != "session_updated" || m.Session.ID != sid {
				continue
			}
			switch m.Session.State {
			case session.StateRunning:
				sawRunning = true
			case session.StateNeedsYou:
				if m.Session.PendingPrompt != "" {
					sawNeedsYouWithPrompt = true
				}
			case session.StateDone:
				sawDone = true
			}
			if sawRunning && sawNeedsYouWithPrompt && sawDone {
				break collect
			}
		case <-deadline:
			break collect
		}
	}
	if !sawRunning {
		t.Errorf("WS não mostrou session_updated running")
	}
	if !sawNeedsYouWithPrompt {
		t.Errorf("WS não mostrou session_updated needs_you com pending_prompt")
	}
	if !sawDone {
		t.Errorf("WS não mostrou session_updated done")
	}
}

func waitState(t *testing.T, reg *registry.Registry, id string, want session.State) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if s, ok := reg.Get(id); ok && s.State == want {
			return
		}
		time.Sleep(3 * time.Millisecond)
	}
	got, _ := reg.Get(id)
	t.Fatalf("sessão %q não chegou em %q (estado atual %q)", id, want, got.State)
}
