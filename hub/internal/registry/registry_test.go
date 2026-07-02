package registry

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

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
