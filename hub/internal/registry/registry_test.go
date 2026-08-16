package registry

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

// TestPersistenceRoundTrip: sessões + estado + dismissed sobrevivem a um
// "restart" (novo Registry no mesmo path). Sessão concluída volta como done.
func TestPersistenceRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sessions.json")
	now := time.Now()

	r1 := NewAt(path)
	r1.Add(session.Session{ID: "a", Machine: "macbook", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})
	_ = r1.UpdateState("a", session.StateDone) // concluiu
	r1.Add(session.Session{ID: "b", Machine: "macbook", State: session.StateNeedsYou, CreatedAt: now, UpdatedAt: now})
	r1.Remove("b") // apagada → dismissed

	r2 := NewAt(path) // simula restart do hub
	if s, ok := r2.Get("a"); !ok || s.State != session.StateDone {
		t.Errorf("sessão 'a' devia voltar como done; ok=%v state=%q", ok, s.State)
	}
	if !r2.Dismissed("b") {
		t.Error("'b' devia continuar dismissed após restart")
	}
	if _, ok := r2.Get("b"); ok {
		t.Error("'b' foi apagada; não devia reaparecer")
	}
}

// TestPersistNaoGravaSessaoVelha: o TTL também vale na ESCRITA. Antes só o load
// filtrava, então um hub que nunca reinicia reescrevia para sempre o que o
// próximo boot ia jogar fora — o arquivo crescia sem limite.
func TestPersistNaoGravaSessaoVelha(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sessions.json")
	velha := time.Now().Add(-persistSessionTTL - time.Hour)
	agora := time.Now()

	r := NewAt(path)
	r.Add(session.Session{ID: "velha", Machine: "m", State: session.StateDone, CreatedAt: velha, UpdatedAt: velha})
	r.Add(session.Session{ID: "nova", Machine: "m", State: session.StateDone, CreatedAt: agora, UpdatedAt: agora})
	r.Add(session.Session{ID: "probe", Machine: "m", State: session.StateDone, Cwd: "/tmp/ClaudeProbe", CreatedAt: agora, UpdatedAt: agora})

	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("lendo o arquivo persistido: %v", err)
	}
	var ps persistState
	if err := json.Unmarshal(b, &ps); err != nil {
		t.Fatalf("json inválido: %v", err)
	}
	gravadas := map[string]bool{}
	for _, s := range ps.Sessions {
		gravadas[s.ID] = true
	}
	if gravadas["velha"] {
		t.Error("sessão além do TTL não devia ir para o disco")
	}
	if gravadas["probe"] {
		t.Error("probe (cwd efêmero) não devia ir para o disco")
	}
	if !gravadas["nova"] {
		t.Errorf("sessão nova devia estar no disco; gravadas=%v", gravadas)
	}
}

// TestLoadDescartaVelhaJaGravada: arquivo escrito por um hub ANTERIOR ao filtro
// da escrita pode ter sessões velhas — o load segue descartando (é o que limpa o
// lixo herdado no primeiro restart).
func TestLoadDescartaVelhaJaGravada(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sessions.json")
	velha := time.Now().Add(-persistSessionTTL - time.Hour)
	agora := time.Now()
	b, err := json.Marshal(persistState{Sessions: []session.Session{
		{ID: "velha", Machine: "m", State: session.StateDone, CreatedAt: velha, UpdatedAt: velha},
		{ID: "nova", Machine: "m", State: session.StateDone, CreatedAt: agora, UpdatedAt: agora},
	}})
	if err != nil {
		t.Fatalf("montando o json: %v", err)
	}
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatalf("escrevendo o arquivo: %v", err)
	}

	r := NewAt(path)
	if _, ok := r.Get("velha"); ok {
		t.Error("sessão velha já gravada não devia recarregar")
	}
	if _, ok := r.Get("nova"); !ok {
		t.Error("sessão nova devia recarregar")
	}
}

// TestPersistenceDropsStale: sessões paradas há mais que o TTL não recarregam.
func TestPersistenceDropsStale(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sessions.json")
	old := time.Now().Add(-persistSessionTTL - time.Hour)
	fresh := time.Now()

	r1 := NewAt(path)
	r1.Add(session.Session{ID: "velha", Machine: "m", State: session.StateDone, CreatedAt: old, UpdatedAt: old})
	r1.Add(session.Session{ID: "nova", Machine: "m", State: session.StateDone, CreatedAt: fresh, UpdatedAt: fresh})

	r2 := NewAt(path)
	if _, ok := r2.Get("velha"); ok {
		t.Error("sessão velha (além do TTL) não devia recarregar")
	}
	if _, ok := r2.Get("nova"); !ok {
		t.Error("sessão nova devia recarregar")
	}
}

