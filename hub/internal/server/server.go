package server

import (
	"net/http"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/registry"
)

// Router registra as rotas do hub. As rotas protegidas passam pelo middleware
// de token; /health fica aberto para healthcheck. lch pode ser nil quando os
// comandos de lançamento/aprovação não são necessários (ex.: alguns testes).
func Router(cfg config.Config, reg *registry.Registry, lch Launcher) *http.ServeMux {
	mux := http.NewServeMux()

	// O engine é sem estado próprio (só encapsula o registry), então instanciá-lo
	// aqui para os hooks é equivalente ao usado pelos runners.
	eng := engine.New(reg)

	// Aberta (sem auth).
	mux.Handle("GET /health", HealthHandler())

	// Protegidas por token.
	mux.Handle("GET /sessions", requireAuth(cfg.Token, SessionsHandler(reg)))
	mux.Handle("GET /sessions/{id}/output", requireAuth(cfg.Token, SessionOutputHandler(reg)))
	mux.Handle("GET /ws", requireAuth(cfg.Token, WSHandler(reg)))
	mux.Handle("POST /hooks/claude", requireAuth(cfg.Token, HookHandler(eng)))

	// Comandos (Fase 3): lançar, aprovar/negar e enviar texto.
	if lch != nil {
		mux.Handle("POST /sessions", requireAuth(cfg.Token, LaunchHandler(lch)))
		mux.Handle("POST /sessions/{id}/approve", requireAuth(cfg.Token, ApproveHandler(lch)))
		mux.Handle("POST /sessions/{id}/deny", requireAuth(cfg.Token, DenyHandler(lch)))
		mux.Handle("POST /sessions/{id}/input", requireAuth(cfg.Token, InputHandler(lch)))
	}

	// Dev-only: seed de dados fake. Em prod o handler responde 404.
	mux.Handle("POST /dev/seed", requireAuth(cfg.Token, SeedHandler(cfg, reg)))

	return mux
}

// New monta o *http.Server do hub a partir da config, do registry e do launcher.
func New(cfg config.Config, reg *registry.Registry, lch Launcher) *http.Server {
	return &http.Server{
		Addr:              cfg.Addr(),
		Handler:           Router(cfg, reg, lch),
		ReadHeaderTimeout: 5 * time.Second,
	}
}
