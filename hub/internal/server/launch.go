package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/vxfontes/cutuque/hub/internal/launcher"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// maxLaunchBody limita o corpo dos POSTs de comando (mesma defesa do hook: um
// prompt real tem poucos KB; acima disso é lixo/abuso — review F2, achado #3).
const maxLaunchBody = 64 * 1024

// Launcher é a superfície que os handlers de comando consomem. *launcher.Launcher
// a satisfaz; um fake a implementa nos testes.
type Launcher interface {
	Launch(ctx context.Context, machine, agent, prompt, cwd, model, effort string) (session.Session, error)
	Approve(id string) error
	Deny(id string) error
	SendText(id, text string) error
	Reply(id, text string) error
	Machines() []string
	Remove(id string) error
	Resolve(id string) error
	ImportHistory(id string) error
	Discover(machine string) ([]session.Discovered, error)
	Live(machine string) ([]session.Discovered, error)
	ListDirs(machine, path string) (session.DirListing, error)
	Adopt(machine, id, cwd, title string) (session.Session, error)
	TmuxList(machine string) ([]session.Discovered, error)
	TmuxCapture(machine, target string) (string, error)
	TmuxSend(machine, target, text string) error
	TmuxKey(machine, target, key string) error
	TmuxResize(machine, target string, cols, rows int) error
	TmuxKill(machine, target string) error
	TmuxKillServer(machine, socket string) error
}

// tmuxKeyRequest é o corpo de POST /machines/{machine}/tmux/key.
type tmuxKeyRequest struct {
	Target string `json:"target"`
	Key    string `json:"key"`
}

// TmuxKeyHandler envia uma tecla nomeada (Ctrl+C, setas, Esc…) ao pane.
// POST {"target","key"} → 200 {"ok":true} | 400 | 404 | 502.
func TmuxKeyHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		machine := r.PathValue("machine")
		r.Body = http.MaxBytesReader(w, r.Body, maxLaunchBody)
		var req tmuxKeyRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Target == "" || req.Key == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		err := lch.TmuxKey(machine, req.Target, req.Key)
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "tmux_failed")
		default:
			writeOK(w)
		}
	}
}

// tmuxResizeRequest é o corpo de POST /machines/{machine}/tmux/resize. cols<=0
// restaura o dimensionamento automático.
type tmuxResizeRequest struct {
	Target string `json:"target"`
	Cols   int    `json:"cols"`
	Rows   int    `json:"rows"`
}

// tmuxKillRequest é o corpo de POST /machines/{machine}/tmux/kill.
type tmuxKillRequest struct {
	Target string `json:"target"`
}

// TmuxKillHandler encerra o pane alvo (kill-pane): fecha o Claude daquele
// terminal. Destrutivo — o app confirma antes de chamar.
//
//	POST /machines/{machine}/tmux/kill {"target":"<socket>\t<pane>"} → 200 ok |
//	400 bad_request | 404 unknown_machine | 502 tmux_failed
func TmuxKillHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		machine := r.PathValue("machine")
		r.Body = http.MaxBytesReader(w, r.Body, maxLaunchBody)
		var req tmuxKillRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Target == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		err := lch.TmuxKill(machine, req.Target)
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "tmux_failed")
		default:
			writeOK(w)
		}
	}
}

// tmuxKillServerRequest é o corpo de POST /machines/{machine}/tmux/kill-server.
type tmuxKillServerRequest struct {
	Socket string `json:"socket"`
}

// ReplyHandler entrega uma resposta em texto à sessão, roteando pelo canal certo
// (tmux send-keys se tiver pane, senão stdin/resume). É o que a resposta vinda
// direto do push usa.
//
//	POST /sessions/{id}/reply {"text":"sim, prossiga"} → 200 ok | 400 | 404 | 409
func ReplyHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		r.Body = http.MaxBytesReader(w, r.Body, maxLaunchBody)
		var req inputRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Text == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		err := lch.Reply(id, req.Text)
		switch {
		case errors.Is(err, launcher.ErrUnknownSession):
			writeJSONError(w, http.StatusNotFound, "unknown_session")
		case err != nil:
			writeJSONError(w, http.StatusConflict, "reply_failed")
		default:
			writeOK(w)
		}
	}
}

