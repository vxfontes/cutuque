package notifier

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/apns"
	"github.com/vxfontes/cutuque/hub/internal/devices"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/event"
	"github.com/vxfontes/cutuque/hub/internal/registry"
)

// recordedPush é um push capturado pelo fake.
type recordedPush struct {
	token   string
	payload []byte
	opts    apns.PushOptions
}

// fakePusher captura pushes e os entrega por um canal para o teste sincronizar
// sem sleeps. Se o token estiver em goneTokens, devolve ErrGone.
type fakePusher struct {
	ch        chan recordedPush
	mu        sync.Mutex
	goneToken string
}

func newFakePusher() *fakePusher {
	return &fakePusher{ch: make(chan recordedPush, 16)}
}

func (f *fakePusher) Push(_ context.Context, token string, payload []byte, opts apns.PushOptions) error {
	cp := append([]byte(nil), payload...)
	f.ch <- recordedPush{token: token, payload: cp, opts: opts}
	f.mu.Lock()
	gone := f.goneToken
	f.mu.Unlock()
	if token == gone {
		return apns.ErrGone
	}
	return nil
}

// recv espera um push com timeout; falha o teste se nada chegar.
func recv(t *testing.T, f *fakePusher) recordedPush {
	t.Helper()
	select {
	case p := <-f.ch:
		return p
	case <-time.After(2 * time.Second):
		t.Fatal("nenhum push recebido dentro do timeout")
		return recordedPush{}
	}
}

// fixture monta registry+engine+notifier com um device registrado e o inicia.
func fixture(t *testing.T) (*engine.Engine, *registry.Registry, *devices.Store, *fakePusher, *Notifier) {
	t.Helper()
	reg := registry.New()
	eng := engine.New(reg)
	store := devices.New()
	store.Upsert("tokendevice1", "ios")
	fake := newFakePusher()
	n := New(fake, store, reg, nil)
	n.Start()
	t.Cleanup(n.Close)
	return eng, reg, store, fake, n
}

// startSession cria uma sessão em running via session_started.
func startSession(eng *engine.Engine, id string) {
	eng.Apply(event.Event{
		SessionID: id, Type: event.SessionStarted,
		Machine: "macbook", Agent: "claude-code", Title: "minha tarefa",
		At: time.Now(),
	})
}

func TestNotifiesOnNeedsYouWithPrompt(t *testing.T) {
	eng, _, _, fake, _ := fixture(t)
	startSession(eng, "s1")
	eng.Apply(event.Event{SessionID: "s1", Type: event.NeedsInput, Data: "posso rodar rm -rf /tmp/x?", At: time.Now()})

	p := recv(t, fake)
	body := string(p.payload)

	if !strings.Contains(body, `"state":"needs_you"`) {
		t.Errorf("payload sem state needs_you: %s", body)
	}
	if !strings.Contains(body, "⚠️ minha tarefa") {
		t.Errorf("payload sem title esperado: %s", body)
	}
	if !strings.Contains(body, "posso rodar rm -rf") {
		t.Errorf("payload sem o texto do pedido (PendingPrompt): %s", body)
	}
	if !strings.Contains(body, `"category":"NEEDS_YOU"`) {
		t.Errorf("payload sem category NEEDS_YOU: %s", body)
	}
	if !strings.Contains(body, `"interruption-level":"time-sensitive"`) {
		t.Errorf("payload sem interruption-level time-sensitive: %s", body)
	}
	if !strings.Contains(body, `"thread-id":"s1"`) {
		t.Errorf("payload sem thread-id da sessão: %s", body)
	}
}

func TestNotifiesOnlyOnceForNeedsYou(t *testing.T) {
	eng, reg, _, fake, _ := fixture(t)
	startSession(eng, "s1")
	eng.Apply(event.Event{SessionID: "s1", Type: event.NeedsInput, Data: "pergunta 1", At: time.Now()})
	first := recv(t, fake)
	if !strings.Contains(string(first.payload), "pergunta 1") {
		t.Fatalf("primeiro push inesperado: %s", first.payload)
	}

	// Rebroadcast com o estado ainda needs_you (novo texto direto no registry):
	// NÃO deve gerar um segundo push (não é transição).
	reg.SetPendingPrompt("s1", "pergunta 2")

	select {
	case p := <-fake.ch:
		t.Fatalf("push duplicado numa repetição de needs_you: %s", p.payload)
	case <-time.After(200 * time.Millisecond):
		// ok: nenhum push extra
	}
}

