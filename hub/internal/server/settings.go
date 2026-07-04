package server

import (
	"encoding/json"
	"net/http"
	"time"
)

// RenudgeController lê e ajusta o intervalo do re-cutucão em runtime.
// *notifier.Notifier o satisfaz.
type RenudgeController interface {
	RenudgeInterval() time.Duration
	SetRenudgeInterval(time.Duration)
}

// ForegroundController marca se o app está em foreground (para suprimir push).
// `at` é um timestamp monotônico do cliente para ordenar updates concorrentes.
// *notifier.Notifier o satisfaz.
type ForegroundController interface {
	SetForeground(active bool, at int64)
	// SetMuted liga/desliga o "modo desligado": mudo = true faz o hub PARAR de
	// disparar qualquer push (needs_you, done, Live Activity) para esta instalação.
	SetMuted(muted bool)
}

// appActiveBody é o corpo de POST /app/active: active=false = app "desligado"
// (não notifica em nada).
type appActiveBody struct {
	Active bool `json:"active"`
}

// AppActiveHandler liga/desliga TODAS as notificações do hub para o app (o
// "encerrar" que a usuária pediu — sem push, sem Live Activity).
//
//	POST {"active":true|false} → 200 {"ok":true}
func AppActiveHandler(fc ForegroundController) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 4*1024)
		var b appActiveBody
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
			writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "bad_request"})
			return
		}
		fc.SetMuted(!b.Active)
		writeJSONResp(w, http.StatusOK, map[string]bool{"ok": true})
	}
}

// foregroundBody é o corpo de POST /app/foreground. `at` (ms monotônicos do
// cliente) ordena updates que podem chegar fora de ordem (SEC-102).
type foregroundBody struct {
	Active bool  `json:"active"`
	At     int64 `json:"at"`
}

// ForegroundHandler recebe o estado de foreground do app (heartbeat enquanto
// aberto; false ao ir pro background). Enquanto ativo, o hub não dispara push.
//
//	POST {"active":true|false,"at":<ms>} → 200 {"ok":true}
func ForegroundHandler(fc ForegroundController) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 4*1024)
		var b foregroundBody
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
			writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "bad_request"})
			return
		}
		fc.SetForeground(b.Active, b.At)
		writeJSONResp(w, http.StatusOK, map[string]bool{"ok": true})
	}
}

// Faixa aceita para o intervalo do re-cutucão (segundos): nem tão curto que vire
// spam, nem tão longo que perca o sentido de "insistente".
const (
	minRenudgeSeconds = 5
	maxRenudgeSeconds = 600
)

// settingsBody é o corpo de leitura/escrita do intervalo do re-cutucão.
type settingsBody struct {
	RenudgeSeconds int `json:"renudge_seconds"`
}

// SettingsHandler expõe GET (ler) e PUT (ajustar) o intervalo do re-cutucão.
func SettingsHandler(rc RenudgeController) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			writeJSONResp(w, http.StatusOK, settingsBody{
				RenudgeSeconds: int(rc.RenudgeInterval() / time.Second),
			})
		case http.MethodPut:
			r.Body = http.MaxBytesReader(w, r.Body, 4*1024)
			var b settingsBody
			if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
				writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "bad_request"})
				return
			}
			if b.RenudgeSeconds < minRenudgeSeconds || b.RenudgeSeconds > maxRenudgeSeconds {
				writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "out_of_range"})
				return
			}
			rc.SetRenudgeInterval(time.Duration(b.RenudgeSeconds) * time.Second)
			writeJSONResp(w, http.StatusOK, settingsBody{RenudgeSeconds: b.RenudgeSeconds})
		default:
			w.Header().Set("Allow", "GET, PUT")
			writeJSONResp(w, http.StatusMethodNotAllowed, map[string]string{"error": "method_not_allowed"})
		}
	}
}

// writeJSONResp escreve uma resposta JSON com o status dado.
func writeJSONResp(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
