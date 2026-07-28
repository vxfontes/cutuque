package reaper

import (
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// fakeOracle responde o que o teste mandar. errLive/errDisk simulam ssh caído —
// o caso que mais importa, porque é onde o reaper tem que NÃO agir.
type fakeOracle struct {
	handles map[string]bool
	live    []session.Discovered
	disk    []string
	errLive error
	errDisk error
	// onLive roda DENTRO da consulta ao oráculo, que é onde o tick passa
	// segundos esperando ssh. É o gancho para simular o que muda no hub nesse
	// intervalo — o único jeito de exercitar a corrida sem dormir no teste.
	onLive func()
}

func (f *fakeOracle) HasHandle(id string) bool { return f.handles[id] }

func (f *fakeOracle) Live(machine, agent string) ([]session.Discovered, error) {
	if f.onLive != nil {
		f.onLive()
	}
	if f.errLive != nil {
		return nil, f.errLive
	}
	return f.live, nil
}

func (f *fakeOracle) TranscriptIDs(machine, agent string) ([]string, error) {
	if f.errDisk != nil {
		return nil, f.errDisk
	}
	return f.disk, nil
}

// fixture monta registry + engine + reaper com graça zero (ceifa no 1º tick).
func fixture(t *testing.T, o *fakeOracle) (*registry.Registry, *Reaper) {
	t.Helper()
	reg := registry.New()
	rp := New(engine.New(reg), reg, o, nil)
	rp.SetGrace(0)
	return reg, rp
}

func addRunning(t *testing.T, reg *registry.Registry, id, pane string, age time.Duration) {
	t.Helper()
	addRunningAgent(t, reg, id, pane, "claude-code", age)
}

func addRunningAgent(t *testing.T, reg *registry.Registry, id, pane, agent string, age time.Duration) {
	t.Helper()
	now := time.Now().Add(-age)
	reg.Add(session.Session{
		ID: id, Machine: "macbook", Agent: agent, Title: id,
		State: session.StateRunning, Pane: pane, CreatedAt: now, UpdatedAt: now,
	})
}

// fakeAgentOracle responde por AGENTE e registra o que foi perguntado. Só o
// teste de roteamento precisa disso; os demais usam o fakeOracle simples.
type fakeAgentOracle struct {
	mu    sync.Mutex
	asked map[oracleKey]bool
	live  map[string][]session.Discovered
	disk  map[string][]string
	// errs marca agente SEM oráculo — hoje é o caso real de codex e opencode,
	// que não implementam Liver nem TranscriptLister.
	errs map[string]error
}

func (f *fakeAgentOracle) HasHandle(string) bool { return false }

func (f *fakeAgentOracle) record(machine, agent string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.asked == nil {
		f.asked = map[oracleKey]bool{}
	}
	f.asked[oracleKey{machine, agent}] = true
}

func (f *fakeAgentOracle) Live(machine, agent string) ([]session.Discovered, error) {
	f.record(machine, agent)
	if err := f.errs[agent]; err != nil {
		return nil, err
	}
	return f.live[agent], nil
}

func (f *fakeAgentOracle) TranscriptIDs(machine, agent string) ([]string, error) {
	if err := f.errs[agent]; err != nil {
		return nil, err
	}
	return f.disk[agent], nil
}

func stateOf(t *testing.T, reg *registry.Registry, id string) (session.State, bool) {
	t.Helper()
	s, ok := reg.Get(id)
	return s.State, ok
}

// TestTickIdlesStoppedSessionWithTranscript: o caso comum. A sessão sumiu do
// oráculo mas o .jsonl continua lá → idle (retomável), não apagada.
func TestTickIdlesStoppedSessionWithTranscript(t *testing.T) {
	reg, rp := fixture(t, &fakeOracle{disk: []string{"zumbi"}})
	addRunning(t, reg, "zumbi", "%0", time.Hour)

	rp.Tick()

	if st, ok := stateOf(t, reg, "zumbi"); !ok || st != session.StateIdle {
		t.Fatalf("estado = %q (existe=%v), quero idle", st, ok)
	}
}

// TestTickForgetsSessionWithoutTranscript: sem .jsonl não dá nem para retomar —
// some do Registry. E NÃO pode marcar dismissed, senão o id ficaria banido.
func TestTickForgetsSessionWithoutTranscript(t *testing.T) {
	reg, rp := fixture(t, &fakeOracle{disk: []string{"outra"}})
	addRunning(t, reg, "fantasma", "%0", time.Hour)

	rp.Tick()

	if _, ok := reg.Get("fantasma"); ok {
		t.Fatalf("sessão sem transcript deveria ter sido esquecida")
	}
	if reg.Dismissed("fantasma") {
		t.Fatalf("Forget não pode marcar dismissed: baniria o id de voltar por hook")
	}
}

// TestTickKeepsLiveSession: a sessão está no oráculo → nada acontece.
func TestTickKeepsLiveSession(t *testing.T) {
	reg, rp := fixture(t, &fakeOracle{
		live: []session.Discovered{{ID: "viva"}},
		disk: []string{"viva"},
	})
	addRunning(t, reg, "viva", "%0", time.Hour)

	rp.Tick()

	if st, _ := stateOf(t, reg, "viva"); st != session.StateRunning {
		t.Fatalf("estado = %q, quero running (a sessão está viva no oráculo)", st)
	}
}

// TestTickNeverTouchesSessionWithLiveHandle: se o hub segura o processo, a
// sessão está viva por definição — nem consulta oráculo, nem ceifa.
func TestTickNeverTouchesSessionWithLiveHandle(t *testing.T) {
	reg, rp := fixture(t, &fakeOracle{handles: map[string]bool{"minha": true}})
	addRunning(t, reg, "minha", "%0", time.Hour)

	rp.Tick()

	if st, ok := stateOf(t, reg, "minha"); !ok || st != session.StateRunning {
		t.Fatalf("estado = %q (existe=%v), quero running: o hub segura o handle", st, ok)
	}
}

// TestTickDoesNothingWhenOracleFails é a garantia mais importante do desenho:
// ssh caído significa "não sei", nunca "morreu". Se este teste quebrar, o hub
// passa a apagar sessões vivas toda vez que a rede oscilar.
func TestTickDoesNothingWhenOracleFails(t *testing.T) {
	reg, rp := fixture(t, &fakeOracle{errLive: errors.New("ssh: connection refused")})
	addRunning(t, reg, "incerta", "%0", time.Hour)

	rp.Tick()

	if st, ok := stateOf(t, reg, "incerta"); !ok || st != session.StateRunning {
		t.Fatalf("estado = %q (existe=%v), quero running intocada", st, ok)
	}
}

// TestTickIdlesWhenTranscriptListUnavailable: liveness respondeu (morreu), mas a
// lista de transcripts falhou. Idle é reversível; esquecer não seria.
func TestTickIdlesWhenTranscriptListUnavailable(t *testing.T) {
	reg, rp := fixture(t, &fakeOracle{errDisk: errors.New("ssh: timeout")})
	addRunning(t, reg, "meio-termo", "%0", time.Hour)

	rp.Tick()

	if st, ok := stateOf(t, reg, "meio-termo"); !ok || st != session.StateIdle {
		t.Fatalf("estado = %q (existe=%v), quero idle sem apagar", st, ok)
	}
}

// TestTickNeverReapsNeedsYou: ceifar a sessão que está esperando resposta seria
// o pior erro possível — ela sequer entra na varredura.
func TestTickNeverReapsNeedsYou(t *testing.T) {
	reg, rp := fixture(t, &fakeOracle{})
	addRunning(t, reg, "perguntando", "%0", time.Hour)
	reg.UpdateState("perguntando", session.StateNeedsYou)

	rp.Tick()

	if st, ok := stateOf(t, reg, "perguntando"); !ok || st != session.StateNeedsYou {
		t.Fatalf("estado = %q (existe=%v), quero needs_you intocado", st, ok)
	}
}

// TestTickRespectsGrace: uma ausência só conta depois de durar a graça inteira.
// Cobre o falso-negativo conhecido do oráculo (tool call longa e silenciosa).
func TestTickRespectsGrace(t *testing.T) {
	reg, rp := fixture(t, &fakeOracle{disk: []string{"pensando"}})
	rp.SetGrace(time.Hour)
	addRunning(t, reg, "pensando", "%0", time.Hour)

	rp.Tick() // primeira ausência: só marca, não age
	if st, _ := stateOf(t, reg, "pensando"); st != session.StateRunning {
		t.Fatalf("estado = %q, quero running: a graça de 1h não venceu", st)
	}

	// Empurra a primeira ausência para trás no tempo e varre de novo.
	rp.mu.Lock()
	rp.misses["pensando"] = time.Now().Add(-2 * time.Hour)
	rp.mu.Unlock()

	rp.Tick()
	if st, _ := stateOf(t, reg, "pensando"); st != session.StateIdle {
		t.Fatalf("estado = %q, quero idle depois da graça vencida", st)
	}
}

// TestPaneCollisionActsWithoutGrace: duas running no mesmo terminal é impossível
// de verdade — o perdedor é resíduo e não precisa esperar graça nenhuma.
func TestPaneCollisionActsWithoutGrace(t *testing.T) {
	reg, rp := fixture(t, &fakeOracle{disk: []string{"antiga", "nova"}})
	rp.SetGrace(time.Hour) // graça longa: só a colisão pode agir aqui
	addRunning(t, reg, "antiga", "sock\t%0", 3*time.Hour)
	addRunning(t, reg, "nova", "sock\t%0", time.Minute)

	rp.Tick()

	if st, _ := stateOf(t, reg, "antiga"); st != session.StateIdle {
		t.Errorf("antiga = %q, quero idle (perdeu o terminal)", st)
	}
	if st, _ := stateOf(t, reg, "nova"); st != session.StateRunning {
		t.Errorf("nova = %q, quero running (é a dona atual do terminal)", st)
	}
}

// TestPaneCollisionActsWithOracleDown: a colisão é prova LOCAL — sai só do
// Registry, sem tocar a rede. Ficava atrás do portão "oráculo respondeu por esta
// máquina", então um ssh caído engavetava justamente a evidência que não
// depende de ssh. Com o oráculo mudo dos dois lados, o destino tem que ser
// idle: a lista de transcripts é desconhecida, e esquecer não é reversível.
func TestPaneCollisionActsWithOracleDown(t *testing.T) {
	reg, rp := fixture(t, &fakeOracle{
		errLive: errors.New("ssh: connection refused"),
		errDisk: errors.New("ssh: connection refused"),
	})
	rp.SetGrace(time.Hour) // graça longa: só a colisão pode agir aqui
	addRunning(t, reg, "antiga", "sock\t%0", 3*time.Hour)
	addRunning(t, reg, "nova", "sock\t%0", time.Minute)

	rp.Tick()

	st, ok := stateOf(t, reg, "antiga")
	if !ok {
		t.Fatalf("antiga foi esquecida; com transcripts desconhecidos só pode virar idle")
	}
	if st != session.StateIdle {
		t.Errorf("antiga = %q, quero idle (perdeu o terminal, e isso se prova sem rede)", st)
	}
	if st, _ := stateOf(t, reg, "nova"); st != session.StateRunning {
		t.Errorf("nova = %q, quero running (é a dona atual do terminal)", st)
	}
}

// TestResolveRecheckHandleGainedMidTick: entre a triagem do Tick e a escrita há
// ida e volta de ssh. Se um SendText/Reply relançar a sessão nesse intervalo, o
// hub passa a segurar o processo — mas o `resume` não mexe no State, então o CAS
// a partir de running passava e mandava para idle uma sessão viva na mão do
// próprio hub. O reteste do handle no resolve() fecha a janela.
func TestResolveRecheckHandleGainedMidTick(t *testing.T) {
	o := &fakeOracle{disk: []string{"retomada"}}
	// Ninguém segura o handle na triagem; ele aparece durante a consulta.
	o.onLive = func() { o.handles = map[string]bool{"retomada": true} }
	reg, rp := fixture(t, o)
	addRunning(t, reg, "retomada", "%0", time.Hour)

	rp.Tick()

	if st, ok := stateOf(t, reg, "retomada"); !ok || st != session.StateRunning {
		t.Fatalf("estado = %q (existe=%v), quero running: o hub segura o processo", st, ok)
	}
}

// TestOracleIsPerAgent: cada agente tem o SEU oráculo (o claude lê ~/.claude, o
// codex lê ~/.codex) e nenhum enxerga as sessões do outro. Agrupando só por
// máquina, o oráculo do claude-code respondia por todo mundo: uma sessão codex
// sem handle (depois de um restart do hub) era invisível ali, e como o
// TranscriptIDs do claude também não a listava, o destino era Forget — sumia do
// Registry sem ninguém ter medido nada. Hoje codex/opencode não implementam
// Liver, então a resposta certa é "não sei" e a sessão fica intocada.
func TestOracleIsPerAgent(t *testing.T) {
	o := &fakeAgentOracle{
		live: map[string][]session.Discovered{"claude-code": {}},
		disk: map[string][]string{"claude-code": {"do-claude"}},
		errs: map[string]error{"codex": errors.New("agente sem oráculo")},
	}
	reg := registry.New()
	rp := New(engine.New(reg), reg, o, nil)
	rp.SetGrace(0)
	addRunningAgent(t, reg, "do-claude", "%0", "claude-code", time.Hour)
	addRunningAgent(t, reg, "do-codex", "%1", "codex", time.Hour)

	rp.Tick()

	if !o.asked[(oracleKey{"macbook", "codex"})] {
		t.Errorf("o reaper não perguntou pelo oráculo do codex; perguntou %v", o.asked)
	}
	if st, ok := stateOf(t, reg, "do-codex"); !ok || st != session.StateRunning {
		t.Fatalf("codex = %q (existe=%v), quero running: não há oráculo que a meça", st, ok)
	}
	// Contraprova: a do claude, essa sim medida e ausente, foi resolvida.
	if st, _ := stateOf(t, reg, "do-claude"); st != session.StateIdle {
		t.Errorf("claude = %q, quero idle (o oráculo dela respondeu e não a viu)", st)
	}
}

// TestPaneCollisionIgnoresEmptyPane: sessões de subagente nascem sem pane; se o
// pane vazio contasse como colisão, TODAS elas se matariam entre si.
func TestPaneCollisionIgnoresEmptyPane(t *testing.T) {
	got := paneCollisions([]session.Session{
		{ID: "a", Machine: "macbook", Pane: ""},
		{ID: "b", Machine: "macbook", Pane: ""},
	})
	if len(got) != 0 {
		t.Fatalf("colisões = %v, quero nenhuma", got)
	}
}

// TestPaneCollisionIgnoresCrossMachine: o alvo "<socket>\t<pane>" não carrega a
// máquina, e os defaults do tmux coincidem entre máquinas (SEC-104).
func TestPaneCollisionIgnoresCrossMachine(t *testing.T) {
	got := paneCollisions([]session.Session{
		{ID: "a", Machine: "macbook", Pane: "default\t%0"},
		{ID: "b", Machine: "macmini", Pane: "default\t%0"},
	})
	if len(got) != 0 {
		t.Fatalf("colisões = %v, quero nenhuma entre máquinas diferentes", got)
	}
}

// TestStartAndCloseAreClean: o loop sobe, faz pelo menos um tick e para sem
// vazar goroutine. Close é idempotente (chamado duas vezes de propósito).
func TestStartAndCloseAreClean(t *testing.T) {
	reg, rp := fixture(t, &fakeOracle{disk: []string{"zumbi"}})
	addRunning(t, reg, "zumbi", "%0", time.Hour)
	rp.SetInterval(10 * time.Millisecond)

	rp.Start()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if st, _ := stateOf(t, reg, "zumbi"); st == session.StateIdle {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	rp.Close()
	rp.Close()

	if st, _ := stateOf(t, reg, "zumbi"); st != session.StateIdle {
		t.Fatalf("estado = %q, quero idle: o loop não chegou a rodar", st)
	}
}
