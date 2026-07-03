package server

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/event"
	"github.com/vxfontes/cutuque/hub/internal/session"
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
	// Pane e TmuxSocket vêm de $TMUX_PANE/$TMUX quando o claude roda no tmux;
	// juntos formam o alvo composto que o app usa pra abrir o terminal ao vivo
	// EXATO dessa sessão. Vazios = sessão local fora do tmux.
	Pane       string `json:"pane"`
	TmuxSocket string `json:"tmux_socket"`
}

// paneTarget compõe o alvo tmux "<socket>\t<pane>" (vazio se não estiver no
// tmux). É o que o app passa de volta para capture/send-keys/resize.
func (p hookPayload) paneTarget() string {
	if p.Pane == "" {
		return ""
	}
	if p.TmuxSocket == "" {
		return p.Pane
	}
	// Normaliza o socket como o listador faz (/private/tmp == /tmp no macOS),
	// para o alvo do hook casar com o da listagem (dedup no app).
	sock := strings.TrimPrefix(p.TmuxSocket, "/private")
	return sock + "\t" + p.Pane
}

// hookTitle escolhe um título LEGÍVEL para uma sessão auto-registrada por hook:
// título explícito > pasta significativa do cwd. NÃO usa a mensagem do hook: a
// mensagem de Notification é texto de status ("Claude is waiting for your
// input" / "Claude needs your permission"), péssimo como nome de sessão. A pasta
// pula componentes que são UUID (ex.: .maestri/roles/<uuid>) ou ruído (.maestri,
// roles, Users) — senão o título vinha um UUID sem sentido.
func hookTitle(p hookPayload) string {
	if p.Title != "" {
		return p.Title
	}
	return niceNameFromCwd(p.Cwd)
}

var hookNoiseDir = map[string]bool{".maestri": true, "roles": true, "Users": true, "": true}

func niceNameFromCwd(cwd string) string {
	parts := strings.Split(strings.Trim(cwd, "/"), "/")
	for i := len(parts) - 1; i >= 0; i-- {
		c := parts[i]
		if hookNoiseDir[c] || looksUUID(c) {
			continue
		}
		return c
	}
	if len(parts) > 0 {
		return parts[len(parts)-1]
	}
	return "sessão"
}

// localizePermissionMessage traduz as mensagens conhecidas do Claude Code (que
// vêm em inglês no hook) para PT-BR, para o push e o prompt de "precisa de você"
// aparecerem em português. Preserva o nome da ferramenta ("...use Bash"). Texto
// desconhecido/custom passa intacto. A comparação é case-insensitive; o prefixo
// é ASCII, então o fatiamento por bytes casa com o tamanho em runes.
func localizePermissionMessage(msg string) string {
	m := strings.TrimSpace(msg)
	lower := strings.ToLower(m)
	const prefixUse = "claude needs your permission to use "
	if strings.HasPrefix(lower, prefixUse) {
		tool := m[len(prefixUse):]
		return "Claude precisa da sua permissão para usar " + tool
	}
	if strings.HasPrefix(lower, "claude needs your permission") {
		return "Claude precisa da sua permissão"
	}
	return msg
}

// notificationBlocks classifica a MENSAGEM de um hook Notification do Claude
// Code em "bloqueio real" (precisa de você) vs "ocioso" (só terminou o turno e
// está esperando). O Claude dispara DOIS textos distintos:
//
//   - "Claude needs your permission to use X" → está BLOQUEADO esperando uma
//     decisão: precisa de você (needs_you).
//   - "Claude is waiting for your input"      → ocioso 60s após terminar o turno:
//     NÃO é bloqueio. Tratar como needs_you fazia sessões concluídas voltarem
//     para "precisa de você" sozinhas (bug relatado). Vira finished (done).
//
// Regra: bloqueia SÓ quando o texto fala em permissão/aprovação; "waiting for
// your input" (e variações de espera ociosa) não bloqueiam. O default para
// mensagens desconhecidas é bloquear (conservador: na dúvida, cutuca — melhor um
// falso needs_you que uma pergunta real engolida).
func notificationBlocks(msg string) bool {
	m := strings.ToLower(strings.TrimSpace(msg))
	// Espera ociosa: o Claude terminou e está só aguardando input — não bloqueia.
	if strings.Contains(m, "waiting for your input") || strings.Contains(m, "waiting for input") {
		return false
	}
	return true
}

// looksUUID diz se s parece um id (hex + hífens, 8+ chars) — para não virar título.
func looksUUID(s string) bool {
	if len(s) < 8 {
		return false
	}
	for _, r := range s {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F') || r == '-') {
			return false
		}
	}
	return strings.Contains(s, "-") || len(s) >= 16
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

		// Probes/health-checks (ex.: CodexBar roda claude em ~/Library/Application
		// Support/.../ClaudeProbe repetidamente) não são sessões reais do usuário —
		// ignora tudo (não registra, não cutuca), senão inundam o app.
		if session.IsEphemeralCwd(p.Cwd) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
			return
		}

		// Qualquer sessão do Claude no Mac (não só as lançadas pelo hub) aparece
		// e pode cutucar: registra se ainda não conhecida antes de transicionar.
		pane := p.paneTarget()
		eng.EnsureRegistered(p.SessionID, p.Machine, "claude-code", hookTitle(p), p.Cwd, pane)

		switch p.HookEventName {
		case "Notification":
			eng.SetPane(p.SessionID, pane)
			if notificationBlocks(p.Message) {
				// Bloqueio real (permissão/decisão): precisa de você. Traduz a
				// mensagem conhecida do Claude para PT-BR antes de exibir.
				eng.Apply(event.Event{SessionID: p.SessionID, Type: event.NeedsInput, Data: localizePermissionMessage(p.Message), At: time.Now()})
			} else {
				// Espera ociosa ("waiting for your input"): o turno acabou. Marca
				// finished (done) — NÃO ressuscita a sessão para needs_you.
				eng.Apply(event.Event{SessionID: p.SessionID, Type: event.Finished, At: time.Now()})
			}
		case "Stop":
			eng.Apply(event.Event{SessionID: p.SessionID, Type: event.Finished, At: time.Now()})
		case "SessionStart", "UserPromptSubmit":
			// Sessão (re)ativa: volta a running (ex.: usuária mandou novo prompt
			// numa sessão que estava done). External:true marca que veio de hook —
			// o Runner (autoritativo) usa External:false para reassumir (#1).
			eng.Apply(event.Event{SessionID: p.SessionID, Type: event.SessionStarted, Machine: p.Machine, Agent: "claude-code", Title: hookTitle(p), Cwd: p.Cwd, Pane: pane, External: true, At: time.Now()})
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
	}
}
