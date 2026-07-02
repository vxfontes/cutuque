package server

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/event"
)

// hookPayload é o corpo enviado pelos hooks do Claude Code (ver docs/09).
type hookPayload struct {
	SessionID     string `json:"session_id"`
	HookEventName string `json:"hook_event_name"`
	Message       string `json:"message"`
}

// HookHandler recebe hooks do Claude Code e os traduz em eventos para o engine:
//
//   - Notification → needs_input (Data = message): o agente pediu algo.
//   - Stop        → finished: o agente terminou.
//
// Outros hooks (PreToolUse, etc.) são aceitos e ignorados. É um canal de
// detecção complementar ao stream-json do Runner (docs/02, docs/03).
func HookHandler(eng *engine.Engine) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var p hookPayload
		if err := json.NewDecoder(r.Body).Decode(&p); err != nil || p.SessionID == "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "bad_request"})
			return
		}

		switch p.HookEventName {
		case "Notification":
			eng.Apply(event.Event{SessionID: p.SessionID, Type: event.NeedsInput, Data: p.Message, At: time.Now()})
		case "Stop":
			eng.Apply(event.Event{SessionID: p.SessionID, Type: event.Finished, At: time.Now()})
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
	}
}
