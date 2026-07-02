package server

import (
	"net/http"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/registry"
)

// Router registra as rotas do hub. As rotas protegidas passam pelo middleware
// de token; /health fica aberto para healthcheck.
func Router(cfg config.Config, reg *registry.Registry) *http.ServeMux {
	mux := http.NewServeMux()

	// Aberta (sem auth).
	mux.Handle("GET /health", HealthHandler())

	// Protegidas por token.
	mux.Handle("GET /sessions", requireAuth(cfg.Token, SessionsHandler(reg)))
	mux.Handle("GET /ws", requireAuth(cfg.Token, WSHandler(reg)))

	// Dev-only: seed de dados fake. Em prod o handler responde 404.
	mux.Handle("POST /dev/seed", requireAuth(cfg.Token, SeedHandler(cfg, reg)))

	return mux
}

// New monta o *http.Server do hub a partir da config e do registry.
func New(cfg config.Config, reg *registry.Registry) *http.Server {
	return &http.Server{
		Addr:              cfg.Addr(),
		Handler:           Router(cfg, reg),
		ReadHeaderTimeout: 5 * time.Second,
	}
}
