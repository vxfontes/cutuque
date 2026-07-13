package board

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PostgresStore é a implementação durável/consultável do board (schema cutuque).
// É a fonte da verdade: leituras são SQL. O pub/sub do WS continua em memória
// (por processo), igual ao MemStore.
type PostgresStore struct {
	pool *pgxpool.Pool
	mu   sync.RWMutex
	subs map[*Sub]struct{}
}

const boardSchemaSQL = `
CREATE SCHEMA IF NOT EXISTS cutuque;
CREATE TABLE IF NOT EXISTS cutuque.board_tasks (
    id            TEXT PRIMARY KEY,
    title         TEXT NOT NULL,
    column_name   TEXT NOT NULL,
    group_name    TEXT NOT NULL DEFAULT '',
    session       TEXT NOT NULL DEFAULT '',
    type          TEXT NOT NULL DEFAULT '',
    role          TEXT NOT NULL DEFAULT '',
    description   TEXT NOT NULL DEFAULT '',
    encalhada     BOOLEAN NOT NULL DEFAULT false,
    archived_week TEXT,
    created_at    TIMESTAMPTZ NOT NULL,
    updated_at    TIMESTAMPTZ NOT NULL,
    started_at    TIMESTAMPTZ,
    reviewed_at   TIMESTAMPTZ,
    ended_at      TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS board_tasks_archived_idx ON cutuque.board_tasks (archived_week);
CREATE INDEX IF NOT EXISTS board_tasks_scope_idx ON cutuque.board_tasks (group_name, session);
CREATE TABLE IF NOT EXISTS cutuque.board_comments (
    id         BIGSERIAL PRIMARY KEY,
    task_id    TEXT NOT NULL REFERENCES cutuque.board_tasks(id) ON DELETE CASCADE,
    author     TEXT NOT NULL DEFAULT '',
    body       TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS board_comments_task_idx ON cutuque.board_comments (task_id, created_at);
CREATE TABLE IF NOT EXISTS cutuque.board_activity (
    id      BIGSERIAL PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES cutuque.board_tasks(id) ON DELETE CASCADE,
    actor   TEXT NOT NULL DEFAULT '',
    action  TEXT NOT NULL DEFAULT '',
    at      TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS board_activity_task_idx ON cutuque.board_activity (task_id, at);
`

// OpenPostgres conecta, roda o schema idempotente e devolve o store. Erro → o
// chamador cai no fallback (MemStore/JSON), sem derrubar o boot.
func OpenPostgres(ctx context.Context, url string) (*PostgresStore, error) {
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	pool, err := pgxpool.New(cctx, url)
	if err != nil {
		return nil, fmt.Errorf("board: conectar no postgres: %w", err)
	}
	if err := pool.Ping(cctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("board: ping no postgres: %w", err)
	}
	if _, err := pool.Exec(cctx, boardSchemaSQL); err != nil {
		pool.Close()
		return nil, fmt.Errorf("board: aplicar schema: %w", err)
	}
	return &PostgresStore{pool: pool, subs: make(map[*Sub]struct{})}, nil
}

func (s *PostgresStore) Close() {
	if s.pool != nil {
		s.pool.Close()
	}
}

// Count devolve quantos cards existem (ativos + arquivados). Usado pelo import
// idempotente pra saber se o board já foi populado.
func (s *PostgresStore) Count() (int, error) {
	ctx, cancel := s.ctx()
	defer cancel()
	var n int
	err := s.pool.QueryRow(ctx, `SELECT count(*) FROM cutuque.board_tasks`).Scan(&n)
	return n, err
}

func (s *PostgresStore) ctx() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 8*time.Second)
}

const taskCols = `id, title, column_name, group_name, session, type, role, description,
	encalhada, created_at, updated_at, started_at, reviewed_at, ended_at`

func scanTask(row pgx.Row) (Task, error) {
	var t Task
	err := row.Scan(&t.ID, &t.Title, &t.Column, &t.Group, &t.Session, &t.Type, &t.Role,
		&t.Description, &t.Encalhada, &t.CreatedAt, &t.UpdatedAt, &t.StartedAt, &t.ReviewedAt, &t.EndedAt)
	return t, err
}

