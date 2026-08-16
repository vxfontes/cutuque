package launcher

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/registry"
)

// probeTarget é um Target fake que também implementa claudecode.Prober, só
// para os testes de reachability. err decide o veredito quando não há delay
// nem bloqueio; delay simula uma sondagem lenta (prova de paralelismo); block,
// quando não-nil, prende Probe até o canal fechar (prova do guarda de rodada
// única) — os dois respeitam ctx.Done, como um ssh de verdade respeitaria o
// ConnectTimeout.
type probeTarget struct {
	name  string
	err   error
	delay time.Duration
	block <-chan struct{}
	calls int32 // atomic: quantas vezes Probe rodou de fato
}

func (p *probeTarget) Name() string { return p.name }
func (p *probeTarget) Kind() string { return "claude-code" }
func (p *probeTarget) NewRunner(app claudecode.Applier) *claudecode.Runner {
	return claudecode.NewRunner(app)
}
func (p *probeTarget) Start(context.Context, string, string, string, string, string, string) (*claudecode.Handle, error) {
	return nil, errors.New("probeTarget não lança sessão")
}

func (p *probeTarget) Probe(ctx context.Context) error {
	atomic.AddInt32(&p.calls, 1)
	if p.block != nil {
		select {
		case <-p.block:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if p.delay > 0 {
		select {
		case <-time.After(p.delay):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return p.err
}

// newReachTestLauncher monta um Launcher com um alvo fake por nome, cada um
// sob a chave "claude-code" (o que anyTarget prefere) — variante multi-
// máquina de newTestLauncher, que só monta uma.
func newReachTestLauncher(byName map[string]claudecode.Target) *Launcher {
	reg := registry.New()
	eng := engine.New(reg)
	targets := make(map[string]map[string]claudecode.Target, len(byName))
	for name, tgt := range byName {
		targets[name] = map[string]claudecode.Target{tgt.Kind(): tgt}
	}
	return New(eng, reg, targets)
}

// (a) Prova que a rodada sonda em PARALELO: N máquinas que demoram `delay`
// para responder custam ~1×delay na rodada inteira, não N×delay. É a razão
// de a rodada existir — a medição de produção (13/08/2026) mostrou uma
// máquina morta sozinha custando o ConnectTimeout inteiro (10s) a quem só
// queria ler a lista; serial multiplicaria isso por máquina morta.
func TestRunReachRoundSondaEmParaleloNaoSerial(t *testing.T) {
	const n = 5
	const delay = 150 * time.Millisecond

	byName := map[string]claudecode.Target{}
	names := make([]string, 0, n)
	for i := 0; i < n; i++ {
		name := fmt.Sprintf("morta-%d", i)
		names = append(names, name)
		byName[name] = &probeTarget{name: name, delay: delay, err: errors.New("dead")}
	}
	l := newReachTestLauncher(byName)

	start := time.Now()
	l.runReachRound(names)
	elapsed := time.Since(start)

	// Serial custaria n*delay (750ms). Paralelo fica perto de UMA delay.
	// Damos folga de 3x uma única sondagem — generoso o bastante pra não
	// piscar sob carga da máquina, mas bem abaixo do custo serial, que é a
	// única coisa que este teste precisa distinguir.
	if elapsed >= 3*delay {
		t.Fatalf("rodada de %d máquinas levou %v — parece SERIAL (custaria ~%v), não paralela", n, elapsed, n*delay)
	}
}

// (b) Prova que dentro do TTL o cache é reaproveitado: uma segunda leitura
// não dispara nova sondagem. Sem isso, o cache não economizaria nada — cada
// poll do app pagaria ssh de novo.
func TestReachabilityDentroDoTTLNaoRessonda(t *testing.T) {
	oldTTL := reachTTL
	reachTTL = time.Hour // bem acima da duração do teste: nunca expira aqui
	defer func() { reachTTL = oldTTL }()

	tgt := &probeTarget{name: "macbook"}
	l := newReachTestLauncher(map[string]claudecode.Target{"macbook": tgt})

	first := l.Reachability()
	if len(first) != 1 || first[0].State != ReachChecando {
		t.Fatalf("primeira leitura = %+v, esperava 1 máquina em checando (nunca sondada ainda)", first)
	}
	waitFor(t, func() bool { return atomic.LoadInt32(&tgt.calls) >= 1 })

	// Espera o bastante para qualquer rodada indevida ter chance de rodar, e
	// lê de novo: dentro do TTL não deve chamar Probe outra vez.
	time.Sleep(30 * time.Millisecond)
	second := l.Reachability()
	if len(second) != 1 || second[0].State != ReachPronto {
		t.Fatalf("segunda leitura = %+v, esperava 1 máquina pronta", second)
	}
	if got := atomic.LoadInt32(&tgt.calls); got != 1 {
		t.Fatalf("Probe rodou %d vezes dentro do TTL, esperava exatamente 1 — cache não evitou a re-sondagem", got)
	}
}

// (c) Prova o guarda de rodada única: com uma sondagem presa (bloqueada) em
// voo, leituras concorrentes de Reachability() NÃO disparam uma segunda
// rodada — Probe só roda mais uma vez depois que a primeira rodada termina.
// Sem isso, duas chamadas simultâneas dobrariam o tráfego de ssh por leitura.
func TestReachabilityGuardaContraRodadaDupla(t *testing.T) {
	oldTTL := reachTTL
	reachTTL = 0 // tudo sempre "velho": toda leitura TENTA disparar rodada nova
	defer func() { reachTTL = oldTTL }()

	release := make(chan struct{})
	tgt := &probeTarget{name: "macbook", block: release}
	l := newReachTestLauncher(map[string]claudecode.Target{"macbook": tgt})

	l.Reachability() // dispara a 1ª rodada, que fica presa esperando `release`
	waitFor(t, func() bool { return atomic.LoadInt32(&tgt.calls) >= 1 })

	// Duas leituras concorrentes enquanto a 1ª rodada ainda está em voo: o
	// guarda (reachRunning) deve recusar as duas.
	l.Reachability()
	l.Reachability()
	time.Sleep(30 * time.Millisecond) // dá chance de uma rodada indevida nascer, se o guarda falhar

	if got := atomic.LoadInt32(&tgt.calls); got != 1 {
		t.Fatalf("Probe já rodou %d vezes com a 1ª rodada ainda presa, esperava 1 — o guarda deveria ter recusado a rodada dupla", got)
	}

	close(release) // libera a 1ª rodada
	waitFor(t, func() bool {
		l.reachMu.Lock()
		defer l.reachMu.Unlock()
		return !l.reachRunning
	})
}

// (d) Prova os três estados e a regra que importa mais: "checando" (ainda não
// sondou) NUNCA sai como pronto. Uma máquina cujo Probe nunca rodou tem que
// aparecer como checando, sem CheckedAt; depois da rodada, sucesso vira
// pronto e erro vira nao_respondeu — e as duas ganham CheckedAt.
func TestReachabilityTresEstadosCorretos(t *testing.T) {
	oldTTL := reachTTL
	reachTTL = time.Hour
	defer func() { reachTTL = oldTTL }()

	ok := &probeTarget{name: "macbook"}                               // err nil → pronto
	dead := &probeTarget{name: "windows", err: errors.New("refused")} // erro → nao_respondeu
	l := newReachTestLauncher(map[string]claudecode.Target{
		"macbook": ok,
		"windows": dead,
	})

	// Antes de qualquer sondagem: as duas têm que vir "checando", nunca
	// "pronto" por default/zero-value do estado.
	before := l.Reachability()
	if len(before) != 2 {
		t.Fatalf("esperava 2 máquinas, veio %d: %+v", len(before), before)
	}
	for _, r := range before {
		if r.State != ReachChecando {
			t.Errorf("%s: state = %q antes de sondar, esperava %q — checando NUNCA pode sair como pronto", r.Machine, r.State, ReachChecando)
		}
		if r.CheckedAt != nil {
			t.Errorf("%s: checando veio com CheckedAt != nil", r.Machine)
		}
	}

	var after []Reachability
	waitFor(t, func() bool {
		after = l.Reachability()
		states := map[string]ReachState{}
		for _, r := range after {
			states[r.Machine] = r.State
		}
		return states["macbook"] == ReachPronto && states["windows"] == ReachNaoRespondeu
	})

	for _, r := range after {
		want := ReachPronto
		if r.Machine == "windows" {
			want = ReachNaoRespondeu
		}
		if r.State != want {
			t.Errorf("%s: state = %q, esperava %q", r.Machine, r.State, want)
		}
		if r.CheckedAt == nil {
			t.Errorf("%s: sondado mas sem CheckedAt", r.Machine)
		}
	}
}
