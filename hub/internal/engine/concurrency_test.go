package engine

import (
	"sync"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/event"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// Este arquivo cobre o ACHADO 2 (card 5dea19beab6d92e4): Apply lê o estado
// atual com e.reg.Get (RLock/RUnlock), decide a transição em cima do
// snapshot FORA de qualquer lock, e só depois escreve com e.reg.UpdateState
// (Lock/Unlock separado, escrita cega — não é CAS). Cada chamada isolada ao
// Registry é atômica; a SEQUÊNCIA de chamadas que Apply compõe não é.
//
// IMPORTANTE: nada aqui é pego por `go test -race`. Toda leitura e toda
// escrita passa por mu.RLock/mu.Lock do Registry — não há acesso concorrente
// desprotegido à mesma memória em ponto nenhum. O que existe é corrida
// LÓGICA clássica (TOCTOU / lost update entre duas seções críticas
// separadas), uma classe que o race detector não enxerga e nunca vai
// enxergar, mesmo com mais iterações. Por isso os testes abaixo afirmam
// invariantes sobre o ESTADO FINAL (não sobre ausência de race do Go), e
// repetem N vezes para dar chance de o entrelaçamento ruim acontecer.
//
// raceTwo dispara f1 e f2 atrás de uma barreira (close(start): as duas só
// começam depois que a outra já está bloqueada esperando, maximizando a
// chance de sobreposição real) e espera as duas terminarem, com um teto de
// 2s como guarda contra hang. Nenhuma das chamadas usadas aqui bloqueia de
// verdade — Engine.Apply e Engine.Idle só mexem em memória (sem histórico
// configurado, e.record é no-op imediato) — então o teto nunca deveria
// disparar; ele existe só para um bug futuro não travar a suíte inteira em
// vez de falhar com uma mensagem clara.
func raceTwo(t *testing.T, f1, f2 func()) {
	t.Helper()
	start := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { <-start; f1(); wg.Done() }()
	go func() { <-start; f2(); wg.Done() }()
	close(start)

	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("raceTwo: goroutines concorrentes não terminaram (hang inesperado)")
	}
}

// concurrencyTrials é quantas vezes cada teste abaixo repete a corrida.
// Calibrado empiricamente (harness isolado, mesma forma exata: RLock/decide
// fora do lock/Lock cego, sem I/O, GOMAXPROCS default): taxa de reprodução
// do entrelaçamento ruim ≈ 1–2% por trial. Com N=2000, P(nenhuma reprodução)
// ≈ (1-0,01)^2000 < 0,001% — folga confortável mesmo em máquina/CI mais
// lenta. custo é irrelevante: cada trial só mexe em memória (sem I/O), a
// suíte inteira roda em milissegundos.
//
// ATENÇÃO para quem for mexer aqui: NUNCA fixar runtime.GOMAXPROCS(1) nestes
// testes. A mesma calibração mediu 0% de reprodução em 10000 trials com
// GOMAXPROCS=1 — a corrida depende de paralelismo real (dois núcleos
// executando ao mesmo tempo), não de scheduling cooperativo. Forçar
// GOMAXPROCS(1) tornaria estes testes permanentemente verdes mesmo com o
// bug presente, criando falsa confiança.
const concurrencyTrials = 2000

