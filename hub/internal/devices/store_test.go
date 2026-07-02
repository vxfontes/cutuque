package devices

import (
	"sync"
	"testing"
	"time"
)

func TestUpsertAndList(t *testing.T) {
	s := New()
	s.Upsert("aa", "ios")
	s.Upsert("bb", "ios")

	got := s.List()
	if len(got) != 2 {
		t.Fatalf("List tem %d devices, quero 2", len(got))
	}
}

func TestUpsertSameTokenPreservesRegisteredAt(t *testing.T) {
	s := New()
	t0 := time.Unix(1000, 0)
	cur := t0
	s.now = func() time.Time { return cur }

	first := s.Upsert("tok", "ios")

	cur = t0.Add(time.Hour)
	second := s.Upsert("tok", "ios") // re-registro

	if len(s.List()) != 1 {
		t.Fatalf("re-registro criou device novo; quero 1, tenho %d", len(s.List()))
	}
	if !second.RegisteredAt.Equal(first.RegisteredAt) {
		t.Errorf("RegisteredAt mudou no re-registro: %v → %v", first.RegisteredAt, second.RegisteredAt)
	}
}

func TestRemove(t *testing.T) {
	s := New()
	s.Upsert("tok", "ios")
	s.Remove("tok")
	if len(s.List()) != 0 {
		t.Errorf("Remove não apagou; List tem %d", len(s.List()))
	}
	s.Remove("tok") // idempotente: não deve panicar
}

func TestConcurrentAccessIsRaceFree(t *testing.T) {
	s := New()
	var wg sync.WaitGroup
	for i := range 50 {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			tok := string(rune('a' + n%26))
			s.Upsert(tok, "ios")
			_ = s.List()
			s.Remove(tok)
		}(i)
	}
	wg.Wait()
}