// TestForegroundSuppressesPush: com o app em foreground, uma transição que
// normalmente cutuca (done) NÃO dispara push.
func TestForegroundSuppressesPush(t *testing.T) {
	eng, _, _, fake, n := fixture(t)
	n.SetForeground(true)
	startSession(eng, "s1")
	eng.Apply(event.Event{SessionID: "s1", Type: event.Finished, At: time.Now()})

	select {
	case p := <-fake.ch:
		t.Fatalf("push disparado com app em foreground: %s", p.payload)
	case <-time.After(300 * time.Millisecond):
		// ok: suprimido
	}
}

// TestForegroundFalseResumesPush: ao voltar pro background (false), o push volta.
func TestForegroundFalseResumesPush(t *testing.T) {
	eng, _, _, fake, n := fixture(t)
	n.SetForeground(true)
	n.SetForeground(false) // app foi pro background
	startSession(eng, "s1")
	eng.Apply(event.Event{SessionID: "s1", Type: event.Finished, At: time.Now()})

	p := recv(t, fake)
	if !strings.Contains(string(p.payload), `"state":"done"`) {
		t.Errorf("push esperado após background: %s", p.payload)
	}
}

func TestNotifiesOnDone(t *testing.T) {
	eng, _, _, fake, _ := fixture(t)
	startSession(eng, "s1")
	eng.Apply(event.Event{SessionID: "s1", Type: event.Finished, At: time.Now()})

	p := recv(t, fake)
	body := string(p.payload)
	if !strings.Contains(body, `"state":"done"`) || !strings.Contains(body, "✅ minha tarefa") {
		t.Errorf("push de done inesperado: %s", body)
	}
	if !strings.Contains(body, "concluiu · macbook") {
		t.Errorf("body de done sem 'concluiu · <machine>': %s", body)
	}
	if !strings.Contains(body, `"category":"DONE"`) {
		t.Errorf("push de done sem category DONE: %s", body)
	}
}

func TestNotifiesOnError(t *testing.T) {
	eng, _, _, fake, _ := fixture(t)
	startSession(eng, "s1")
	eng.Apply(event.Event{SessionID: "s1", Type: event.Errored, At: time.Now()})

	p := recv(t, fake)
	body := string(p.payload)
	if !strings.Contains(body, `"state":"error"`) || !strings.Contains(body, "❌ minha tarefa") {
		t.Errorf("push de error inesperado: %s", body)
	}
	if !strings.Contains(body, "falhou · macbook") {
		t.Errorf("body de error sem 'falhou · <machine>': %s", body)
	}
}

func TestNoPushOnRunningCreation(t *testing.T) {
	eng, _, _, fake, _ := fixture(t)
	// Cria em running (sem push) e depois força um done: o PRIMEIRO push que
	// chega deve ser o de done — provando que a criação em running não empurrou.
	startSession(eng, "s1")
	eng.Apply(event.Event{SessionID: "s1", Type: event.Finished, At: time.Now()})

	p := recv(t, fake)
	if !strings.Contains(string(p.payload), `"state":"done"`) {
		t.Errorf("primeiro push não foi o de done (criação em running empurrou?): %s", p.payload)
	}
}

func TestFanoutToAllDevices(t *testing.T) {
	eng, _, store, fake, _ := fixture(t)
	store.Upsert("tokendevice2", "ios") // agora 2 devices
	startSession(eng, "s1")
	eng.Apply(event.Event{SessionID: "s1", Type: event.Finished, At: time.Now()})

	got := map[string]bool{}
	got[recv(t, fake).token] = true
	got[recv(t, fake).token] = true
	if !got["tokendevice1"] || !got["tokendevice2"] {
		t.Errorf("fan-out não atingiu os dois devices: %v", got)
	}
}