// TmuxKillServerHandler encerra o servidor tmux inteiro do socket (todos os
// panes). Destrutivo — o app confirma antes.
//
//	POST /machines/{machine}/tmux/kill-server {"socket":"/tmp/tmux-501/main"} →
//	200 ok | 400 bad_request | 404 unknown_machine | 502 tmux_failed
func TmuxKillServerHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		machine := r.PathValue("machine")
		r.Body = http.MaxBytesReader(w, r.Body, maxLaunchBody)
		var req tmuxKillServerRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Socket == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		err := lch.TmuxKillServer(machine, req.Socket)
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "tmux_failed")
		default:
			writeOK(w)
		}
	}
}

// TmuxResizeHandler fixa/restaura o tamanho da janela do pane (para o terminal
// caber no celular). POST {"target","cols","rows"} → 200 {"ok":true}.
func TmuxResizeHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		machine := r.PathValue("machine")
		r.Body = http.MaxBytesReader(w, r.Body, maxLaunchBody)
		var req tmuxResizeRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Target == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		err := lch.TmuxResize(machine, req.Target, req.Cols, req.Rows)
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "tmux_failed")
		default:
			writeOK(w)
		}
	}
}

// TmuxListHandler lista os panes do tmux rodando claude numa máquina (a ponte
// para observar/controlar sessões vivas de terminal). Mesmo contrato do discover.
func TmuxListHandler(lch Launcher) http.HandlerFunc {
	return discoveryLikeHandler(func(machine string) ([]session.Discovered, error) {
		return lch.TmuxList(machine)
	})
}

// DirsHandler lista as subpastas de um caminho na máquina, para o seletor de
// pastas do app navegar as pastas do Mac ao criar uma sessão.
//
//	GET /machines/{machine}/dirs?path=/Users/example → 200 {path,parent,dirs}
//	(path vazio → home da máquina) | 404 unknown_machine | 502 discover_failed
func DirsHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		listing, err := lch.ListDirs(r.PathValue("machine"), r.URL.Query().Get("path"))
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "discover_failed")
		default:
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(listing)
		}
	}
}

// TmuxScreenHandler devolve a tela atual do pane (espelho ao vivo).
//
//	GET /machines/{machine}/tmux/screen?target=%12 → 200 {"screen":"..."} |
//	400 bad_request | 404 unknown_machine | 502 tmux_failed
func TmuxScreenHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		machine := r.PathValue("machine")
		target := r.URL.Query().Get("target")
		if target == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		screen, err := lch.TmuxCapture(machine, target)
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "tmux_failed")
		default:
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]string{"screen": screen})
		}
	}
}

// tmuxKeysRequest é o corpo de POST /machines/{machine}/tmux/keys.
type tmuxKeysRequest struct {
	Target string `json:"target"`
	Text   string `json:"text"`
}

// TmuxKeysHandler digita `text` no pane e submete (Enter) — a mensagem do
// celular caindo no terminal que já roda.
//
//	POST {"target":"%12","text":"..."} → 200 {"ok":true} | 400 | 404 | 502
func TmuxKeysHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		machine := r.PathValue("machine")
		r.Body = http.MaxBytesReader(w, r.Body, maxLaunchBody)
		var req tmuxKeysRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Target == "" || req.Text == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		err := lch.TmuxSend(machine, req.Target, req.Text)
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "tmux_failed")
		default:
			writeOK(w)
		}
	}
}

