package history

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/vxfontes/cutuque/hub/internal/event"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// openTimeout limita o connect + migração no boot para o hub não pendurar se o
// Postgres estiver fora do ar (cai no fallback JSON quem chama).
const openTimeout = 10 * time.Second

// PostgresStore implementa Store sobre um Postgres (schema `cutuque`).
type PostgresStore struct {
	pool *pgxpool.Pool
}

// Open conecta em url (CUTUQUE_DATABASE_URL), roda o schema idempotente e devolve
// o Store. Erro → o chamador cai no fallback JSON (não derruba o boot).
func Open(ctx context.Context, url string) (*PostgresStore, error) {
	ctx, cancel := context.WithTimeout(ctx, openTimeout)
	defer cancel()

	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("history: conectar no postgres: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("history: ping no postgres: %w", err)
	}
	if _, err := pool.Exec(ctx, schemaSQL); err != nil {
		pool.Close()
		return nil, fmt.Errorf("history: aplicar schema: %w", err)
	}
	return &PostgresStore{pool: pool}, nil
}

func (s *PostgresStore) Close() {
	if s.pool != nil {
		s.pool.Close()
	}
}

// UpsertSession grava a sessão (1 linha por id). created_at só é fixado na
// inserção; updates preservam o original e avançam updated_at.
func (s *PostgresStore) UpsertSession(ctx context.Context, sess session.Session) error {
	const q = `
INSERT INTO cutuque.sessions (id, machine, agent, title, cwd, model, state, external, created_at, updated_at)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
ON CONFLICT (id) DO UPDATE SET
    machine=EXCLUDED.machine, agent=EXCLUDED.agent, title=EXCLUDED.title,
    cwd=EXCLUDED.cwd, model=EXCLUDED.model, state=EXCLUDED.state,
    external=EXCLUDED.external, updated_at=EXCLUDED.updated_at`
	created := sess.CreatedAt
	if created.IsZero() {
		created = time.Now()
	}
	updated := sess.UpdatedAt
	if updated.IsZero() {
		updated = time.Now()
	}
	_, err := s.pool.Exec(ctx, q,
		sess.ID, sess.Machine, sess.Agent, sess.Title, sess.Cwd, sess.Model,
		string(sess.State), sess.External, created, updated)
	return err
}

// AppendEvent adiciona um evento ao log (append puro).
func (s *PostgresStore) AppendEvent(ctx context.Context, ev event.Event) error {
	at := ev.At
	if at.IsZero() {
		at = time.Now()
	}
	const q = `INSERT INTO cutuque.events (session_id, at, type, kind, data) VALUES ($1,$2,$3,$4,$5)`
	_, err := s.pool.Exec(ctx, q, ev.SessionID, at, string(ev.Type), ev.Kind, ev.Data)
	return err
}

// RecentSessions lista as sessões mais recentes primeiro.
func (s *PostgresStore) RecentSessions(ctx context.Context, limit int) ([]session.Session, error) {
	if limit <= 0 {
		limit = 100
	}
	const q = `
SELECT id, machine, agent, title, cwd, model, state, external, created_at, updated_at
FROM cutuque.sessions ORDER BY updated_at DESC LIMIT $1`
	rows, err := s.pool.Query(ctx, q, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []session.Session
	for rows.Next() {
		var sess session.Session
		var st string
		if err := rows.Scan(&sess.ID, &sess.Machine, &sess.Agent, &sess.Title,
			&sess.Cwd, &sess.Model, &st, &sess.External, &sess.CreatedAt, &sess.UpdatedAt); err != nil {
			return nil, err
		}
		sess.State = session.State(st)
		out = append(out, sess)
	}
	return out, rows.Err()
}

// SessionEvents devolve a linha do tempo (mais antigo → mais novo) de uma sessão.
func (s *PostgresStore) SessionEvents(ctx context.Context, sessionID string, limit int) ([]StoredEvent, error) {
	if limit <= 0 {
		limit = 1000
	}
	const q = `
SELECT seq, session_id, at, type, kind, data
FROM cutuque.events WHERE session_id=$1 ORDER BY seq ASC LIMIT $2`
	rows, err := s.pool.Query(ctx, q, sessionID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []StoredEvent
	for rows.Next() {
		var e StoredEvent
		if err := rows.Scan(&e.Seq, &e.SessionID, &e.At, &e.Type, &e.Kind, &e.Data); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
