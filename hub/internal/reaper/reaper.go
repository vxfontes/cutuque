// Package reaper resolve sessões zumbi: as que entraram em `running` e nunca
// receberam o evento de saída (processo morto sem Stop, terminal fechado, claude
// novo no mesmo pane). Sem ele, uma sessão assim fica running PARA SEMPRE — o
// hub não tinha nenhum mecanismo que reavaliasse estado com o tempo.
//
// A postura é deliberadamente conservadora: na dúvida, NÃO age. "Não sei"
// (ssh caiu, máquina desconhecida, oráculo com erro) nunca é tratado como
// "morreu" — errar para o lado de deixar um zumbi a mais é muito melhor do que
// apagar da lista uma sessão que estava viva esperando a usuária.
package reaper

import (
	"log/slog"
	"sort"
	"sync"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

const (
	// defaultInterval: de quanto em quanto tempo o reaper varre o Registry.
	defaultInterval = 5 * time.Minute
	// defaultGrace: quanto tempo uma sessão precisa ficar ausente do oráculo,
	// de forma CONTÍNUA, antes de ser ceifada. Muito maior que a janela do
	// próprio oráculo (15min) porque o oráculo tem falso-negativo conhecido:
	// uma tool call longa e silenciosa não toca o transcript.
	defaultGrace = 30 * time.Minute
)

// Oracle é o que o reaper precisa saber sobre o mundo lá fora. *launcher.Launcher
// satisfaz esta interface; em teste ela é um fake, para a lógica de ceifa não
// depender de ssh nem de python3.
type Oracle interface {
	// HasHandle diz se o hub mantém um processo vivo desta sessão.
	HasHandle(id string) bool
	// Live lista as sessões daquele agente rodando agora na máquina.
	// Erro = "não sei".
	Live(machine, agent string) ([]session.Discovered, error)
	// TranscriptIDs lista os ids daquele agente com transcript no disco.
	// Erro = "não sei".
	TranscriptIDs(machine, agent string) ([]string, error)
}

// oracleKey é a granularidade da consulta: cada agente tem o SEU oráculo (o
// claude lê ~/.claude, o codex lê ~/.codex) e nenhum enxerga as sessões do
// outro. Agrupar só por máquina fazia o oráculo do claude-code responder por
// todo mundo — e "o claude não vê esta sessão codex" virava "esta sessão
// morreu", com Forget no fim.
type oracleKey struct{ machine, agent string }

// Reaper varre o Registry periodicamente. Mesma forma dos outros componentes de
// fundo do hub (Notifier): New / Start / Close, goroutine própria com WaitGroup.
type Reaper struct {
	eng    *engine.Engine
	reg    *registry.Registry
	oracle Oracle
	logger *slog.Logger

	interval time.Duration
	grace    time.Duration

	mu     sync.Mutex
	closed bool
	// misses guarda desde quando cada sessão está ausente do oráculo. Não é
	// persistido de propósito: depois de um restart é mais seguro recomeçar a
	// contagem do que confiar num bookkeeping que pode ter dessincronizado.
	misses map[string]time.Time

	stop chan struct{}
	wg   sync.WaitGroup
}

// New cria o reaper. logger nil vira o default.
func New(eng *engine.Engine, reg *registry.Registry, oracle Oracle, logger *slog.Logger) *Reaper {
	if logger == nil {
		logger = slog.Default()
	}
	return &Reaper{
		eng:      eng,
		reg:      reg,
		oracle:   oracle,
		logger:   logger,
		interval: defaultInterval,
		grace:    defaultGrace,
		misses:   make(map[string]time.Time),
		stop:     make(chan struct{}),
	}
}

// SetInterval e SetGrace ajustam a cadência. Chamar ANTES de Start (é assim que
// os testes encurtam os tempos, mesmo padrão do notifier).
func (rp *Reaper) SetInterval(d time.Duration) {
	if d > 0 {
		rp.interval = d
	}
}

func (rp *Reaper) SetGrace(d time.Duration) {
	if d >= 0 {
		rp.grace = d
	}
}

// Start sobe a goroutine de varredura. O primeiro tick roda na hora: os zumbis
// herdados do boot (o JSON persistido volta cheio deles) não precisam esperar um
// intervalo inteiro para sumir da lista.
func (rp *Reaper) Start() {
	rp.wg.Add(1)
	go func() {
		defer rp.wg.Done()
		rp.Tick()
		t := time.NewTicker(rp.interval)
		defer t.Stop()
		for {
			select {
			case <-rp.stop:
				return
			case <-t.C:
				rp.Tick()
			}
		}
	}()
}

// Close para a varredura e espera a goroutine terminar. Idempotente.
func (rp *Reaper) Close() {
	rp.mu.Lock()
	if rp.closed {
		rp.mu.Unlock()
		return
	}
	rp.closed = true
	close(rp.stop)
	rp.mu.Unlock()
	rp.wg.Wait()
}

// Tick faz UMA varredura, síncrona. É exportada para os testes exercitarem a
// lógica sem depender de tempo real (mesma separação loop/passo do seedDriver).
func (rp *Reaper) Tick() {
	var candidates []session.Session
	for _, s := range rp.reg.List() {
		// SÓ running é candidato. needs_you é proibido: é exatamente a sessão
		// que está esperando a usuária, e ceifá-la seria o pior erro possível.
		// idle é o destino, não a origem. done/error já têm veredito.
		if s.State != session.StateRunning {
			continue
		}
		// Se o hub segura o processo, está viva — não custa nada e é definitivo.
		if rp.oracle.HasHandle(s.ID) {
			continue
		}
		candidates = append(candidates, s)
	}
	if len(candidates) == 0 {
		rp.forgetMissesExcept(nil)
		return
	}

	collided := paneCollisions(candidates)
	live, disk := rp.consultOracle(candidates)

	now := time.Now()
	seen := make(map[string]bool, len(candidates))
	for _, s := range candidates {
		seen[s.ID] = true
		verdict, ok := live[oracleKey{s.Machine, s.Agent}]
		if ok && verdict[s.ID] {
			rp.clearMiss(s.ID)
			continue
		}
		// Colisão de pane é prova LOCAL: duas running no mesmo terminal da mesma
		// máquina é impossível de verdade, e isso se conclui só do Registry. Por
		// isso não espera graça E não depende do oráculo — fica ANTES do portão
		// abaixo, senão um ssh caído engavetaria a única evidência que não
		// precisa de rede. Continua atrás do teste de liveness acima: se o
		// oráculo garante que a sessão está viva, ela não é resíduo de ninguém.
		if collided[s.ID] {
			rp.resolve(s, disk)
			rp.clearMiss(s.ID)
			continue
		}
		if !ok {
			// Oráculo não respondeu por esta máquina: não sei nada, não conto
			// nem miss (senão um ssh instável acumularia graça sozinho).
			continue
		}
		if !rp.missedLongEnough(s.ID, now) {
			continue
		}
		rp.resolve(s, disk)
		rp.clearMiss(s.ID)
	}
	rp.forgetMissesExcept(seen)
}

// resolve decide o destino de um zumbi confirmado e escreve — sempre por
// compare-and-swap a partir de running, nunca confiando no snapshot do início
// do tick.
func (rp *Reaper) resolve(s session.Session, disk map[oracleKey]map[string]bool) {
	// Reconfere o handle: entre a triagem do Tick e aqui houve ida e volta de
	// ssh (segundos), e nesse intervalo um SendText/Reply pode ter feito o hub
	// relançar a sessão. O `resume` pega handle sem mexer no State, então o CAS
	// a partir de running passaria e mandaria para idle uma sessão que o próprio
	// hub está segurando pela mão. Consulta local, custo zero.
	if rp.oracle.HasHandle(s.ID) {
		return
	}
	ids, known := disk[oracleKey{s.Machine, s.Agent}]
	if !known {
		// Não consegui listar os transcripts desta máquina. Idle é seguro
		// (reversível, some da lista de ativas, nada é apagado); esquecer não
		// seria — nunca apago sem prova de que o transcript sumiu.
		if rp.eng.Idle(s.ID, session.StateRunning) {
			rp.logger.Info("reaper: sessão parada → idle (transcript indeterminado)",
				"session", s.ID, "machine", s.Machine, "title", s.Title)
		}
		return
	}
	if ids[s.ID] {
		if rp.eng.Idle(s.ID, session.StateRunning) {
			rp.logger.Info("reaper: sessão parada → idle",
				"session", s.ID, "machine", s.Machine, "title", s.Title)
		}
		return
	}
	// Sem transcript no disco: nem dá para retomar. Forget (não Remove): não
	// marca dismissed, então se um hook real trouxer esse id de volta um dia,
	// a sessão pode reaparecer.
	if rp.reg.Forget(s.ID, session.StateRunning) {
		rp.eng.RecordForgotten(s.ID)
		rp.logger.Info("reaper: sessão sem transcript → esquecida",
			"session", s.ID, "machine", s.Machine, "title", s.Title)
	}
}

// consultOracle pergunta a cada par (máquina, agente), em paralelo, quem está
// vivo e quais transcripts existem. Par cujo oráculo falhou simplesmente NÃO
// entra nos mapas — ausência aqui significa "não sei", nunca "não tem". Um
// agente sem oráculo (codex, opencode: nenhum implementa Liver hoje) cai nessa
// mesma vala: as sessões dele nunca são ceifadas, que é o certo enquanto não
// houver como medi-las.
func (rp *Reaper) consultOracle(candidates []session.Session) (live, disk map[oracleKey]map[string]bool) {
	keys := make(map[oracleKey]bool)
	for _, s := range candidates {
		keys[oracleKey{s.Machine, s.Agent}] = true
	}
	live = make(map[oracleKey]map[string]bool, len(keys))
	disk = make(map[oracleKey]map[string]bool, len(keys))

	var mu sync.Mutex
	var wg sync.WaitGroup
	for k := range keys {
		wg.Add(1)
		go func(k oracleKey) {
			defer wg.Done()
			liveIDs, errLive := rp.oracle.Live(k.machine, k.agent)
			diskIDs, errDisk := rp.oracle.TranscriptIDs(k.machine, k.agent)

			mu.Lock()
			defer mu.Unlock()
			if errLive != nil {
				rp.logger.Debug("reaper: oráculo de liveness indisponível",
					"machine", k.machine, "agent", k.agent, "err", errLive)
			} else {
				set := make(map[string]bool, len(liveIDs))
				for _, d := range liveIDs {
					set[d.ID] = true
				}
				live[k] = set
			}
			if errDisk != nil {
				rp.logger.Debug("reaper: lista de transcripts indisponível",
					"machine", k.machine, "agent", k.agent, "err", errDisk)
			} else {
				set := make(map[string]bool, len(diskIDs))
				for _, id := range diskIDs {
					set[id] = true
				}
				disk[k] = set
			}
		}(k)
	}
	wg.Wait()
	return live, disk
}

// paneCollisions acha sessões running que reivindicam o MESMO terminal da mesma
// máquina. O dono legítimo é o de atividade mais recente; os outros são resíduo
// de um claude anterior. Sinal puramente local — não custa I/O nenhum.
func paneCollisions(running []session.Session) map[string]bool {
	type key struct{ machine, pane string }
	byPane := make(map[key][]session.Session)
	for _, s := range running {
		if s.Pane == "" {
			continue // sessão de subagente/fora do tmux: pane não correlaciona nada
		}
		k := key{s.Machine, s.Pane}
		byPane[k] = append(byPane[k], s)
	}
	losers := make(map[string]bool)
	for _, group := range byPane {
		if len(group) < 2 {
			continue
		}
		sort.Slice(group, func(i, j int) bool {
			if !group[i].UpdatedAt.Equal(group[j].UpdatedAt) {
				return group[i].UpdatedAt.After(group[j].UpdatedAt)
			}
			return group[i].CreatedAt.After(group[j].CreatedAt)
		})
		for _, l := range group[1:] {
			losers[l.ID] = true
		}
	}
	return losers
}

// missedLongEnough marca a ausência e diz se ela já dura mais que a graça.
func (rp *Reaper) missedLongEnough(id string, now time.Time) bool {
	rp.mu.Lock()
	defer rp.mu.Unlock()
	first, seen := rp.misses[id]
	if !seen {
		rp.misses[id] = now
		return rp.grace == 0
	}
	return now.Sub(first) >= rp.grace
}

func (rp *Reaper) clearMiss(id string) {
	rp.mu.Lock()
	delete(rp.misses, id)
	rp.mu.Unlock()
}

// forgetMissesExcept descarta o bookkeeping de sessões que não são mais
// candidatas — senão o mapa cresceria para sempre, um id por sessão já resolvida.
func (rp *Reaper) forgetMissesExcept(keep map[string]bool) {
	rp.mu.Lock()
	defer rp.mu.Unlock()
	for id := range rp.misses {
		if !keep[id] {
			delete(rp.misses, id)
		}
	}
}