// DiscoverHandler lista as sessões do Claude Code existentes numa máquina
// (inclusive as não lançadas pelo Cutuque). 200 {"sessions":[Discovered...]} |
// 404 unknown_machine | 502 discover_failed.
func DiscoverHandler(lch Launcher) http.HandlerFunc {
	return discoveryLikeHandler(func(machine string) ([]session.Discovered, error) {
		return lch.Discover(machine)
	})
}

// LiveHandler lista as sessões do Claude Code RODANDO agora numa máquina.
// Mesmo contrato do DiscoverHandler.
func LiveHandler(lch Launcher) http.HandlerFunc {
	return discoveryLikeHandler(func(machine string) ([]session.Discovered, error) {
		return lch.Live(machine)
	})
}

// discoveryLikeHandler é o corpo comum de discover/live: {machine} → lista, com
// o mesmo mapeamento de erro/status.
func discoveryLikeHandler(list func(machine string) ([]session.Discovered, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sessions, err := list(r.PathValue("machine"))
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case errors.Is(err, launcher.ErrDiscoverFailed):
			// Máquina existe, mas a busca falhou (ssh/python/timeout) — 502, não
			// 404: o cliente sabe que o nome está certo e é transitório.
			writeJSONError(w, http.StatusBadGateway, "discover_failed")
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "discover_failed")
		default:
			if sessions == nil {
				sessions = []session.Discovered{}
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string][]session.Discovered{"sessions": sessions})
		}
	}
}

// adoptRequest é o corpo de POST /machines/{machine}/adopt.
type adoptRequest struct {
	ID    string `json:"id"`
	Cwd   string `json:"cwd"`
	Title string `json:"title"`
}

// AdoptHandler registra uma sessão descoberta para poder abri-la e continuar.
// 201 {"session":{...}} | 400 bad_request | 404 unknown_machine.
func AdoptHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		machine := r.PathValue("machine")
		r.Body = http.MaxBytesReader(w, r.Body, maxLaunchBody)
		var req adoptRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ID == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		s, err := lch.Adopt(machine, req.ID, req.Cwd, req.Title)
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
			return
		case errors.Is(err, launcher.ErrInvalidSessionID):
			writeJSONError(w, http.StatusBadRequest, "invalid_session_id")
			return
		case err != nil:
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(launchResponse{Session: s})
	}
}

// TargetsHandler lista as máquinas disponíveis para lançar sessões.
//
//	200 {"targets":["macbook","macmini"]}
func TargetsHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string][]string{"targets": lch.Machines()})
	}
}

// ResolveHandler tira a sessão de needs_you (marca concluída) sem apagá-la.
//
//	200 {"ok":true} | 404 unknown_session
func ResolveHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := lch.Resolve(r.PathValue("id")); err != nil {
			writeJSONError(w, http.StatusNotFound, "unknown_session")
			return
		}
		writeOK(w)
	}
}

// HistoryHandler importa, sob demanda, o transcript de uma sessão externa já
// registrada, para o chat mostrar a conversa ao abrir (em vez de "sem mensagens
// ainda"). Idempotente no Launcher. O app chama isto ao abrir o detalhe de uma
// sessão externa; depois relê GET /output para exibir o histórico.
//
//	POST /sessions/{id}/history → 200 ok | 404 unknown_session
func HistoryHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := lch.ImportHistory(r.PathValue("id")); err != nil {
			writeJSONError(w, http.StatusNotFound, "unknown_session")
			return
		}
		writeOK(w)
	}
}

// DeleteSessionHandler apaga uma sessão (fecha se viva + remove do registry).
//
//	200 {"ok":true} | 404 unknown_session
func DeleteSessionHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if err := lch.Remove(id); err != nil {
			writeJSONError(w, http.StatusNotFound, "unknown_session")
			return
		}
		writeOK(w)
	}
}

// launchRequest é o corpo de POST /sessions. Cwd é opcional: a pasta onde o
// `claude` roda; vazio = home.
type launchRequest struct {
	Machine string `json:"machine"`
	Agent   string `json:"agent"`
	Prompt  string `json:"prompt"`
	Cwd     string `json:"cwd,omitempty"`
	Model   string `json:"model,omitempty"`  // alias/nome do modelo do claude (vazio = default)
	Effort  string `json:"effort,omitempty"` // low|medium|high|xhigh|max (vazio = default)
}