func mkSession(id string, created time.Time) session.Session {
	return session.Session{
		ID:        id,
		Machine:   "macbook",
		Agent:     "claude-code",
		Title:     "tarefa " + id,
		State:     session.StateRunning,
		CreatedAt: created,
		UpdatedAt: created,
	}
}

func TestAddAndGet(t *testing.T) {
	r := New()
	s := mkSession("a", time.Now())
	r.Add(s)

	got, ok := r.Get("a")
	if !ok {
		t.Fatalf("Get(\"a\") ok = false, quero true")
	}
	if got.ID != "a" {
		t.Errorf("ID = %q, quero \"a\"", got.ID)
	}
}

func TestGetMissingReturnsFalse(t *testing.T) {
	r := New()
	if _, ok := r.Get("nada"); ok {
		t.Errorf("Get de id inexistente ok = true, quero false")
	}
}

func TestListOrderedByCreatedAt(t *testing.T) {
	r := New()
	base := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	r.Add(mkSession("c", base.Add(2*time.Minute)))
	r.Add(mkSession("a", base))
	r.Add(mkSession("b", base.Add(1*time.Minute)))

	list := r.List()
	if len(list) != 3 {
		t.Fatalf("len(List) = %d, quero 3", len(list))
	}
	want := []string{"a", "b", "c"}
	for i, id := range want {
		if list[i].ID != id {
			t.Errorf("List[%d].ID = %q, quero %q", i, list[i].ID, id)
		}
	}
}

func TestSetPendingPromptBroadcasts(t *testing.T) {
	r := New()
	r.Add(mkSession("a", time.Now()))

	sub := r.Subscribe()
	defer r.Unsubscribe(sub)

	r.SetPendingPrompt("a", "Bash: rm -rf / — apagar tudo")

	got, _ := r.Get("a")
	if got.PendingPrompt != "Bash: rm -rf / — apagar tudo" {
		t.Errorf("PendingPrompt = %q, quero o texto definido", got.PendingPrompt)
	}
	select {
	case s := <-sub.C:
		if s.PendingPrompt == "" {
			t.Errorf("broadcast sem PendingPrompt, quero o texto")
		}
	case <-time.After(time.Second):
		t.Fatalf("SetPendingPrompt não fez broadcast")
	}
}

func TestSetPendingPromptSameTextNoBroadcast(t *testing.T) {
	r := New()
	r.Add(mkSession("a", time.Now()))
	r.SetPendingPrompt("a", "x")

	sub := r.Subscribe()
	defer r.Unsubscribe(sub)
	r.SetPendingPrompt("a", "x") // mesmo texto: no-op

	select {
	case <-sub.C:
		t.Errorf("SetPendingPrompt com mesmo texto fez broadcast, quero no-op")
	case <-time.After(50 * time.Millisecond):
	}
}

func TestClearPendingPromptBroadcastsAndIsIdempotent(t *testing.T) {
	r := New()
	r.Add(mkSession("a", time.Now()))
	r.SetPendingPrompt("a", "algo")

	sub := r.Subscribe()
	defer r.Unsubscribe(sub)

	r.ClearPendingPrompt("a")
	if got, _ := r.Get("a"); got.PendingPrompt != "" {
		t.Errorf("PendingPrompt = %q, quero vazio após clear", got.PendingPrompt)
	}
	select {
	case <-sub.C:
	case <-time.After(time.Second):
		t.Fatalf("ClearPendingPrompt não fez broadcast")
	}

	// Segundo clear: já vazio, não deve fazer broadcast.
	r.ClearPendingPrompt("a")
	select {
	case <-sub.C:
		t.Errorf("ClearPendingPrompt idempotente fez broadcast, quero no-op")
	case <-time.After(50 * time.Millisecond):
	}
}

func TestPendingPromptOnMissingSessionIsNoOp(t *testing.T) {
	r := New()
	r.SetPendingPrompt("nada", "x") // não deve panicar nem criar sessão
	r.ClearPendingPrompt("nada")
	if _, ok := r.Get("nada"); ok {
		t.Errorf("sessão inexistente foi criada, quero no-op")
	}
}

func TestUpdateStateChangesStateAndUpdatedAt(t *testing.T) {
	r := New()
	old := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	r.Add(mkSession("a", old))

	if err := r.UpdateState("a", session.StateDone); err != nil {
		t.Fatalf("UpdateState: %v", err)
	}

	got, _ := r.Get("a")
	if got.State != session.StateDone {
		t.Errorf("State = %q, quero \"done\"", got.State)
	}
	if !got.UpdatedAt.After(old) {
		t.Errorf("UpdatedAt = %v, quero depois de %v", got.UpdatedAt, old)
	}
	if !got.CreatedAt.Equal(old) {
		t.Errorf("CreatedAt = %v, quero inalterado %v", got.CreatedAt, old)
	}
}