// attach preenche Comments e Activity dos tasks dados (2 queries por lote).
func (s *PostgresStore) attach(ctx context.Context, tasks []Task) []Task {
	if len(tasks) == 0 {
		return tasks
	}
	idx := make(map[string]int, len(tasks))
	ids := make([]string, len(tasks))
	for i := range tasks {
		idx[tasks[i].ID] = i
		ids[i] = tasks[i].ID
	}
	// comentários
	if rows, err := s.pool.Query(ctx, `SELECT task_id, author, body, created_at
		FROM cutuque.board_comments WHERE task_id = ANY($1) ORDER BY created_at ASC, id ASC`, ids); err == nil {
		defer rows.Close()
		for rows.Next() {
			var tid string
			var c Comment
			if rows.Scan(&tid, &c.Author, &c.Text, &c.CreatedAt) == nil {
				if i, ok := idx[tid]; ok {
					tasks[i].Comments = append(tasks[i].Comments, c)
				}
			}
		}
	}
	// atividade
	if rows, err := s.pool.Query(ctx, `SELECT task_id, actor, action, at
		FROM cutuque.board_activity WHERE task_id = ANY($1) ORDER BY at ASC, id ASC`, ids); err == nil {
		defer rows.Close()
		for rows.Next() {
			var tid string
			var a Activity
			if rows.Scan(&tid, &a.Actor, &a.Action, &a.At) == nil {
				if i, ok := idx[tid]; ok {
					tasks[i].Activity = append(tasks[i].Activity, a)
				}
			}
		}
	}
	return tasks
}

func (s *PostgresStore) List() []Task {
	ctx, cancel := s.ctx()
	defer cancel()
	rows, err := s.pool.Query(ctx, `SELECT `+taskCols+`
		FROM cutuque.board_tasks WHERE archived_week IS NULL ORDER BY created_at ASC`)
	if err != nil {
		log.Printf("board pg: List: %v", err)
		return []Task{}
	}
	defer rows.Close()
	var out []Task
	for rows.Next() {
		t, err := scanTask(rows)
		if err != nil {
			log.Printf("board pg: scan: %v", err)
			continue
		}
		out = append(out, t)
	}
	return s.attach(ctx, out)
}

func (s *PostgresStore) Get(id string) (Task, bool) {
	ctx, cancel := s.ctx()
	defer cancel()
	return s.getCtx(ctx, id)
}

func (s *PostgresStore) getCtx(ctx context.Context, id string) (Task, bool) {
	t, err := scanTask(s.pool.QueryRow(ctx, `SELECT `+taskCols+` FROM cutuque.board_tasks WHERE id=$1`, id))
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			log.Printf("board pg: Get: %v", err)
		}
		return Task{}, false
	}
	got := s.attach(ctx, []Task{t})
	return got[0], true
}

