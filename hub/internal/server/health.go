// Package server monta o servidor HTTP do hub e seus handlers.
package server

import (
	"encoding/json"
	"net/http"
)

// HealthHandler responde ao healthcheck do hub.
func HealthHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{
			"status":  "ok",
			"service": "cutuque-hub",
		})
	}
}
