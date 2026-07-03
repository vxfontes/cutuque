package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
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

// shutdownTimeout é o teto para o desligamento gracioso: o quanto srv.Shutdown
// espera as requests em voo terminarem antes de desistir (Fase 5).
const shutdownTimeout = 10 * time.Second

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

	// Launcher com os alvos conhecidos. Sem CUTUQUE_SSH_TARGETS, cai no
	// LocalTarget "macbook" (dev, hub e claude na mesma máquina). Com a env
	// var, cada entrada vira um SSHTarget (hub no servidor, claude na máquina
	// remota via ssh) — Fase 5.
	eng := engine.New(reg)
	targets := buildTargets(os.Getenv("CUTUQUE_SSH_TARGETS"), logger)
	lch := launcher.New(eng, reg, targets)
	lch.SetMaxSessions(cfg.MaxSessions) // SEC-007: teto de sessões concorrentes

	// APNs (Fase 4): opcional. Se configurado, sobe o Notifier e habilita a rota
	// de registro de devices; senão, o hub segue normalmente sem push.
	var ntf *notifier.Notifier
	var serverOpts []server.RouterOption
	if cfg.APNSEnabled() {
		client, err := apns.NewClient(cfg)
		if err != nil {
			logger.Error("apns configurado mas a chave não carregou; seguindo sem push", "err", err)
		} else {
			store := devices.New()
			ntf = notifier.New(client, store, reg, logger)
			ntf.SetRenudgeInterval(time.Duration(cfg.RenudgeSeconds) * time.Second)
			ntf.Start()
			serverOpts = append(serverOpts, server.WithDevices(store), server.WithRenudge(ntf), server.WithForeground(ntf))
			logger.Info("apns habilitado", "host", cfg.APNSHost, "topic", cfg.APNSTopic, "renudge_s", cfg.RenudgeSeconds)
		}
	} else {
		logger.Info("apns desabilitado (credenciais não configuradas); hub sobe sem push")
	}

	srv := server.New(cfg, reg, lch, serverOpts...)

	// Graceful shutdown (Fase 5): SIGINT/SIGTERM disparam, em ordem, (1)
	// srv.Shutdown — para de aceitar conexões novas e espera as em voo (até
	// shutdownTimeout); só DEPOIS disso é seguro chamar (2) notifier.Close e
	// (3) launcher.Shutdown, porque um Launch em andamento dentro de um
	// handler HTTP já terá retornado quando srv.Shutdown desbloquear —
	// Launcher.Shutdown só enxerga sessões cujo Handle já foi registrado.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	serveErr := make(chan error, 1)
	go func() {
		logger.Info("cutuque hub subindo", "env", cfg.Env, "addr", cfg.Addr())
		err := srv.ListenAndServe()
		if errors.Is(err, http.ErrServerClosed) {
			err = nil // esperado: srv.Shutdown foi chamado de propósito
		}
		serveErr <- err
	}()

	select {
	case <-ctx.Done():
		logger.Info("sinal de encerramento recebido; desligando graciosamente")
	case err := <-serveErr:
		if err != nil {
			logger.Error("servidor parou inesperadamente", "err", err)
			os.Exit(1)
		}
		return
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("erro ao desligar o servidor http", "err", err)
	}
	if ntf != nil {
		ntf.Close()
	}
	lch.Shutdown()

	if err := <-serveErr; err != nil {
		logger.Error("servidor parou com erro durante o shutdown", "err", err)
	}
	logger.Info("cutuque hub encerrado")
}

// buildTargets monta o mapa de alvos do Launcher a partir de
// CUTUQUE_SSH_TARGETS ("nome=destino,nome2=destino2", onde destino é um alias
// do ~/.ssh/config ou user@host). Vazia: cai no LocalTarget "macbook" (mesmo
// comportamento de antes da Fase 5). Não-vazia: cada entrada vira um
// SSHTarget — nenhum LocalTarget implícito é adicionado, então quem quiser o
// macbook local precisa listá-lo explicitamente (ele deixa de ser "grátis").
func buildTargets(rawSSHTargets string, logger *slog.Logger) map[string]claudecode.Target {
	dests := parseSSHTargets(rawSSHTargets, logger)
	if len(dests) == 0 {
		return map[string]claudecode.Target{
			"macbook": claudecode.NewLocalTarget("macbook"),
		}
	}
	targets := make(map[string]claudecode.Target, len(dests))
	for name, d := range dests {
		t := claudecode.NewSSHTarget(name, d.dest)
		// Caminho absoluto do claude remoto por alvo (opcional): necessário
		// quando o binário certo não é o primeiro no PATH do login shell remoto
		// (ex.: no Mac, /opt/homebrew tem uma versão antiga; a boa está em
		// ~/.local/bin). Vazio → default "claude".
		t.SetRemoteClaudeCmd(d.remoteCmd)
		targets[name] = t
	}
	return targets
}

// sshDest é um alvo SSH parseado: destino ssh + comando/caminho do claude remoto.
type sshDest struct {
	dest      string
	remoteCmd string // vazio = default "claude"
}

// parseSSHTargets interpreta CUTUQUE_SSH_TARGETS num mapa nome->destino ssh.
// Parse defensivo: entradas malformadas (sem "=", nome ou destino vazio) são
// ignoradas com log de aviso — uma entrada ruim não deve impedir as demais nem
// derrubar o boot do hub.
// Formato de cada entrada: "nome=destino" ou "nome=destino=comando-claude".
// destino = alias do ~/.ssh/config ou user@host. O 3º campo (opcional) é o
// caminho/comando do claude remoto.
func parseSSHTargets(raw string, logger *slog.Logger) map[string]sshDest {
	out := make(map[string]sshDest)
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return out
	}
	for _, entry := range strings.Split(raw, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		parts := strings.SplitN(entry, "=", 3)
		name := strings.TrimSpace(parts[0])
		dest := ""
		remoteCmd := ""
		if len(parts) >= 2 {
			dest = strings.TrimSpace(parts[1])
		}
		if len(parts) == 3 {
			remoteCmd = strings.TrimSpace(parts[2])
		}
		if name == "" || dest == "" {
			logger.Warn("CUTUQUE_SSH_TARGETS: entrada malformada ignorada", "entry", entry)
			continue
		}
		// Defesa: um dest começando com "-" poderia ser reinterpretado pelo ssh
		// como opção (ex.: -oProxyCommand=...). Rejeita (review F5, injeção-ssh).
		if strings.HasPrefix(dest, "-") {
			logger.Warn("CUTUQUE_SSH_TARGETS: destino começa com '-', ignorado", "entry", entry)
			continue
		}
		out[name] = sshDest{dest: dest, remoteCmd: remoteCmd}
	}
	return out
}