func TestUpdateStateMissingReturnsError(t *testing.T) {
	r := New()
	if err := r.UpdateState("nada", session.StateDone); err == nil {
		t.Errorf("UpdateState de id inexistente err = nil, quero erro")
	}
}

// TestUpdateStateIfCurrentAppliesWhenStateMatches cobre o caminho feliz da
// primitiva atômica: estado atual bate com `from`, a transição acontece.
func TestUpdateStateIfCurrentAppliesWhenStateMatches(t *testing.T) {
	r := New()
	old := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	r.Add(mkSession("a", old))

	ok := r.UpdateStateIfCurrent("a", session.StateRunning, session.StateError)
	if !ok {
		t.Fatalf("UpdateStateIfCurrent = false, quero true (estado batia)")
	}
	got, _ := r.Get("a")
	if got.State != session.StateError {
		t.Errorf("State = %q, quero \"error\"", got.State)
	}
	if !got.UpdatedAt.After(old) {
		t.Errorf("UpdatedAt = %v, quero depois de %v", got.UpdatedAt, old)
	}
}

// TestUpdateStateIfCurrentNoOpsWhenStateChanged cobre o achado BLOQUEANTE da
// revisão da Ludmilla (card 6b74500a1fd9a1f2): se o estado atual já não é mais
// `from` (ex.: a sessão terminou com sucesso por conta própria numa corrida),
// a chamada não pode sobrescrever o estado terminal legítimo.
func TestUpdateStateIfCurrentNoOpsWhenStateChanged(t *testing.T) {
	r := New()
	old := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	s := mkSession("a", old)
	s.State = session.StateDone
	r.Add(s)

	ok := r.UpdateStateIfCurrent("a", session.StateRunning, session.StateError)
	if ok {
		t.Fatalf("UpdateStateIfCurrent = true, quero false (estado já não era running)")
	}
	got, _ := r.Get("a")
	if got.State != session.StateDone {
		t.Errorf("State = %q, quero \"done\" preservado (não pode virar error)", got.State)
	}
	if got.UpdatedAt.After(old) {
		t.Errorf("UpdatedAt = %v, mudou mesmo com no-op — não devia", got.UpdatedAt)
	}
}

// TestUpdateStateIfCurrentMissingSessionReturnsFalse cobre id desconhecido:
// no-op, sem pânico.
func TestUpdateStateIfCurrentMissingSessionReturnsFalse(t *testing.T) {
	r := New()
	if ok := r.UpdateStateIfCurrent("fantasma", session.StateRunning, session.StateError); ok {
		t.Errorf("UpdateStateIfCurrent = true, quero false (sessão não existe)")
	}
}

func TestSubscribeReceivesOnAdd(t *testing.T) {
	r := New()
	sub := r.Subscribe()
	defer r.Unsubscribe(sub)

	r.Add(mkSession("a", time.Now()))

	select {
	case s := <-sub.C:
		if s.ID != "a" {
			t.Errorf("recebido ID = %q, quero \"a\"", s.ID)
		}
	case <-time.After(time.Second):
		t.Fatal("timeout esperando evento de Add")
	}
}

func TestSubscribeReceivesOnUpdateState(t *testing.T) {
	r := New()
	r.Add(mkSession("a", time.Now()))

	sub := r.Subscribe()
	defer r.Unsubscribe(sub)

	if err := r.UpdateState("a", session.StateNeedsYou); err != nil {
		t.Fatalf("UpdateState: %v", err)
	}

	select {
	case s := <-sub.C:
		if s.State != session.StateNeedsYou {
			t.Errorf("recebido State = %q, quero \"needs_you\"", s.State)
		}
	case <-time.After(time.Second):
		t.Fatal("timeout esperando evento de UpdateState")
	}
}

func TestUnsubscribeStopsDelivery(t *testing.T) {
	r := New()
	sub := r.Subscribe()
	r.Unsubscribe(sub)

	r.Add(mkSession("a", time.Now()))

	// Após Unsubscribe o canal deve estar fechado e não entregar mais eventos.
	select {
	case s, ok := <-sub.C:
		if ok {
			t.Errorf("recebeu evento %q após Unsubscribe", s.ID)
		}
	case <-time.After(200 * time.Millisecond):
		// canal não fechado explicitamente também é aceitável (sem entrega)
	}
}

