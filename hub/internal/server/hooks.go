package server

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/event"
)

// hookPayload é o corpo enviado pelos hooks do Claude Code (ver docs/09). cwd e
// machine permitem AUTO-REGISTRAR sessões que o hub não lançou (qualquer claude
// no Mac aparece e cutuca).
type hookPayload struct {
	SessionID     string `json:"session_id"`
	HookEventName string `json:"hook_event_name"`
	Message       string `json:"message"`
	Cwd           string `json:"cwd"`
	Machine       string `json:"machine"`
	Title         string `json:"title"`
}

// hookTitle escolhe um título legível para uma sessão auto-registrada por hook:
// título explícito > última mensagem (Notification) > última pasta do cwd.
func hookTitle(p hookPayload) string {
	if p.Title != "" {
		return p.Title
	}
	if p.Message != "" {
		return p.Message
	}
	cwd := strings.TrimRight(p.Cwd, "/")
	if i := strings.LastIndex(cwd, "/"); i >= 0 {
		return cwd[i+1:]
	}
	return cwd
}

// maxHookBody limita o corpo do hook: payloads reais têm poucos KB; qualquer
// coisa maior é lixo ou abuso (DoS por buffer em memória — review F2, achado #3).
const maxHookBody = 64 * 1024

// HookHandler recebe hooks do Claude Code e os traduz em eventos para o engine:
//
//   - Notification → needs_input (Data = message): o agente pediu algo.
//   - Stop        → finished: o agente terminou.
//
// Outros hooks (PreToolUse, etc.) são aceitos e ignorados. É um canal de
// detecção complementar ao stream-json do Runner (docs/02, docs/03).
func HookHandler(eng *engine.Engine) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxHookBody)
		var p hookPayload
		if err := json.NewDecoder(r.Body).Decode(&p); err != nil || p.SessionID == "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "bad_request"})
			return
		}

		// Qualquer sessão do Claude no Mac (não só as lançadas pelo hub) aparece
		// e pode cutucar: registra se ainda não conhecida antes de transicionar.
		eng.EnsureRegistered(p.SessionID, p.Machine, "claude-code", hookTitle(p), p.Cwd)

		switch p.HookEventName {
		case "Notification":
			eng.Apply(event.Event{SessionID: p.SessionID, Type: event.NeedsInput, Data: p.Message, At: time.Now()})
		case "Stop":
			eng.Apply(event.Event{SessionID: p.SessionID, Type: event.Finished, At: time.Now()})
		case "SessionStart", "UserPromptSubmit":
			// Sessão (re)ativa: volta a running (ex.: usuária mandou novo prompt
			// numa sessão que estava done). ensureRunning cuida do register/bump.
			eng.Apply(event.Event{SessionID: p.SessionID, Type: event.SessionStarted, Machine: p.Machine, Agent: "claude-code", Title: hookTitle(p), Cwd: p.Cwd, At: time.Now()})
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
	}
}