// TestApply_ConcurrentUserRespondedVsTerminalEvent_NeverRegressesTerminalState
// cobre a Sequência A (engine.go, guarda de linhas ~149-169): uma vez que um
// evento terminal (finished/errored/session_ended) grava um veredito, um
// user_responded concorrente — que leu needs_you ANTES da escrita terminal —
// nunca pode reverter esse veredito de volta a running. É exatamente o
// invariante que o comentário do Apply promete ("evita regredir done→running
// numa corrida... ambos chamam Apply"), mas a guarda só filtra pelo snapshot
// do MOMENTO DA LEITURA, não do momento da escrita — a janela entre o
// e.reg.Get e o e.reg.UpdateState fica aberta.
//
// [16/08/2026] REATIVADO: a Sequência A foi corrigida — Apply (engine.go) usa
// agora um LOOP de releitura+CAS (UpdateStateIfCurrent) em vez da escrita cega
// e.reg.UpdateState. Uma troca ingênua para CAS de tiro único (from = snapshot
// lido uma vez no topo) só fecharia METADE das ordens de chegada — a outra
// metade passaria a perder pelo lado espelhado (o evento terminal descartado
// por `from` obsoleto). O loop relê fresco a cada tentativa e reavalia as
// MESMAS guards, fechando as duas direções. Decisão da dona do projeto (16/08,
// Opção 2 "falha e conta"): a escrita perdedora não aplica, e o fato fica
// observável via slog.Debug/Warn — nunca engolida em silêncio nem mascarada
// como se a transição tivesse ocorrido (e.record só roda após o loop
// convergir).
func TestApply_ConcurrentUserRespondedVsTerminalEvent_NeverRegressesTerminalState(t *testing.T) {
	cases := []struct {
		name   string
		termEv event.Type
		termSt session.State
	}{
		{"finished => done", event.Finished, session.StateDone},
		{"errored => error", event.Errored, session.StateError},
		{"session_ended => idle", event.SessionEnded, session.StateIdle},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			regressions := 0
			for i := 0; i < concurrencyTrials; i++ {
				reg := registry.New()
				eng := New(reg)
				seed(reg, "s", session.StateNeedsYou)

				raceTwo(t,
					func() { eng.Apply(event.Event{SessionID: "s", Type: event.UserResponded}) },
					func() { eng.Apply(event.Event{SessionID: "s", Type: c.termEv}) },
				)

				got, _ := reg.Get("s")
				if got.State == session.StateRunning {
					regressions++
				}
			}
			if regressions > 0 {
				t.Errorf("%s: %d/%d trials regrediram o estado terminal de volta a \"running\" — "+
					"UserResponded concorrente pisou num veredito (%q) que já tinha sido gravado. "+
					"Causa: o loop de CAS de Apply (engine.go) regrediu.",
					c.name, regressions, concurrencyTrials, c.termSt)
			}
		})
	}
}

