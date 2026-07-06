package history

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/event"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// testStore abre o Store contra o Postgres de teste (CUTUQUE_TEST_DATABASE_URL),
// pulando se não configurado, e limpa as tabelas para o teste ficar isolado.
func testStore(t *testing.T) *PostgresStore {
	t.Helper()
	url := os.Getenv("CUTUQUE_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("defina CUTUQUE_TEST_DATABASE_URL para rodar os testes de Postgres")
	}
	st, err := Open(context.Background(), url)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(st.Close)
	if _, err := st.pool.Exec(context.Background(), "TRUNCATE cutuque.sessions, cutuque.events"); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	return st
}

func TestUpsertSessionInsereEAtualiza(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	created := time.Now().Add(-time.Hour).UTC().Truncate(time.Millisecond)

	s := session.Session{ID: "ses_abc", Machine: "macbook", Agent: "opencode",
		Title: "teste", Cwd: "/tmp/x", Model: "zai/glm-4.5-flash",
		State: session.StateRunning, CreatedAt: created, UpdatedAt: created}
	if err := st.UpsertSession(ctx, s); err != nil {
		t.Fatalf("upsert insert: %v", err)
	}

	// Update: muda estado + updated_at; created_at deve ser preservado.
	s.State = session.StateDone
	s.UpdatedAt = time.Now().UTC().Truncate(time.Millisecond)
	if err := st.UpsertSession(ctx, s); err != nil {
		t.Fatalf("upsert update: %v", err)
	}

	got, err := st.RecentSessions(ctx, 10)
	if err != nil {
		t.Fatalf("recent: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("len = %d, quero 1 (upsert, não duplicar)", len(got))
	}
	if got[0].State != session.StateDone {
		t.Errorf("state = %q, quero done (update aplicado)", got[0].State)
	}
	if got[0].Model != "zai/glm-4.5-flash" {
		t.Errorf("model = %q, quero o persistido", got[0].Model)
	}
	if !got[0].CreatedAt.Equal(created) {
		t.Errorf("created_at = %v, quero o original %v (preservado no update)", got[0].CreatedAt, created)
	}
}

func TestAppendEventEOrdemCronologica(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	evs := []event.Event{
		{SessionID: "ses_x", Type: event.SessionStarted, At: now},
		{SessionID: "ses_x", Type: event.OutputChunk, Kind: event.KindUser, Data: "oi", At: now.Add(time.Second)},
		{SessionID: "ses_x", Type: event.OutputChunk, Kind: event.KindAssistant, Data: "olá", At: now.Add(2 * time.Second)},
		{SessionID: "ses_x", Type: event.Finished, At: now.Add(3 * time.Second)},
		{SessionID: "ses_outra", Type: event.SessionStarted, At: now}, // não deve vazar pra ses_x
	}
	for _, e := range evs {
		if err := st.AppendEvent(ctx, e); err != nil {
			t.Fatalf("append: %v", err)
		}
	}

	got, err := st.SessionEvents(ctx, "ses_x", 100)
	if err != nil {
		t.Fatalf("events: %v", err)
	}
	if len(got) != 4 {
		t.Fatalf("len = %d, quero 4 (só de ses_x)", len(got))
	}
	// Ordem cronológica estável por seq.
	if got[0].Type != string(event.SessionStarted) || got[3].Type != string(event.Finished) {
		t.Errorf("ordem errada: %s .. %s", got[0].Type, got[3].Type)
	}
	if got[1].Kind != event.KindUser || got[1].Data != "oi" {
		t.Errorf("evento[1] = %+v, quero user/oi", got[1])
	}
	// seq monotônico crescente.
	if !(got[0].Seq < got[1].Seq && got[1].Seq < got[2].Seq) {
		t.Errorf("seq não é monotônico: %d %d %d", got[0].Seq, got[1].Seq, got[2].Seq)
	}
}