func TestMultipleSubscribersBothReceive(t *testing.T) {
	r := New()
	s1 := r.Subscribe()
	defer r.Unsubscribe(s1)
	s2 := r.Subscribe()
	defer r.Unsubscribe(s2)

	r.Add(mkSession("a", time.Now()))

	for i, sub := range []*Subscription{s1, s2} {
		select {
		case <-sub.C:
		case <-time.After(time.Second):
			t.Fatalf("subscriber %d não recebeu evento", i)
		}
	}
}

func TestConcurrentAccessIsRaceFree(t *testing.T) {
	r := New()
	var wg sync.WaitGroup

	// Subscribers que drenam continuamente.
	stop := make(chan struct{})
	for range 4 {
		sub := r.Subscribe()
		wg.Go(func() {
			for {
				select {
				case <-sub.C:
				case <-stop:
					r.Unsubscribe(sub)
					return
				}
			}
		})
	}

	// Escritores concorrentes.
	for i := range 8 {
		wg.Go(func() {
			id := fmt.Sprintf("s%d", i)
			r.Add(mkSession(id, time.Now()))
			_ = r.UpdateState(id, session.StateDone)
		})
	}

	// Leitores concorrentes.
	for range 8 {
		wg.Go(func() {
			_ = r.List()
			_, _ = r.Get("s0")
		})
	}

	// Deixa os escritores/leitores rodarem e para os subscribers.
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()
	// Fecha subscribers só depois de escritores/leitores terem sido criados.
	time.Sleep(50 * time.Millisecond)
	close(stop)
	<-done
}

// TestSetPaneEvictionClearsPendingQuestions cobre o achado do card
// a87e93b01123fa13 (bug irmão descoberto na mesma revisão): o switch de
// evicção do SetPane, no case StateNeedsYou, limpava PendingPrompt mas
// esquecia PendingQuestions — violando a invariante documentada em
// session.go:66-72 ("Vazio nos demais casos" de needs_you). Sem a correção,
// uma sessão evictada saía em StateDone com PendingQuestions ainda populado
// (dado sujo no Registry e no JSON persistido). Nota: o nome de teste pedido
// na tarefa original (TestSetPaneEvictsAndMarksBroadcastOnly) não existe no
// repo — a cobertura de SetPane mora em internal/engine/engine_test.go
// (TestSetPaneEvictsStaleSession), que também não cobria PendingQuestions;
// este teste fica em registry_test.go por testar Registry.SetPane
// diretamente, sem passar pelo Engine.
func TestSetPaneEvictionClearsPendingQuestions(t *testing.T) {
	r := New()
	now := time.Now()
	pane := "/tmp/tmux-501/main\t%0"
	qs := []session.Question{{Question: "qual?", Options: []session.QuestionOption{{Label: "a"}, {Label: "b"}}}}

	// A: travada em needs_you, com PendingQuestions preenchido E com a pane.
	r.Add(session.Session{
		ID: "A", Machine: "macbook", State: session.StateNeedsYou,
		Pane: pane, PendingPrompt: "?", PendingQuestions: qs,
		CreatedAt: now, UpdatedAt: now,
	})
	// B: nova sessão reusa a MESMA pane — evicta A.
	r.Add(session.Session{ID: "B", Machine: "macbook", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})
	r.SetPane("B", pane)

	a, _ := r.Get("A")
	if a.State != session.StateDone {
		t.Fatalf("A.State = %q, quero done (evictada)", a.State)
	}
	if a.PendingPrompt != "" {
		t.Errorf("A.PendingPrompt = %q, quero vazio após evicção", a.PendingPrompt)
	}
	if len(a.PendingQuestions) != 0 {
		t.Errorf("A.PendingQuestions = %+v, quero vazio após evicção (invariante de session.go:66-72)", a.PendingQuestions)
	}
}

func TestRemoveDeletesAndSignals(t *testing.T) {
	r := New()
	sub := r.Subscribe()
	defer r.Unsubscribe(sub)
	r.Add(session.Session{ID: "s1", State: session.StateRunning})
	<-sub.C // consome o Add

	if !r.Remove("s1") {
		t.Fatal("Remove(s1) = false, quero true (existia)")
	}
	if _, ok := r.Get("s1"); ok {
		t.Error("sessão ainda existe após Remove")
	}
	select {
	case id := <-sub.Removed:
		if id != "s1" {
			t.Errorf("Removed = %q, quero s1", id)
		}
	case <-time.After(time.Second):
		t.Fatal("não recebeu sinal de remoção")
	}
	if r.Remove("s1") {
		t.Error("Remove de sessão inexistente = true, quero false")
	}
}