func (s *PostgresStore) Add(n NewTask) Task {
	ctx, cancel := s.ctx()
	defer cancel()
	now := time.Now()
	actor := n.Role
	if actor == "" {
		actor = n.Type
	}
	id := newID()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		log.Printf("board pg: Add begin: %v", err)
		return Task{}
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `INSERT INTO cutuque.board_tasks
		(id, title, column_name, group_name, session, type, role, description, created_at, updated_at)
		VALUES ($1,$2,'a_fazer',$3,$4,$5,$6,$7,$8,$8)`,
		id, n.Title, n.Group, n.Session, n.Type, n.Role, n.Description, now); err != nil {
		log.Printf("board pg: Add insert: %v", err)
		return Task{}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO cutuque.board_activity (task_id, actor, action, at)
		VALUES ($1,$2,'criou o card',$3)`, id, actorOr(actor), now); err != nil {
		log.Printf("board pg: Add activity: %v", err)
		return Task{}
	}
	if err := tx.Commit(ctx); err != nil {
		log.Printf("board pg: Add commit: %v", err)
		return Task{}
	}
	t, _ := s.getCtx(ctx, id)
	s.broadcast(t)
	return t
}

func (s *PostgresStore) Update(id string, column, title, description, role *string, actor string) (Task, bool) {
	if column != nil && !ValidColumn(*column) {
		return Task{}, false
	}
	ctx, cancel := s.ctx()
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		log.Printf("board pg: Update begin: %v", err)
		return Task{}, false
	}
	defer tx.Rollback(ctx)

	// trava a linha e lê o estado atual
	var curCol string
	var started, reviewed, ended *time.Time
	err = tx.QueryRow(ctx, `SELECT column_name, started_at, reviewed_at, ended_at
		FROM cutuque.board_tasks WHERE id=$1 FOR UPDATE`, id).Scan(&curCol, &started, &reviewed, &ended)
	if err != nil {
		return Task{}, false
	}
	now := time.Now()

	if column != nil {
		if *column != curCol {
			label := colLabelPT[*column]
			if label == "" {
				label = *column
			}
			if _, err := tx.Exec(ctx, `INSERT INTO cutuque.board_activity (task_id, actor, action, at)
				VALUES ($1,$2,$3,$4)`, id, actorOr(actor), "moveu para "+label, now); err != nil {
				log.Printf("board pg: Update activity: %v", err)
				return Task{}, false
			}
		}
		// datas derivadas na 1ª entrada em cada estágio
		if *column == "em_progresso" && started == nil {
			started = &now
		}
		if *column == "em_revisao" && reviewed == nil {
			reviewed = &now
		}
		if *column == "concluido" && ended == nil {
			ended = &now
		}
		// qualquer movimentação explícita limpa a marca de encalhada
		if _, err := tx.Exec(ctx, `UPDATE cutuque.board_tasks
			SET column_name=$2, encalhada=false, started_at=$3, reviewed_at=$4, ended_at=$5, updated_at=$6
			WHERE id=$1`, id, *column, started, reviewed, ended, now); err != nil {
			log.Printf("board pg: Update column: %v", err)
			return Task{}, false
		}
	}
	if title != nil {
		if _, err := tx.Exec(ctx, `UPDATE cutuque.board_tasks SET title=$2, updated_at=$3 WHERE id=$1`, id, *title, now); err != nil {
			return Task{}, false
		}
	}
	if description != nil {
		if _, err := tx.Exec(ctx, `UPDATE cutuque.board_tasks SET description=$2, updated_at=$3 WHERE id=$1`, id, *description, now); err != nil {
			return Task{}, false
		}
	}
	if role != nil {
		if _, err := tx.Exec(ctx, `UPDATE cutuque.board_tasks SET role=$2, updated_at=$3 WHERE id=$1`, id, *role, now); err != nil {
			return Task{}, false
		}
	}
	if err := tx.Commit(ctx); err != nil {
		log.Printf("board pg: Update commit: %v", err)
		return Task{}, false
	}
	t, ok := s.getCtx(ctx, id)
	if ok {
		s.broadcast(t)
	}
	return t, ok
}

func (s *PostgresStore) SetEncalhada(id string, v bool, actor string) (Task, bool) {
	ctx, cancel := s.ctx()
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Task{}, false
	}
	defer tx.Rollback(ctx)
	var cur bool
	if err := tx.QueryRow(ctx, `SELECT encalhada FROM cutuque.board_tasks WHERE id=$1 FOR UPDATE`, id).Scan(&cur); err != nil {
		return Task{}, false
	}
	now := time.Now()
	if v != cur {
		action := "reativou o card"
		if v {
			action = "marcou como encalhada"
		}
		if _, err := tx.Exec(ctx, `INSERT INTO cutuque.board_activity (task_id, actor, action, at)
			VALUES ($1,$2,$3,$4)`, id, actorOr(actor), action, now); err != nil {
			return Task{}, false
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE cutuque.board_tasks SET encalhada=$2, updated_at=$3 WHERE id=$1`, id, v, now); err != nil {
		return Task{}, false
	}
	if err := tx.Commit(ctx); err != nil {
		return Task{}, false
	}
	t, ok := s.getCtx(ctx, id)
	if ok {
		s.broadcast(t)
	}
	return t, ok
}

