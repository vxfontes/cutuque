package main

import (
	"log/slog"
	"os"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/launcher"
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

	// Launcher com os alvos conhecidos. Dev: só o macbook local (claude-code).
	// SSHTarget para máquinas remotas fica para a Fase 3/v1 (stub por ora).
	eng := engine.New(reg)
	targets := map[string]claudecode.Target{
		"macbook": claudecode.NewLocalTarget("macbook"),
	}
	lch := launcher.New(eng, reg, targets)

	srv := server.New(cfg, reg, lch)

	logger.Info("cutuque hub subindo", "env", cfg.Env, "addr", cfg.Addr())
	if err := srv.ListenAndServe(); err != nil {
		logger.Error("servidor parou", "err", err)
		os.Exit(1)
	}
}