func TestGoneRemovesDevice(t *testing.T) {
	eng, _, store, fake, _ := fixture(t)
	fake.mu.Lock()
	fake.goneToken = "tokendevice1"
	fake.mu.Unlock()

	startSession(eng, "s1")
	eng.Apply(event.Event{SessionID: "s1", Type: event.Finished, At: time.Now()})
	recv(t, fake) // consome o push (que devolve ErrGone)

	// Espera a remoção assíncrona (a goroutine de fan-out chama Remove após Push).
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(store.List()) == 0 {
			return // ok
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Errorf("device com 410 não foi removido; store ainda tem %d", len(store.List()))
}

// TestPayloadNeverContainsOutput é o teste de segurança crítico: o output da
// sessão (sentinela) JAMAIS pode aparecer no JSON do push — só metadados.
func TestPayloadNeverContainsOutput(t *testing.T) {
	const sentinel = "===SENTINELA-OUTPUT-DO-AGENTE-NAO-VAZAR==="

	eng, reg, _, fake, _ := fixture(t)
	startSession(eng, "s1")
	// Injeta output com a sentinela (armazenado no buffer de output do registry).
	eng.Apply(event.Event{SessionID: "s1", Type: event.OutputChunk, Kind: event.KindAssistant, Data: sentinel, At: time.Now()})
	// Confirma que a sentinela está mesmo guardada (senão o teste seria vácuo).
	out := reg.Output("s1")
	var joined strings.Builder
	for _, c := range out {
		joined.WriteString(c.Text)
	}
	if len(out) == 0 || !strings.Contains(joined.String(), sentinel) {
		t.Fatalf("sentinela não foi guardada no output; teste inválido")
	}

	// Transição real para needs_you (com prompt) — dispara o push.
	eng.Apply(event.Event{SessionID: "s1", Type: event.NeedsInput, Data: "posso continuar?", At: time.Now()})

	p := recv(t, fake)
	if strings.Contains(string(p.payload), sentinel) {
		t.Fatalf("VAZAMENTO: output da sessão apareceu no payload do push:\n%s", p.payload)
	}
	// sanity: o push é mesmo o de needs_you com o prompt (não vazio à toa).
	if !strings.Contains(string(p.payload), "posso continuar?") {
		t.Errorf("push não carregou o PendingPrompt esperado: %s", p.payload)
	}
}

// TestRenudgeRepeatsWhileNeedsYou cobre a opção 1: enquanto a sessão continuar
// em needs_you, o Notifier re-cutuca periodicamente (mais de um push).
func TestRenudgeRepeatsWhileNeedsYou(t *testing.T) {
	eng, _, _, fake, n := fixture(t)
	n.SetRenudgeInterval(40 * time.Millisecond)
	startSession(eng, "s1")
	eng.Apply(event.Event{SessionID: "s1", Type: event.NeedsInput, Data: "aprova?", At: time.Now()})

	// Push imediato + pelo menos dois re-cutucões (a sessão segue em needs_you).
	for i := 0; i < 3; i++ {
		p := recv(t, fake)
		if !strings.Contains(string(p.payload), `"state":"needs_you"`) {
			t.Fatalf("push %d não é de needs_you: %s", i, p.payload)
		}
	}
}

// TestRenudgeStopsAfterResolved cobre o cancelamento: ao sair de needs_you
// (usuária respondeu → running), os re-cutucões param.
func TestRenudgeStopsAfterResolved(t *testing.T) {
	eng, _, _, fake, n := fixture(t)
	n.SetRenudgeInterval(40 * time.Millisecond)
	startSession(eng, "s1")
	eng.Apply(event.Event{SessionID: "s1", Type: event.NeedsInput, Data: "aprova?", At: time.Now()})
	recv(t, fake) // push imediato

	// Resolve: volta para running (aprovou). Deve cancelar o re-cutucão.
	eng.Apply(event.Event{SessionID: "s1", Type: event.UserResponded, At: time.Now()})

	// Drena eventuais re-cutucões em voo e então exige silêncio por vários intervalos.
	drainUntilQuiet(fake, 3*40*time.Millisecond)
	select {
	case p := <-fake.ch:
		t.Fatalf("re-cutucão continuou após resolver: %s", p.payload)
	case <-time.After(5 * 40 * time.Millisecond):
		// silêncio: correto
	}
}

// drainUntilQuiet consome pushes até não chegar nenhum por `quiet`.
func drainUntilQuiet(f *fakePusher, quiet time.Duration) {
	for {
		select {
		case <-f.ch:
		case <-time.After(quiet):
			return
		}
	}
}

// TestCloseDoesNotHangWithConcurrentNeedsYou cobre o achado bloqueante da review
// F4.1: um needs_you disparado no instante do Close() não pode deixar uma
// goroutine de nudge órfã travando o WaitGroup. Força a corrida N vezes e exige
// que Close() retorne dentro de um timeout curto.
func TestCloseDoesNotHangWithConcurrentNeedsYou(t *testing.T) {
	for i := 0; i < 50; i++ {
		reg := registry.New()
		eng := engine.New(reg)
		store := devices.New()
		store.Upsert("tokendevice1", "ios")
		n := New(newFakePusher(), store, reg, nil)
		n.SetRenudgeInterval(time.Hour) // nudge nunca dispararia sozinho; só o Close deve encerrá-lo
		n.Start()

		startSession(eng, "s1")
		// Dispara needs_you e Close() concorrentes para provocar a corrida.
		go eng.Apply(event.Event{SessionID: "s1", Type: event.NeedsInput, Data: "aprova?", At: time.Now()})

		done := make(chan struct{})
		go func() { n.Close(); close(done) }()

		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatalf("iteração %d: Close() travou (goroutine de nudge órfã)", i)
		}
	}
}