func (s *PostgresStore) AddComment(id, author, text string) (Task, bool) {
	ctx, cancel := s.ctx()
	defer cancel()
	now := time.Now()
	ct, err := s.pool.Exec(ctx, `INSERT INTO cutuque.board_comments (task_id, author, body, created_at)
		SELECT $1,$2,$3,$4 WHERE EXISTS (SELECT 1 FROM cutuque.board_tasks WHERE id=$1)`,
		id, author, text, now)
	if err != nil {
		log.Printf("board pg: AddComment: %v", err)
		return Task{}, false
	}
	if ct.RowsAffected() == 0 {
		return Task{}, false // task não existe
	}
	_, _ = s.pool.Exec(ctx, `UPDATE cutuque.board_tasks SET updated_at=$2 WHERE id=$1`, id, now)
	t, ok := s.getCtx(ctx, id)
	if ok {
		s.broadcast(t)
	}
	return t, ok
}

func (s *PostgresStore) Remove(id string) bool {
	ctx, cancel := s.ctx()
	defer cancel()
	ct, err := s.pool.Exec(ctx, `DELETE FROM cutuque.board_tasks WHERE id=$1`, id)
	if err != nil {
		log.Printf("board pg: Remove: %v", err)
		return false
	}
	if ct.RowsAffected() == 0 {
		return false
	}
	s.broadcastRemoved(id)
	return true
}

func (s *PostgresStore) CloseWeek(now time.Time) (archived, stalled int) {
	label := weekLabel(now)
	weekStart := startOfISOWeek(now)
	ctx, cancel := s.ctx()
	defer cancel()

	var archivedIDs, stalledIDs []string
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		log.Printf("board pg: CloseWeek begin: %v", err)
		return 0, 0
	}
	defer tx.Rollback(ctx)

	rows, err := tx.Query(ctx, `UPDATE cutuque.board_tasks SET archived_week=$1
		WHERE column_name='concluido' AND archived_week IS NULL RETURNING id`, label)
	if err == nil {
		for rows.Next() {
			var id string
			if rows.Scan(&id) == nil {
				archivedIDs = append(archivedIDs, id)
			}
		}
		rows.Close()
	}
	rows2, err := tx.Query(ctx, `UPDATE cutuque.board_tasks SET encalhada=true, updated_at=$2
		WHERE column_name='a_fazer' AND NOT encalhada AND archived_week IS NULL AND created_at < $1
		RETURNING id`, weekStart, now)
	if err == nil {
		for rows2.Next() {
			var id string
			if rows2.Scan(&id) == nil {
				stalledIDs = append(stalledIDs, id)
			}
		}
		rows2.Close()
	}
	if err := tx.Commit(ctx); err != nil {
		log.Printf("board pg: CloseWeek commit: %v", err)
		return 0, 0
	}
	for _, id := range archivedIDs {
		s.broadcastRemoved(id)
	}
	for _, id := range stalledIDs {
		if t, ok := s.getCtx(ctx, id); ok {
			s.broadcast(t)
		}
	}
	return len(archivedIDs), len(stalledIDs)
}

func (s *PostgresStore) ArchivedWeeks() []ArchivedWeek {
	ctx, cancel := s.ctx()
	defer cancel()
	rows, err := s.pool.Query(ctx, `SELECT `+taskCols+`, archived_week
		FROM cutuque.board_tasks WHERE archived_week IS NOT NULL
		ORDER BY archived_week DESC, created_at ASC`)
	if err != nil {
		log.Printf("board pg: ArchivedWeeks: %v", err)
		return []ArchivedWeek{}
	}
	defer rows.Close()
	order := []string{}
	byWeek := map[string][]Task{}
	for rows.Next() {
		var t Task
		var wk string
		if err := rows.Scan(&t.ID, &t.Title, &t.Column, &t.Group, &t.Session, &t.Type, &t.Role,
			&t.Description, &t.Encalhada, &t.CreatedAt, &t.UpdatedAt, &t.StartedAt, &t.ReviewedAt, &t.EndedAt, &wk); err != nil {
			continue
		}
		if _, seen := byWeek[wk]; !seen {
			order = append(order, wk)
		}
		byWeek[wk] = append(byWeek[wk], t)
	}
	// anexa comentários/atividade de todos os arquivados (por id)
	full := map[string]Task{}
	for _, t := range s.attach(ctx, flatten(byWeek)) {
		full[t.ID] = t
	}
	out := make([]ArchivedWeek, 0, len(order))
	for _, wk := range order {
		var y, w int
		fmt.Sscanf(wk, "%d-W%d", &y, &w)
		start := isoWeekStartDate(y, w)
		tasks := make([]Task, 0, len(byWeek[wk]))
		for _, t := range byWeek[wk] {
			if ft, ok := full[t.ID]; ok {
				tasks = append(tasks, ft)
			} else {
				tasks = append(tasks, t)
			}
		}
		out = append(out, ArchivedWeek{
			Label: wk, Start: start.Format("2006-01-02"),
			End: start.AddDate(0, 0, 6).Format("2006-01-02"), Tasks: tasks,
		})
	}
	return out
}