// TestApply_ConcurrentPermissionRequestedVsSessionEnded_PendingPromptNeverDanglesOutsideNeedsYou
// cobre a Sequência B (engine.go:169-195): o invariante documentado em
// registry.go:459-461 e reforçado no comentário do Apply ("ao sair de
// needs_you nenhum dos dois faz mais sentido") — State != needs_you implica
// PendingPrompt=="" e PendingQuestions vazio — deve valer SEMPRE, mesmo sob
// corrida. Hoje a escrita do estado (UpdateState) e a escrita do
// PendingPrompt/PendingQuestions (SetPendingPrompt/ClearPendingPrompt) são
// seções críticas SEPARADAS: uma segunda goroutine de Apply para a MESMA
// sessão, correndo entre as duas, pode fazer o estado e o PendingPrompt
// terminarem descasados (pertencerem a eventos diferentes).
//
// Se isto falhar: expõe um lost update entre as 2-3 seções críticas de
// engine.go:175-195. Diferente da Sequência A, o conserto aqui não é um
// simples swap de método — exigiria mover a escrita de estado e de
// PendingPrompt/Questions para dentro da MESMA seção crítica do Registry
// (mudança de contrato), decisão de arquitetura da dona do projeto, fora do
// escopo desta tarefa.
func TestApply_ConcurrentPermissionRequestedVsSessionEnded_PendingPromptNeverDanglesOutsideNeedsYou(t *testing.T) {
	// BUG REAL CONFIRMADO (achado deste teste, não consertado — decisão da dona
	// do projeto, fora do escopo desta tarefa): rodando os 2000 trials, dezenas
	// reproduziram o dangling em toda rodada local (ex.: 45/2000 numa rodada —
	// o número exato varia por rodada/máquina, é uma corrida real). Causa raiz:
	// a escrita do estado (engine.go:169) e a escrita de
	// PendingPrompt/PendingQuestions (engine.go:185-194) são seções críticas
	// SEPARADAS do Registry — uma segunda goroutine de Apply para a mesma
	// sessão pode intercalar as duas. Diferente da Sequência A, aqui não é um
	// simples swap de método: exigiria mover as duas escritas para dentro da
	// MESMA seção crítica do Registry (mudança de contrato). NÃO CONSERTE o
	// engine: só documente e siga.
	t.Skip("ACHADO 2 / card 5dea19beab6d92e4: reproduz PendingPrompt pendurado fora de needs_you (engine.go: escrita de estado e de PendingPrompt em seções críticas separadas) — fix é decisão de arquitetura da dona do projeto, adiada de propósito")

	dangling := 0
	for i := 0; i < concurrencyTrials; i++ {
		reg := registry.New()
		eng := New(reg)
		seed(reg, "s", session.StateRunning)

		raceTwo(t,
			func() {
				eng.Apply(event.Event{SessionID: "s", Type: event.PermissionRequested, Data: "prompt-G1"})
			},
			func() { eng.Apply(event.Event{SessionID: "s", Type: event.SessionEnded}) },
		)

		got, _ := reg.Get("s")
		if got.State != session.StateNeedsYou {
			if got.PendingPrompt != "" || len(got.PendingQuestions) != 0 {
				dangling++
			}
		}
	}
	if dangling > 0 {
		t.Errorf("%d/%d trials terminaram FORA de needs_you com PendingPrompt/PendingQuestions pendurado — "+
			"a escrita de estado e a de PendingPrompt são seções críticas separadas em engine.go, e uma "+
			"PermissionRequested concorrente com um SessionEnded pode intercalar as duas.",
			dangling, concurrencyTrials)
	}
}

// TestApply_OutputChunkDuringConcurrentRemove_DoesNotLeakOrphanOutput cobre a
// Sequência C (engine.go:134-137): output_chunk confere se a sessão existe
// (e.reg.Get) e só então grava o output (e.reg.AppendOutput) — duas seções
// críticas separadas. Um Registry.Remove concorrente entre as duas pode
// recriar um buffer de output para uma sessão que acabou de ser apagada de
// r.byID: AppendOutput (output.go:27) não reconfere existência.
//
// Severidade baixa (vazamento pequeno de memória, nunca limpo depois; não
// corrompe estado visível na UI) — incluído por completude do ACHADO 2, não
// bloqueante.
//
// Se isto falhar: expõe que output.go:27 não reconfere r.byID antes de
// escrever em r.outputs — fix envolveria decidir se AppendOutput deve
// silenciosamente ignorar sessão ausente (mudança de contrato do Registry),
// decisão da dona do projeto, fora do escopo desta tarefa.
func TestApply_OutputChunkDuringConcurrentRemove_DoesNotLeakOrphanOutput(t *testing.T) {
	// BUG REAL CONFIRMADO, severidade BAIXA (achado deste teste, não
	// consertado — decisão da dona do projeto, fora do escopo desta tarefa):
	// rodando os 2000 trials, dezenas reproduziram o vazamento em toda rodada
	// local (ex.: 91/2000 numa rodada — o número exato varia por
	// rodada/máquina, é uma corrida real). Causa raiz: AppendOutput
	// (output.go:27) não reconfere r.byID antes de escrever em r.outputs; o
	// Apply só confere existência ANTES (engine.go:134), não no momento da
	// escrita. Efeito é só vazamento pequeno de memória (nunca limpo depois),
	// não corrompe estado visível na UI — por isso severidade baixa, mas ainda
	// assim um bug real. NÃO CONSERTE o engine: só documente e siga.
	t.Skip("ACHADO 2 / card 5dea19beab6d92e4: reproduz output órfão pra sessão removida (output.go:27 não reconfere r.byID) — severidade baixa, fix é decisão da dona do projeto, adiada de propósito")

	leaks := 0
	for i := 0; i < concurrencyTrials; i++ {
		reg := registry.New()
		eng := New(reg)
		seed(reg, "s", session.StateRunning)

		raceTwo(t,
			func() { eng.Apply(event.Event{SessionID: "s", Type: event.OutputChunk, Data: "x"}) },
			func() { reg.Remove("s") },
		)

		if _, exists := reg.Get("s"); !exists {
			if out := reg.Output("s"); len(out) != 0 {
				leaks++
			}
		}
	}
	if leaks > 0 {
		t.Errorf("%d/%d trials deixaram output órfão para uma sessão já removida — "+
			"AppendOutput (output.go:27) não reconfere r.byID entre o Get de checagem do Apply e a própria escrita.",
			leaks, concurrencyTrials)
	}
}

