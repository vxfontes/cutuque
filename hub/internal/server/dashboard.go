package server

import (
	"bytes"
	_ "embed"
	"net/http"
)

// dashboardHTML é o Command Center web, embutido no binário do hub. É servido
// como estático em GET /dashboard (aberto). Servir a página pela MESMA origem do
// hub evita o bloqueio de WebSocket cross-origin do navegador.
//
//go:embed dashboard.html
var dashboardHTML []byte

// tokenPlaceholder é substituído pelo token real do hub ao servir a página, para
// o dashboard conectar no WS sem exigir ?token= na URL (é o hub do próprio dono).
var tokenPlaceholder = []byte("__CUTUQUE_TOKEN__")

// DashboardHandler serve a página do Command Center com o token do hub injetado.
func DashboardHandler(token string) http.HandlerFunc {
	page := bytes.Replace(dashboardHTML, tokenPlaceholder, []byte(token), 1)
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(page)
	}
}
