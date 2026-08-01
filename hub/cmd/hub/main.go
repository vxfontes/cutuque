package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
	_ "time/tzdata" // tz embutida: LoadLocation("America/Sao_Paulo") funciona no container alpine

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/adapter/codex"
	"github.com/vxfontes/cutuque/hub/internal/adapter/opencode"
	"github.com/vxfontes/cutuque/hub/internal/apns"
	"github.com/vxfontes/cutuque/hub/internal/board"
	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/devices"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/history"
	"github.com/vxfontes/cutuque/hub/internal/launcher"
	"github.com/vxfontes/cutuque/hub/internal/machine"
	"github.com/vxfontes/cutuque/hub/internal/notifier"
	"github.com/vxfontes/cutuque/hub/internal/reaper"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/server"
)

// shutdownTimeout é o teto para o desligamento gracioso: o quanto srv.Shutdown
// espera as requests em voo terminarem antes de desistir (Fase 5).
const shutdownTimeout = 10 * time.Second

// pgConnectBudget é por quanto tempo o boot insiste no Postgres antes de cair no
// JSON. Existe por causa da queda de energia de 2026-07-28: no reboot do macmini
// o hub sobe junto com o container do Postgres e pode chegar primeiro. Como a
// escolha do storage é feita UMA vez no boot (abaixo), um atraso de segundos do
// Postgres deixaria o hub em JSON até alguém reiniciar — e isso é silencioso:
// health 200, board respondendo, nada denunciando. Corrida de boot resolve em
// segundos; queda real de Postgres dura mais, então o fallback continua valendo
// pro caso em que ele faz sentido.
const pgConnectBudget = 90 * time.Second

// pgRetryFirstWait/pgRetryMaxWait: backoff entre tentativas de connect. São var,
// e não const, só para o teste poder encolhê-los — em produção ninguém escreve.
var (
	pgRetryFirstWait = 1 * time.Second
	pgRetryMaxWait   = 10 * time.Second
)