func flatten(m map[string][]Task) []Task {
	out := []Task{}
	for _, ts := range m {
		out = append(out, ts...)
	}
	return out
}

// --- pub/sub (em memória, por processo) ---

func (s *PostgresStore) Subscribe() *Sub {
	ch := make(chan Task, subBuffer)
	rm := make(chan string, subBuffer)
	sub := &Sub{C: ch, ch: ch, Removed: rm, removedCh: rm}
	s.mu.Lock()
	s.subs[sub] = struct{}{}
	s.mu.Unlock()
	return sub
}

func (s *PostgresStore) Unsubscribe(sub *Sub) {
	s.mu.Lock()
	delete(s.subs, sub)
	s.mu.Unlock()
}

func (s *PostgresStore) broadcast(t Task) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for sub := range s.subs {
		select {
		case sub.ch <- t:
		default:
		}
	}
}

func (s *PostgresStore) broadcastRemoved(id string) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for sub := range s.subs {
		select {
		case sub.removedCh <- id:
		default:
		}
	}
}

// ImportFromJSON importa um board.json (formato do MemStore) pro Postgres.
// Idempotente por card (ON CONFLICT DO NOTHING). Use só quando o board está vazio.
// Retorna quantos cards foram vistos no arquivo.
func (s *PostgresStore) ImportFromJSON(path string) (int, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	var st diskState
	if err := json.Unmarshal(b, &st); err != nil || st.Tasks == nil {
		var tasks []Task
		if err2 := json.Unmarshal(b, &tasks); err2 != nil {
			return 0, err2
		}
		st = diskState{Tasks: tasks}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)

	n := 0
	for _, t := range st.Tasks {
		if err := insertTaskTx(ctx, tx, t, nil); err != nil {
			return 0, err
		}
		n++
	}
	for label, ts := range st.Archive {
		l := label
		for _, t := range ts {
			if err := insertTaskTx(ctx, tx, t, &l); err != nil {
				return 0, err
			}
			n++
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return n, nil
}

func insertTaskTx(ctx context.Context, tx pgx.Tx, t Task, archivedWeek *string) error {
	if _, err := tx.Exec(ctx, `INSERT INTO cutuque.board_tasks
		(id,title,column_name,group_name,session,type,role,description,encalhada,archived_week,created_at,updated_at,started_at,reviewed_at,ended_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
		ON CONFLICT (id) DO NOTHING`,
		t.ID, t.Title, t.Column, t.Group, t.Session, t.Type, t.Role, t.Description, t.Encalhada, archivedWeek,
		t.CreatedAt, t.UpdatedAt, t.StartedAt, t.ReviewedAt, t.EndedAt); err != nil {
		return err
	}
	for _, c := range t.Comments {
		if _, err := tx.Exec(ctx, `INSERT INTO cutuque.board_comments (task_id,author,body,created_at) VALUES ($1,$2,$3,$4)`,
			t.ID, c.Author, c.Text, c.CreatedAt); err != nil {
			return err
		}
	}
	for _, a := range t.Activity {
		if _, err := tx.Exec(ctx, `INSERT INTO cutuque.board_activity (task_id,actor,action,at) VALUES ($1,$2,$3,$4)`,
			t.ID, a.Actor, a.Action, a.At); err != nil {
			return err
		}
	}
	return nil
}

// ensure interface compliance
var _ Store = (*PostgresStore)(nil)
