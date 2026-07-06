// Package history persiste o histórico das sessões (metadados + event-log) no
// Postgres, para consultar sessões passadas e sua linha do tempo mesmo depois
// de saírem do registry em memória (v2.2/v2.3).
//
// O Engine — único escritor do estado — alimenta o Store via write-through
// assíncrono: cada transição vira um UpsertSession e cada evento vira um
// AppendEvent. O Store é OPCIONAL: sem CUTUQUE_DATABASE_URL o hub segue com a
// persistência JSON em disco (degradação graciosa).
package history

import (
	"context"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/event"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// StoredEvent é um evento do event-log lido de volta (com o número de sequência
// monotônico que dá a ordem cronológica estável).
type StoredEvent struct {
	Seq       int64     `json:"seq"`
	SessionID string    `json:"session_id"`
	At        time.Time `json:"at"`
	Type      string    `json:"type"`
	Kind      string    `json:"kind,omitempty"`
	Data      string    `json:"data,omitempty"`
}

// Store é a persistência do histórico. As escritas (UpsertSession/AppendEvent)
// são idempotentes o suficiente para o write-through (upsert por id; evento é
// append puro). As leituras servem a reconciliação no boot e a tela de histórico.
type Store interface {
	// UpsertSession grava/atualiza a linha da sessão (1 por id).
	UpsertSession(ctx context.Context, s session.Session) error
	// AppendEvent adiciona um evento ao log (append-only).
	AppendEvent(ctx context.Context, ev event.Event) error
	// RecentSessions lista as sessões mais recentes (tela de histórico).
	RecentSessions(ctx context.Context, limit int) ([]session.Session, error)
	// SessionEvents devolve a linha do tempo de uma sessão (ordem cronológica).
	SessionEvents(ctx context.Context, sessionID string, limit int) ([]StoredEvent, error)
	// Close libera a pool de conexões.
	Close()
}

// schemaSQL cria o schema/tabelas do histórico. Idempotente (IF NOT EXISTS):
// roda no boot toda vez, sem migration framework — o schema é pequeno e estável.
const schemaSQL = `
CREATE SCHEMA IF NOT EXISTS cutuque;

CREATE TABLE IF NOT EXISTS cutuque.sessions (
    id         text PRIMARY KEY,
    machine    text        NOT NULL DEFAULT '',
    agent      text        NOT NULL DEFAULT '',
    title      text        NOT NULL DEFAULT '',
    cwd        text        NOT NULL DEFAULT '',
    model      text        NOT NULL DEFAULT '',
    state      text        NOT NULL DEFAULT '',
    external   boolean     NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cutuque.events (
    seq        bigserial   PRIMARY KEY,
    session_id text        NOT NULL,
    at         timestamptz NOT NULL,
    type       text        NOT NULL,
    kind       text        NOT NULL DEFAULT '',
    data       text        NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS events_session_seq_idx ON cutuque.events (session_id, seq);
`
