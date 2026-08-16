package launcher

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
)

// ReachState é o alcance de uma máquina na aba Máquinas: TRÊS estados
// possíveis, nunca um quarto (review do card cc906a1edd6d0c8e). Um host cuja
// chave ainda não é confiável, por exemplo, NÃO vira estado próprio — é só
// mais um jeito do ssh não responder, e cai em ReachNaoRespondeu como
// qualquer outra falha. "Ainda não sei" (ReachChecando) nunca pode aparecer
// como pronto: é o próprio motivo da aba existir — dar um sinal em que a
// usuária pode confiar.
type ReachState string

const (
	// ReachChecando: nenhuma sondagem terminou ainda para esta máquina desde
	// que o hub subiu (ou ela acabou de virar alvo). Estado inicial de toda
	// máquina — NUNCA renderizado como pronto.
	ReachChecando ReachState = "checando"
	// ReachPronto: a última sondagem (Probe) voltou sem erro — o ssh
	// respondeu de verdade, a máquina está pronta pra uso agora.
	ReachPronto ReachState = "pronto"
	// ReachNaoRespondeu: a última sondagem deu erro, qualquer que seja o
	// motivo (timeout, host-key não confiável, chave recusada, DNS...). A aba
	// só quer responder "dá pra usar AGORA?" — o motivo exato não vira estado.
	ReachNaoRespondeu ReachState = "nao_respondeu"
)

var (
	// reachTTL: por quanto tempo um resultado de sondagem é considerado
	// válido antes de merecer nova rodada. var (não const) para os testes
	// encolherem sem depender de sleep real — mesmo padrão de launchTimeout.
	reachTTL = 20 * time.Second

	// reachProbeTimeout é o teto de UMA sondagem individual. Fica um pouco
	// ACIMA do ConnectTimeout de consulta (3s — connectTimeoutConsulta): quem
	// decide "desistir" é o próprio ssh via -o ConnectTimeout, este contexto é
	// só uma rede de segurança para o caso (raro) do processo não voltar
	// sozinho a tempo. Nunca use isto para esperar MAIS que o ConnectTimeout.
	reachProbeTimeout = 5 * time.Second
)

// reachEntry é o último resultado de sondagem conhecido de uma máquina.
type reachEntry struct {
	state     ReachState
	checkedAt time.Time
}

// Reachability é o formato de fio de GET /machines/reachability: uma linha
// por máquina cadastrada como alvo hoje. CheckedAt é ponteiro (não
// time.Time) para SUMIR do JSON via omitempty quando nunca houve sondagem —
// time.Time zero não é omitido por encoding/json, só ponteiro nil é (mesma
// convenção do StartedAt do board).
type Reachability struct {
	Machine   string     `json:"machine"`
	State     ReachState `json:"state"`
	CheckedAt *time.Time `json:"checked_at,omitempty"`
}

// Reachability devolve o alcance conhecido de cada máquina cadastrada como
// alvo — SEMPRE do cache, nunca abre ssh na hora do request. É o ponto
// inteiro da feature: uma máquina morta custou 10s de ConnectTimeout a quem
// só queria LER a lista (medido em produção, 13/08/2026); aqui o pior caso de
// uma leitura é a velocidade de um map lookup.
//
// Quando algum resultado está velho (ou nunca existiu), dispara uma rodada de
// sondagem em background antes de devolver — esta chamada devolve o que já
// tinha (ou "checando"); a PRÓXIMA já vem atualizada.
func (l *Launcher) Reachability() []Reachability {
	names := l.machineNames()

	l.reachMu.Lock()
	out := make([]Reachability, 0, len(names))
	stale := false
	for _, name := range names {
		e, ok := l.reach[name]
		if !ok || time.Since(e.checkedAt) > reachTTL {
			stale = true
		}
		r := Reachability{Machine: name, State: ReachChecando}
		if ok {
			r.State = e.state
			checkedAt := e.checkedAt // não aponta pro campo do map: e é cópia local do loop
			r.CheckedAt = &checkedAt
		}
		out = append(out, r)
	}
	l.reachMu.Unlock()

	if stale {
		l.maybeStartReachRound(names)
	}
	return out
}

// machineNames devolve os nomes das máquinas cadastradas como alvo, em ordem
// estável. O mapa de targets não garante ordem nenhuma, e /machines/
// reachability precisa de saída determinística: o app faz polling disto, e
// uma lista que troca de ordem sozinha a cada resposta é ruído.
func (l *Launcher) machineNames() []string {
	snap := l.snapshot()
	names := make([]string, 0, len(snap))
	for name := range snap {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// maybeStartReachRound dispara uma rodada de sondagem em background SE não
// houver uma em voo — o guarda de rodada única: duas leituras simultâneas de
// Reachability() não podem virar duas rodadas de ssh nas mesmas máquinas.
//
// A goroutine usa o MESMO wg/baseCtx do resto do Launcher (padrão da casa,
// ver Launch/Shutdown): wg.Add ANTES de nascer, e se o hub estiver em
// Shutdown a rodada nem começa — senão o Shutdown vazaria esperando por uma
// sondagem que ninguém vai cancelar.
func (l *Launcher) maybeStartReachRound(names []string) {
	l.reachMu.Lock()
	if l.reachRunning {
		l.reachMu.Unlock()
		return
	}
	l.reachRunning = true
	l.reachMu.Unlock()

	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		l.reachMu.Lock()
		l.reachRunning = false
		l.reachMu.Unlock()
		return
	}
	l.wg.Add(1)
	l.mu.Unlock()

	go func() {
		defer l.wg.Done()
		defer func() {
			l.reachMu.Lock()
			l.reachRunning = false
			l.reachMu.Unlock()
		}()
		l.runReachRound(names)
	}()
}

// runReachRound sonda em PARALELO todas as máquinas dadas. É o motivo de
// existir desta rodada: serial faria N máquinas mortas custarem N ×
// reachProbeTimeout — paralelo, o pior caso da rodada inteira é UMA
// reachProbeTimeout, não N. Usa l.baseCtx: se o Shutdown cancelar no meio da
// rodada, os ssh em voo morrem junto (mesmo padrão do Launch).
func (l *Launcher) runReachRound(names []string) {
	var wg sync.WaitGroup
	for _, name := range names {
		tgt, ok := l.anyTarget(name)
		if !ok {
			continue
		}
		wg.Add(1)
		go func(name string, tgt claudecode.Target) {
			defer wg.Done()
			state := l.probeOne(tgt)
			now := time.Now()
			l.reachMu.Lock()
			l.reach[name] = reachEntry{state: state, checkedAt: now}
			l.reachMu.Unlock()
		}(name, tgt)
	}
	wg.Wait()
}

// probeOne sonda um único alvo com o teto de reachProbeTimeout. Alvo sem
// Prober (hoje só o LocalTarget de dev) é sempre "pronto": não há alcance de
// rede a confirmar — o próprio hub É a máquina, então não existe "ssh que não
// respondeu" nesse caso.
func (l *Launcher) probeOne(tgt claudecode.Target) ReachState {
	prober, ok := tgt.(claudecode.Prober)
	if !ok {
		return ReachPronto
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, reachProbeTimeout)
	defer cancel()
	if err := prober.Probe(ctx); err != nil {
		return ReachNaoRespondeu
	}
	return ReachPronto
}
