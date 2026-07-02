package server

import (
	"encoding/json"
	"net/http"

	"github.com/vxfontes/cutuque/hub/internal/devices"
)

// maxDeviceBody limita o corpo de POST /devices (um token + platform tem poucas
// centenas de bytes; acima disso é lixo/abuso — mesma defesa dos outros POSTs).
const maxDeviceBody = 8 * 1024

// deviceTokenMinLen/deviceTokenMaxLen delimitam o tamanho aceito do device token
// em hex. Um token APNs real tem 64 hex chars; a faixa larga tolera variações
// futuras sem virar um campo livre.
const (
	deviceTokenMinLen = 32
	deviceTokenMaxLen = 200
)

// registerDeviceRequest é o corpo de POST /devices.
type registerDeviceRequest struct {
	Token    string `json:"token"`
	Platform string `json:"platform"`
}

// DevicesHandler registra um device token para receber push.
//
//	200 {"ok":true} | 400 bad_request (token não-hex/fora do range ou platform vazio)
func DevicesHandler(store *devices.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxDeviceBody)
		var req registerDeviceRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil ||
			req.Platform == "" || !validHexToken(req.Token) {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		store.Upsert(req.Token, req.Platform)
		writeOK(w)
	}
}

// validHexToken valida que o token é hex puro com tamanho na faixa aceita.
func validHexToken(tok string) bool {
	if len(tok) < deviceTokenMinLen || len(tok) > deviceTokenMaxLen {
		return false
	}
	for _, c := range tok {
		isHex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !isHex {
			return false
		}
	}
	return true
}
