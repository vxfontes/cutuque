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
