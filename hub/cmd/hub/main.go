package main

import (
	"log/slog"
	"os"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/apns"
	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/devices"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/launcher"
	"github.com/vxfontes/cutuque/hub/internal/notifier"
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

	// APNs (Fase 4): opcional. Se configurado, sobe o Notifier e habilita a rota
	// de registro de devices; senão, o hub segue normalmente sem push. O
	// encerramento do Notifier acompanha o processo (graceful shutdown segue
	// como dívida — ver review/log.md).
	var serverOpts []server.RouterOption
	if cfg.APNSEnabled() {
		client, err := apns.NewClient(cfg)
		if err != nil {
			logger.Error("apns configurado mas a chave não carregou; seguindo sem push", "err", err)
		} else {
			store := devices.New()
			ntf := notifier.New(client, store, reg, logger)
			ntf.SetRenudgeInterval(time.Duration(cfg.RenudgeSeconds) * time.Second)
			ntf.Start()
			serverOpts = append(serverOpts, server.WithDevices(store), server.WithRenudge(ntf))
			logger.Info("apns habilitado", "host", cfg.APNSHost, "topic", cfg.APNSTopic, "renudge_s", cfg.RenudgeSeconds)
		}
	} else {
		logger.Info("apns desabilitado (credenciais não configuradas); hub sobe sem push")
	}

	srv := server.New(cfg, reg, lch, serverOpts...)

	logger.Info("cutuque hub subindo", "env", cfg.Env, "addr", cfg.Addr())
	if err := srv.ListenAndServe(); err != nil {
		logger.Error("servidor parou", "err", err)
		os.Exit(1)
	}
}
