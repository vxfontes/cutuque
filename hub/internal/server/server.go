package server

import (
	"net/http"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/config"
)

// Router registra as rotas do hub.
func Router() *http.ServeMux {
	mux := http.NewServeMux()
	mux.Handle("GET /health", HealthHandler())
	return mux
}

// New monta o *http.Server do hub a partir da config.
func New(cfg config.Config) *http.Server {
	return &http.Server{
		Addr:              cfg.Addr(),
		Handler:           Router(),
		ReadHeaderTimeout: 5 * time.Second,
	}
}