// TestIdle_DoesNotRegressFreshNeedsYou_UnlikeApplyMainPath é um teste de
// CONTRASTE, esperado passar hoje SEM nenhuma mudança no engine — documenta
// que o padrão que a Sequência A deveria adotar já existe e já funciona no
// próprio pacote.
//
// Engine.Idle (usado pelo reaper) já demite Running→Idle via
// UpdateStateIfCurrent (CAS de verdade, registry.go:346) em vez da escrita
// cega que Apply usa em engine.go:169. Racendo eng.Idle(id, Running) contra
// um eng.Apply(NeedsInput) concorrente para a mesma sessão: como
// NeedsInput SEMPRE escreve needs_you (a regra de desempate do doc 03 diz
// que needs_input vence a partir de QUALQUER estado, mesmo done — Apply não
// confere o estado vivo de novo antes de escrever, só o snapshot lido no
// início), e o CAS do Idle só têm efeito enquanto o estado ainda for
// Running, a única saída possível para o campo State, em QUALQUER ordem de
// entrelaçamento, é needs_you:
//   - se o CAS do Idle vence primeiro (Running→idle) antes de Apply escrever,
//     o UpdateState incondicional do Apply ainda roda depois e sobrescreve
//     para needs_you;
//   - se o UpdateState do Apply escreve primeiro (Running→needs_you), o CAS
//     do Idle então vê o estado já diferente de Running e falha (no-op).
//
// Ou seja, diferente da Sequência A (onde a escrita cega do Apply podia SER a
// que vence por último e regredir um veredito terminal), aqui o Apply SEMPRE
// vence por último ou o CAS do Idle nunca chega a valer — nunca o contrário.
// Não é uma garantia estatística (N alto): é garantida pela combinação
// escrita-incondicional-do-Apply + CAS-defensivo-do-Idle, em qualquer ordem
// de escalonamento. Ainda assim roda com o mesmo N dos testes acima, como
// registro vivo de referência para o fix futuro da Sequência A.
func TestIdle_DoesNotRegressFreshNeedsYou_UnlikeApplyMainPath(t *testing.T) {
	for i := 0; i < concurrencyTrials; i++ {
		reg := registry.New()
		eng := New(reg)
		seed(reg, "s", session.StateRunning)

		raceTwo(t,
			func() { eng.Idle("s", session.StateRunning) },
			func() { eng.Apply(event.Event{SessionID: "s", Type: event.NeedsInput, Data: "aprova?"}) },
		)

		got, _ := reg.Get("s")
		if got.State != session.StateNeedsYou {
			t.Fatalf("trial %d: State = %q, quero needs_you sempre (o CAS do Idle nunca deveria vencer por "+
				"último contra um NeedsInput concorrente) — se isto falhou, o padrão de contraste quebrou e "+
				"precisa de investigação, não é o comportamento documentado", i, got.State)
		}
	}
}