// openPostgresWithRetry chama open até dar certo ou o prazo estourar, com backoff
// dobrando de pgRetryFirstWait até pgRetryMaxWait. Retentar é seguro: os dois
// opens (board e histórico) aplicam schema idempotente (CREATE ... IF NOT EXISTS).
//
// O prazo é conferido DEPOIS da primeira tentativa, de propósito: com deadline no
// passado (dev) ainda se tenta uma vez, preservando o comportamento antigo de boot
// rápido mesmo com CUTUQUE_DATABASE_URL apontando pra lugar nenhum.
func openPostgresWithRetry[T any](
	ctx context.Context,
	logger *slog.Logger,
	what string,
	deadline time.Time,
	open func(context.Context) (T, error),
) (T, error) {
	var zero T
	wait := pgRetryFirstWait
	for attempt := 1; ; attempt++ {
		v, err := open(ctx)
		if err == nil {
			if attempt > 1 {
				logger.Info("postgres respondeu depois de esperar", "para", what, "tentativas", attempt)
			}
			return v, nil
		}
		if !time.Now().Before(deadline) {
			return zero, err
		}
		if attempt == 1 {
			logger.Info("postgres ainda não respondeu; insistindo até o prazo",
				"para", what, "err", err, "prazo_s", int(time.Until(deadline).Seconds()))
		}
		select {
		case <-ctx.Done():
			return zero, ctx.Err()
		case <-time.After(wait):
		}
		if wait *= 2; wait > pgRetryMaxWait {
			wait = pgRetryMaxWait
		}
	}
}

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
	cfg := config.Load()

	// Fail-fast: em prod o token é obrigatório. Sem ele, toda rota protegida
	// ficaria aberta (ver review/security.md#SEC-001).
	if cfg.Env == "prod" && cfg.Token == "" {
		logger.Error("CUTUQUE_TOKEN é obrigatório em prod; defina a variável de ambiente")
		os.Exit(1)
	}

	// CUTUQUE_SESSIONS_PATH persiste a metadata das sessões em disco (volume
	// docker) para sobreviverem a restart/deploy — senão sessões concluídas
	// reaparecem como "rodando" e a lista some. Sem a env var, só memória (dev).
	reg := registry.New()
	// board.json vive no MESMO diretório da persistência de sessões: não há
	// env var própria para o board, apenas reaproveita o volume já montado
	// para CUTUQUE_SESSIONS_PATH. Sem a env var, o board segue só em memória
	// (dev), igual ao registry.
	var boardStore board.Store = board.New()
	boardPath := ""
	if p := os.Getenv("CUTUQUE_SESSIONS_PATH"); p != "" {
		reg = registry.NewAt(p)
		logger.Info("sessões persistidas em disco", "path", p, "carregadas", len(reg.List()))
		boardPath = filepath.Join(filepath.Dir(p), "board.json")
	}

	// Board: Postgres é a fonte da verdade (durável/consultável) quando há
	// CUTUQUE_DATABASE_URL; senão cai no JSON/memória (dev). No 1º boot com DB
	// vazio, importa o board.json existente (o arquivo fica de backup).
	dbURL := os.Getenv("CUTUQUE_DATABASE_URL")
	// Prazo COMPARTILHADO pelos dois connects (board e histórico): é o mesmo
	// Postgres, então quem chega depois aproveita o que sobrou e o boot nunca
	// gasta 2× o orçamento. Só em prod — em dev o prazo já nasce vencido, isto é,
	// uma tentativa só.
	pgDeadline := time.Now()
	if dbURL != "" && cfg.Env == "prod" {
		pgDeadline = pgDeadline.Add(pgConnectBudget)
	}
	if dbURL != "" {
		if pg, err := openPostgresWithRetry(context.Background(), logger, "board", pgDeadline,
			func(ctx context.Context) (*board.PostgresStore, error) {
				return board.OpenPostgres(ctx, dbURL)
			},
		); err != nil {
			logger.Warn("board Postgres indisponível; caindo no JSON", "err", err)
			if boardPath != "" {
				boardStore = board.NewAt(boardPath)
			}
		} else {
			if n, cerr := pg.Count(); cerr == nil && n == 0 && boardPath != "" {
				if imp, ierr := pg.ImportFromJSON(boardPath); ierr != nil {
					logger.Warn("board: import do board.json falhou", "err", ierr)
				} else if imp > 0 {
					logger.Info("board: board.json importado pro Postgres", "cards", imp)
				}
			}
			boardStore = pg
			logger.Info("board no Postgres (schema cutuque)", "tarefas", len(boardStore.List()))
		}
	} else if boardPath != "" {
		boardStore = board.NewAt(boardPath)
		logger.Info("board persistido em disco (JSON)", "path", boardPath, "tarefas", len(boardStore.List()))
	}

	// Fechamento semanal automático (domingo 23:59 America/Sao_Paulo): arquiva os
	// concluídos e marca encalhadas. Manual: POST /board/close.
	if loc, err := time.LoadLocation("America/Sao_Paulo"); err == nil {
		board.StartWeeklyCloser(boardStore, loc)
		logger.Info("fechamento semanal do board agendado", "tz", "America/Sao_Paulo")
	}

	// CUTUQUE_DATABASE_URL liga o histórico no Postgres (schema `cutuque`):
	// write-through assíncrono de cada transição/evento, para consultar sessões
	// passadas e sua linha do tempo (v2.2/v2.3). O registry segue persistindo o
	// estado VIVO em JSON (fast-path/restart) — o Postgres é a camada durável de
	// histórico. Sem a env var (ou se o connect falhar), degrada gracioso: só JSON.
	var eng *engine.Engine
	var hist *history.PostgresStore
	if dbURL != "" {
		st, err := openPostgresWithRetry(context.Background(), logger, "histórico", pgDeadline,
			func(ctx context.Context) (*history.PostgresStore, error) {
				return history.Open(ctx, dbURL)
			},
		)
		if err != nil {
			logger.Warn("histórico Postgres indisponível; seguindo só com JSON", "err", err)
			eng = engine.New(reg)
		} else {
			hist = st
			eng = engine.NewWithHistory(reg, st)
			logger.Info("histórico habilitado no Postgres (schema cutuque)")
		}
	} else {
		eng = engine.New(reg)
	}

	// Launcher com os alvos conhecidos. Sem CUTUQUE_SSH_TARGETS, cai no
	// LocalTarget "macbook" (dev, hub e claude na mesma máquina). Com a env
	// var, cada entrada vira um SSHTarget (hub no servidor, claude na máquina
	// remota via ssh) — Fase 5.
	machines, machineWarns := machine.ParseSSHTargets(os.Getenv("CUTUQUE_SSH_TARGETS"))
	for _, w := range machineWarns {
		logger.Warn("CUTUQUE_SSH_TARGETS", "aviso", w)
	}
	targets := buildTargets(machines)
	lch := launcher.New(eng, reg, targets)
	lch.SetMaxSessions(cfg.MaxSessions) // SEC-007: teto de sessões concorrentes

	// Reaper: resolve sessões que entraram em running e nunca receberam o evento
	// de saída (processo morto sem Stop, terminal fechado, claude novo no mesmo
	// pane). Roda sempre — limpar zumbi é higiene do Registry, não depende de
	// push nem de Postgres. Usa o `eng` daqui, não um Engine próprio: as
	// transições dele são transições de verdade e precisam ir para o histórico.
	rp := reaper.New(eng, reg, lch, logger)
	rp.Start()

	// APNs (Fase 4): opcional. Se configurado, sobe o Notifier e habilita a rota
	// de registro de devices; senão, o hub segue normalmente sem push.
	var ntf *notifier.Notifier
	mreg := buildMachineRegistry(machines, logger)
	serverOpts := []server.RouterOption{
		server.WithBoard(boardStore),
		server.WithMachines(mreg),
	}
	// CUTUQUE_MACHINES_DIR liga o CADASTRO de máquinas pelo app (aba Máquinas):
	// é onde ficam o registro, as chaves privadas geradas aqui e o known_hosts
	// próprio. Sem a env var o hub só LISTA o que veio do CUTUQUE_SSH_TARGETS —
	// gerar chave privada em disco efêmero seria perdê-la no próximo deploy.
	if dir := os.Getenv("CUTUQUE_MACHINES_DIR"); dir != "" {
		ks := machine.NewKeyStore(dir)
		// Antes de restaurar qualquer alvo: é este known_hosts que os alvos das
		// máquinas do app consultam, e o StrictHostKeyChecking=yes delas não
		// perdoa apontá-lo para o lugar errado.
		lch.SetMachineKnownHosts(ks.KnownHostsPath())
		restaurados := restauraAlvosDoApp(lch, mreg)
		serverOpts = append(serverOpts, server.WithMachineKeys(ks), server.WithMachineTargets(lch))
		logger.Info("cadastro de máquinas pelo app habilitado", "dir", dir, "alvos_restaurados", restaurados)
	}
	if cfg.APNSEnabled() {
		client, err := apns.NewClient(cfg)
		if err != nil {
			logger.Error("apns configurado mas a chave não carregou; seguindo sem push", "err", err)
		} else {
			// CUTUQUE_DEVICES_PATH persiste os device tokens em disco (volume
			// docker) para sobreviverem a restart/deploy — senão um push
			// disparado antes do app reabrir e re-registrar se perde. Sem a env
			// var, segue só em memória (dev).
			store := devices.New()
			if p := os.Getenv("CUTUQUE_DEVICES_PATH"); p != "" {
				store = devices.NewAt(p)
				logger.Info("devices persistidos em disco", "path", p, "carregados", len(store.List()))
			}
			ntf = notifier.New(client, store, reg, logger)
			ntf.SetRenudgeInterval(time.Duration(cfg.RenudgeSeconds) * time.Second)
			ntf.Start()
			serverOpts = append(serverOpts, server.WithDevices(store), server.WithRenudge(ntf), server.WithForeground(ntf))
			logger.Info("apns habilitado", "host", cfg.APNSHost, "topic", cfg.APNSTopic, "renudge_s", cfg.RenudgeSeconds)
		}
	} else {
		logger.Info("apns desabilitado (credenciais não configuradas); hub sobe sem push")
	}

	// Rotas de histórico (v2.4) só quando o Postgres está ligado.
	if hist != nil {
		serverOpts = append(serverOpts, server.WithHistory(hist))
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
	// O reaper para ANTES do launcher (usa os targets dele como oráculo) e antes
	// do eng.Close() (as transições que ele acabou de gravar ainda precisam ser
	// drenadas para o histórico).
	rp.Close()
	lch.Shutdown()
	// Drena a fila de histórico (write-through assíncrono) e fecha a pool antes
	// de sair, para não perder os últimos eventos nem vazar conexões.
	eng.Close()
	if hist != nil {
		hist.Close()
	}

	if err := <-serveErr; err != nil {
		logger.Error("servidor parou com erro durante o shutdown", "err", err)
	}
	logger.Info("cutuque hub encerrado")
}

