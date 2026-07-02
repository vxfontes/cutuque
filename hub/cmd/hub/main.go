package main

import (
	"log/slog"
	"os"

	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/server"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
	cfg := config.Load()

	// Fail-fast: em prod o token é obrigatório. Sem ele, toda rota protegida
	// ficaria aberta (ver review/security.md#SEC-001).
	if cfg.Env == "prod" && cfg.Token == "" {
		logger.Error("CUTUQUE_TOKEN é obrigatório em prod; defina a variável de ambiente")
		os.Exit(1)
	}

	reg := registry.New()
	srv := server.New(cfg, reg)

	logger.Info("cutuque hub subindo", "env", cfg.Env, "addr", cfg.Addr())
	if err := srv.ListenAndServe(); err != nil {
		logger.Error("servidor parou", "err", err)
		os.Exit(1)
	}
}
