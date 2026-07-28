package server

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

func TestHookNotificationSetsNeedsYou(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"Notification","message":"posso rodar rm?"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if s, _ := reg.Get("s"); s.State != session.StateNeedsYou {
		t.Errorf("State = %q, quero \"needs_you\"", s.State)
	}
}

// TestHookAutoRegistersUnknownSession: um hook de uma sessão que o hub NÃO
// lançou (interativa/tmux) auto-registra a sessão e a leva a needs_you — a base
// para "qualquer claude no Mac aparece e cutuca".
func TestHookAutoRegistersUnknownSession(t *testing.T) {
	cfg, reg := testDeps()
	body := `{"session_id":"desconhecida-123","hook_event_name":"Notification","message":"posso rodar?","cwd":"/Users/example/proj","machine":"macbook"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	s, ok := reg.Get("desconhecida-123")
	if !ok {
		t.Fatal("sessão desconhecida não foi auto-registrada pelo hook")
	}
	if s.State != session.StateNeedsYou || s.Machine != "macbook" || s.Cwd != "/Users/example/proj" {
		t.Errorf("sessão auto-registrada errada: %+v", s)
	}
}

// TestHookSessionStartRegistersRunning: SessionStart auto-registra como running.
func TestHookSessionStartRegistersRunning(t *testing.T) {
	cfg, reg := testDeps()
	body := `{"session_id":"nova-1","hook_event_name":"SessionStart","cwd":"/Users/example/x","machine":"macbook"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if s, ok := reg.Get("nova-1"); !ok || s.State != session.StateRunning {
		t.Errorf("SessionStart devia registrar running; got ok=%v state=%q", ok, s.State)
	}
}

func TestHookStopSetsDone(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
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
		t.Errorf("State = %q, quero \"done\"", s.State)
	}
}

// TestHookNotificationPermissionBlocks: a mensagem real de permissão do Claude
// ("Claude needs your permission") é bloqueio → needs_you.
func TestHookNotificationPermissionBlocks(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateRunning, External: true, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if s, _ := reg.Get("s"); s.State != session.StateNeedsYou {
		t.Errorf("permissão devia dar needs_you; State = %q", s.State)
	}
}

// TestHookPermissionMessageLocalized: a mensagem de permissão do Claude é
// traduzida para PT-BR no prompt (preservando o nome da ferramenta).
func TestHookPermissionMessageLocalized(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateRunning, External: true, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil).ServeHTTP(rec, req)

	s, _ := reg.Get("s")
	if s.PendingPrompt != "Claude precisa da sua permissão para usar Bash" {
		t.Errorf("prompt não traduzido: %q", s.PendingPrompt)
	}
}

// TestHookIdleNotificationBecomesDone: a mensagem ociosa do Claude ("waiting for
// your input") NÃO é bloqueio — vira done, não needs_you.
func TestHookIdleNotificationBecomesDone(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateRunning, External: true, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"Notification","message":"Claude is waiting for your input"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if s, _ := reg.Get("s"); s.State != session.StateDone {
		t.Errorf("espera ociosa devia dar done; State = %q", s.State)
	}
}

// TestHookIdleDoesNotResurrectDone: o bug relatado — uma sessão JÁ concluída
// recebe o Notification ocioso e NÃO deve voltar para needs_you.
func TestHookIdleDoesNotResurrectDone(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateDone, External: true, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"Notification","message":"Claude is waiting for your input"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if s, _ := reg.Get("s"); s.State != session.StateDone {
		t.Errorf("sessão concluída não pode voltar pra needs_you; State = %q", s.State)
	}
}

// postHook manda um payload de hook autenticado e devolve o recorder. Os testes
// de SessionEnd exercitam várias combinações do mesmo request.
func postHook(t *testing.T, cfg config.Config, reg *registry.Registry, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil).ServeHTTP(rec, req)
	return rec
}