// buildTargets monta o mapa de alvos do Launcher a partir das máquinas já
// parseadas do CUTUQUE_SSH_TARGETS. Lista vazia: cai no LocalTarget "macbook"
// (mesmo comportamento de antes da Fase 5). Não-vazia: cada entrada vira um
// SSHTarget — nenhum LocalTarget implícito é adicionado, então quem quiser o
// macbook local precisa listá-lo explicitamente (ele deixa de ser "grátis").
func buildTargets(machines []machine.Machine) map[string]map[string]claudecode.Target {
	// Cada máquina roda os dois agentes (claude-code + codex). O mapa é
	// máquina → agente (t.Kind()) → alvo; o Launcher escolhe pelo agente pedido.
	if len(machines) == 0 {
		return map[string]map[string]claudecode.Target{
			"macbook": agentMap(
				claudecode.NewLocalTarget("macbook"),
				codex.NewLocalTarget("macbook"),
				opencode.NewLocalTarget("macbook"),
			),
		}
	}
	targets := make(map[string]map[string]claudecode.Target, len(machines))
	for _, m := range machines {
		// O mesmo construtor do cadastro em runtime (launcher.TargetsFor): sem
		// known_hosts próprio, porque máquina do hub.env conecta pelo ~/.ssh do
		// container. Um só lugar monta alvo ssh — dois divergiriam.
		targets[m.Name] = launcher.TargetsFor(m, "")
	}
	return targets
}

