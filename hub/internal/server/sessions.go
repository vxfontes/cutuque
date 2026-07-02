package server

import (
	"encoding/json"
	"net/http"

	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// sessionsResponse é o corpo de GET /sessions.
type sessionsResponse struct {
	Sessions []session.Session `json:"sessions"`
}

// SessionsHandler responde a lista de sessões do registry em JSON.
func SessionsHandler(reg *registry.Registry) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sessions := reg.List()
		if sessions == nil {
			sessions = []session.Session{} // serializa como [] e não null
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(sessionsResponse{Sessions: sessions})
	}
}
