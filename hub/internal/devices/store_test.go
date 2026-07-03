package devices

import (
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// Persistência: um Store com path grava no disco e um novo Store no mesmo path
// recarrega os devices (sobrevive a restart/deploy do hub).
func TestPersistenceRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "devices.json")

	s1 := NewAt(path)
	s1.Upsert("aa", "ios")
	s1.Upsert("bb", "ios")

	s2 := NewAt(path) // simula um restart do hub
	got := s2.List()
	if len(got) != 2 {
		t.Fatalf("após reload tem %d devices, quero 2", len(got))
	}
	if got[0].Token != "aa" || got[1].Token != "bb" {
		t.Fatalf("tokens não bateram após reload: %+v", got)
	}
}

// TestPersistenceConcurrent: Upserts concorrentes não corrompem o arquivo e o
// disco reflete todos ao recarregar (persistMu serializa as gravações — SEC-105).
func TestPersistenceConcurrent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "devices.json")
	s := NewAt(path)

	const n = 50
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			// token hex único de 40 chars a partir do índice.
			s.Upsert(fmtToken(i), "ios")
		}(i)
	}
	wg.Wait()

	reloaded := NewAt(path).List()
	if len(reloaded) != n {
		t.Fatalf("após %d upserts concorrentes, disco tem %d devices", n, len(reloaded))
	}
}

// fmtToken gera um token hex determinístico de 40 chars para o índice i.
func fmtToken(i int) string {
	const hex = "0123456789abcdef"
	b := make([]byte, 40)
	for j := range b {
		b[j] = hex[(i+j)%16]
	}
	// garante unicidade por i nos primeiros chars
	b[0] = hex[i%16]
	b[1] = hex[(i/16)%16]
	return string(b)
}

// Remove também é persistido: o device sai do disco, não volta no reload.
func TestPersistenceRemove(t *testing.T) {
	path := filepath.Join(t.TempDir(), "devices.json")

	s1 := NewAt(path)
	s1.Upsert("aa", "ios")
	s1.Upsert("bb", "ios")
	s1.Remove("aa")

	s2 := NewAt(path)
	got := s2.List()
	if len(got) != 1 || got[0].Token != "bb" {
		t.Fatalf("após remove+reload quero só 'bb', tenho %+v", got)
	}
}

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
