package server

import (
	_ "embed"
	"net/http"
)

// dashboardHTML é o Command Center web, embutido no binário do hub. É servido
// como estático em GET /dashboard (aberto, sem token — a página só lê dados
// depois de conectar no WS, que exige token via ?token=). Servir a página pela
// MESMA origem do hub evita o bloqueio de WebSocket cross-origin do navegador.
//
//go:embed dashboard.html
var dashboardHTML []byte

// DashboardHandler serve a página do Command Center.
func DashboardHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(dashboardHTML)
	}
}