// restauraAlvosDoApp devolve ao Launcher os alvos das máquinas que o app já
// cadastrou e cuja impressão digital já foi confirmada. Sem isto, um restart do
// hub deixaria a máquina na lista mas inutilizável até a usuária confirmar a
// impressão de novo — e ela não teria como saber que precisava.
//
// Máquina sem fingerprint fica de fora de propósito: é o mesmo critério do
// runtime (o hub se recusa a conectar sem confirmação).
func restauraAlvosDoApp(lch *launcher.Launcher, reg *machine.Registry) int {
	n := 0
	for _, m := range reg.List() {
		if m.Source != machine.SourceApp || m.HostFingerprint == "" {
			continue
		}
		lch.RegisterMachine(m)
		n++
	}
	return n
}

// buildMachineRegistry monta o registro da aba Máquinas: sempre com o que veio
// do CUTUQUE_SSH_TARGETS e, quando CUTUQUE_MACHINES_DIR está configurado,
// também com os cadastros do app persistidos em disco.
func buildMachineRegistry(ms []machine.Machine, logger *slog.Logger) *machine.Registry {
	base := machinesForRegistry(ms)
	dir := os.Getenv("CUTUQUE_MACHINES_DIR")
	if dir == "" {
		return machine.NewRegistry(base)
	}
	path := filepath.Join(dir, "machines.json")
	reg := machine.NewRegistryAt(path, base)
	logger.Info("registro de máquinas persistido", "path", path, "total", len(reg.List()))
	return reg
}

// machinesForRegistry devolve as máquinas que o app deve enxergar na aba
// Máquinas, espelhando o fallback do buildTargets: sem CUTUQUE_SSH_TARGETS o
// hub roda com o LocalTarget "macbook" implícito, e /machines precisa mostrar
// o mesmo que /targets — senão o app lista vazio num hub que tem alvo.
func machinesForRegistry(ms []machine.Machine) []machine.Machine {
	if len(ms) > 0 {
		return ms
	}
	return []machine.Machine{{Name: "macbook", Dest: "local", Source: machine.SourceLocal}}
}

// agentMap indexa alvos pelo agente que cada um representa (t.Kind()).
func agentMap(ts ...claudecode.Target) map[string]claudecode.Target {
	m := make(map[string]claudecode.Target, len(ts))
	for _, t := range ts {
		m[t.Kind()] = t
	}
	return m
}

// O parse do CUTUQUE_SSH_TARGETS (e a defesa contra destino que parece opção do
// ssh) mora em internal/machine — a aba Máquinas precisa das máquinas como
// recurso, não só dos alvos do Launcher.