// launchResponse é o corpo de sucesso de POST /sessions.
type launchResponse struct {
	Session session.Session `json:"session"`
}

// inputRequest é o corpo de POST /sessions/{id}/input.
type inputRequest struct {
	Text string `json:"text"`
}

// writeJSONError responde um status com {"error": code}.
func writeJSONError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": code})
}

// writeOK responde 200 {"ok":true}.
func writeOK(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
}

// LaunchHandler dispara uma nova sessão. O contexto da sessão é desacoplado do
// request (a sessão precisa sobreviver à resposta HTTP).
//
//	201 {"session":{...}} | 400 unknown_machine|unknown_agent|bad_request |
//	429 too_many_sessions | 504 launch_timeout
func LaunchHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxLaunchBody)
		var req launchRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Machine == "" || req.Agent == "" || req.Prompt == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}

		s, err := lch.Launch(context.Background(), req.Machine, req.Agent, req.Prompt, req.Cwd, req.Model, req.Effort)
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusBadRequest, "unknown_machine")
		case errors.Is(err, launcher.ErrUnknownAgent):
			writeJSONError(w, http.StatusBadRequest, "unknown_agent")
		case errors.Is(err, launcher.ErrTooManySessions):
			// SEC-007: teto de sessões concorrentes atingido — 429, o cliente
			// pode tentar de novo mais tarde (não é um erro do pedido em si).
			writeJSONError(w, http.StatusTooManyRequests, "too_many_sessions")
		case errors.Is(err, launcher.ErrLaunchTimeout):
			writeJSONError(w, http.StatusGatewayTimeout, "launch_timeout")
		case errors.Is(err, launcher.ErrShuttingDown):
			// Hub encerrando: 503, o cliente tenta de novo quando voltar.
			writeJSONError(w, http.StatusServiceUnavailable, "shutting_down")
		case err != nil:
			writeJSONError(w, http.StatusBadRequest, "bad_request")
		default:
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(launchResponse{Session: s})
		}
	}
}

// decideHandler serve approve/deny: valida e chama a ação dada.
//
//	200 {"ok":true} | 404 unknown_session | 409 stale_state
func decideHandler(action func(id string) error) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		err := action(id)
		switch {
		case errors.Is(err, launcher.ErrUnknownSession):
			writeJSONError(w, http.StatusNotFound, "unknown_session")
		case errors.Is(err, launcher.ErrStaleState):
			writeJSONError(w, http.StatusConflict, "stale_state")
		case err != nil:
			writeJSONError(w, http.StatusConflict, "stale_state")
		default:
			writeOK(w)
		}
	}
}

// ApproveHandler aprova o pedido pendente da sessão {id}.
func ApproveHandler(lch Launcher) http.HandlerFunc { return decideHandler(lch.Approve) }

// DenyHandler nega o pedido pendente da sessão {id}.
func DenyHandler(lch Launcher) http.HandlerFunc { return decideHandler(lch.Deny) }

// InputHandler envia texto arbitrário à sessão viva {id}.
//
//	200 {"ok":true} | 400 bad_request | 404 unknown_session | 409 no_live_session
func InputHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		r.Body = http.MaxBytesReader(w, r.Body, maxLaunchBody)
		var req inputRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Text == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}

		err := lch.SendText(id, req.Text)
		switch {
		case errors.Is(err, launcher.ErrUnknownSession):
			writeJSONError(w, http.StatusNotFound, "unknown_session")
		case errors.Is(err, launcher.ErrNoHandle):
			writeJSONError(w, http.StatusConflict, "no_live_session")
		case err != nil:
			writeJSONError(w, http.StatusConflict, "no_live_session")
		default:
			writeOK(w)
		}
	}
}