// TestHookSessionEndIdlesActiveSession é o fecho do ciclo de vida: o processo do
// claude saiu, então a sessão para de ocupar a lista de ativas. Cobre running e
// needs_you — needs_you é o mais importante, porque uma pergunta cujo processo
// morreu não seria respondida nunca e o notifier ficaria re-cutucando.
func TestHookSessionEndIdlesActiveSession(t *testing.T) {
	casos := []struct {
		nome   string
		estado session.State
		reason string
	}{
		{"running com terminal fechado", session.StateRunning, "prompt_input_exit"},
		{"needs_you com processo morto", session.StateNeedsYou, "other"},
		{"clear troca o id da sessão", session.StateRunning, "clear"},
		{"resume abandona esta sessão", session.StateRunning, "resume"},
		{"motivo desconhecido também encerra", session.StateRunning, "motivo-que-ainda-nao-existe"},
	}
	for _, c := range casos {
		t.Run(c.nome, func(t *testing.T) {
			cfg, reg := testDeps()
			now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
			reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: c.estado, CreatedAt: now, UpdatedAt: now})
			if c.estado == session.StateNeedsYou {
				reg.SetPendingPrompt("s", "posso rodar rm?")
			}

			rec := postHook(t, cfg, reg, `{"session_id":"s","hook_event_name":"SessionEnd","reason":"`+c.reason+`"}`)

			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, quero 200", rec.Code)
			}
			s, ok := reg.Get("s")
			if !ok {
				t.Fatal("SessionEnd não pode apagar a sessão, só rebaixar para idle")
			}
			if s.State != session.StateIdle {
				t.Errorf("State = %q, quero %q", s.State, session.StateIdle)
			}
			if s.PendingPrompt != "" {
				t.Errorf("PendingPrompt = %q, quero vazio: ninguém vai responder a um processo morto", s.PendingPrompt)
			}
		})
	}
}

// TestHookSessionEndKeepsVerdict: done/error já têm veredito. Rebaixar para idle
// apagaria "concluída"/"falhou" da lista da usuária sem ganhar nada — e o Stop
// vem SEMPRE logo antes do SessionEnd quando a sessão termina de verdade.
func TestHookSessionEndKeepsVerdict(t *testing.T) {
	for _, estado := range []session.State{session.StateDone, session.StateError} {
		t.Run(string(estado), func(t *testing.T) {
			cfg, reg := testDeps()
			now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
			reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: estado, CreatedAt: now, UpdatedAt: now})

			postHook(t, cfg, reg, `{"session_id":"s","hook_event_name":"SessionEnd","reason":"other"}`)

			if s, _ := reg.Get("s"); s.State != estado {
				t.Errorf("State = %q, quero %q intocado", s.State, estado)
			}
		})
	}
}

// TestHookSessionEndNeverRegisters: um adeus não pode CRIAR sessão. Sem isto, um
// SessionEnd atrasado (de uma sessão que o reaper já esqueceu) ressuscitaria um
// card morto na lista — e ele nasceria running, o zumbi que estamos matando.
func TestHookSessionEndNeverRegisters(t *testing.T) {
	cfg, reg := testDeps()

	rec := postHook(t, cfg, reg, `{"session_id":"nunca-vista","hook_event_name":"SessionEnd","reason":"other","cwd":"/Users/example/proj","machine":"macbook"}`)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if _, ok := reg.Get("nunca-vista"); ok {
		t.Fatal("SessionEnd de sessão desconhecida não pode auto-registrar nada")
	}
}

// TestHookTitleFromRoleWinsOverCwd: sessão de agente Maestri roda em
// .maestri/roles/<uuid>, um caminho que só produz "personal" pelo cwd — TODOS os
// agentes apareciam com o mesmo nome. O hook.sh lê o role.json (que só existe na
// máquina de origem) e manda o nome pronto; aqui ele tem que vencer o cwd.
func TestHookTitleFromRoleWinsOverCwd(t *testing.T) {
	cfg, reg := testDeps()

	postHook(t, cfg, reg, `{"session_id":"agente-1","hook_event_name":"SessionStart","title":"cutuque","cwd":"/Users/dev/coding/personal/.maestri/roles/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","machine":"macbook"}`)

	s, ok := reg.Get("agente-1")
	if !ok {
		t.Fatal("sessão não registrada")
	}
	if s.Title != "cutuque" {
		t.Errorf("Title = %q, quero %q", s.Title, "cutuque")
	}
}

func TestHookUnknownEventIsNoOp(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"PreToolUse"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if s, _ := reg.Get("s"); s.State != session.StateRunning {
		t.Errorf("State = %q, quero \"running\" (evento não mapeado é no-op)", s.State)
	}
}

func TestHookBadRequest(t *testing.T) {
	cfg, reg := testDeps()

	for _, body := range []string{`{isso não é json`, `{"hook_event_name":"Stop"}`} {
		req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer secret")
		rec := httptest.NewRecorder()

		Router(cfg, reg, nil).ServeHTTP(rec, req)

		if rec.Code != http.StatusBadRequest {
			t.Errorf("body %q => status %d, quero 400", body, rec.Code)
		}
	}
}

func TestHookRequiresAuth(t *testing.T) {
	cfg, reg := testDeps()
	body := `{"session_id":"s","hook_event_name":"Stop"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, quero 401", rec.Code)
	}
}
