// Package board mantém o quadro Kanban dos agentes: fonte da verdade das
// tarefas (Task) conhecidas pelo hub. Thread-safe, com persistência JSON
// opcional e pub/sub para o WebSocket (espelha o padrão de internal/registry).
package board

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"sort"
	"sync"
	"time"
)

// Columns são as colunas do quadro, na ordem do fluxo.
var Columns = []string{"a_fazer", "em_progresso", "feito", "em_revisao", "concluido"}

// ValidColumn diz se c é uma coluna conhecida.
func ValidColumn(c string) bool {
	for _, x := range Columns {
		if x == c {
			return true
		}
	}
	return false
}

// Task é um card do quadro.
type Task struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	Column    string    `json:"column"`
	Group     string    `json:"group"`
	Session   string    `json:"session"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

const subBuffer = 32

// Sub é a inscrição de um interessado nas mudanças do quadro.
type Sub struct {
	C         <-chan Task
	ch        chan Task
	Removed   <-chan string
	removedCh chan string
}

// Store guarda as tarefas em memória de forma thread-safe, com persistência
// JSON opcional (path != "").
type Store struct {
	mu        sync.RWMutex
	byID      map[string]Task
	subs      map[*Sub]struct{}
	path      string
	persistMu sync.Mutex
}

func New() *Store {
	return &Store{byID: make(map[string]Task), subs: make(map[*Sub]struct{})}
}

func NewAt(path string) *Store {
	s := New()
	s.path = path
	s.load()
	return s
}

func newID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func (s *Store) load() {
	if s.path == "" {
		return
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		return // best-effort
	}
	var tasks []Task
	if json.Unmarshal(b, &tasks) != nil {
		return
	}
	s.mu.Lock()
	for _, t := range tasks {
		s.byID[t.ID] = t
	}
	s.mu.Unlock()
}

func (s *Store) persist() {
	if s.path == "" {
		return
	}
	s.persistMu.Lock()
	defer s.persistMu.Unlock()
	tasks := s.List()
	b, err := json.MarshalIndent(tasks, "", " ")
	if err != nil {
		return
	}
	tmp := s.path + ".tmp"
	if os.WriteFile(tmp, b, 0o644) == nil {
		_ = os.Rename(tmp, s.path)
	}
}

func (s *Store) List() []Task {
	s.mu.RLock()
	out := make([]Task, 0, len(s.byID))
	for _, t := range s.byID {
		out = append(out, t)
	}
	s.mu.RUnlock()
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out
}

func (s *Store) Get(id string) (Task, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	t, ok := s.byID[id]
	return t, ok
}

func (s *Store) Add(title, group, session string) Task {
	now := time.Now()
	t := Task{ID: newID(), Title: title, Column: "a_fazer", Group: group, Session: session, CreatedAt: now, UpdatedAt: now}
	s.mu.Lock()
	s.byID[t.ID] = t
	s.mu.Unlock()
	s.persist()
	s.broadcast(t)
	return t
}

// Update altera coluna e/ou título (ponteiros nil = não mexe). Retorna a task
// atualizada e ok=false se o id não existir ou a coluna for inválida.
func (s *Store) Update(id string, column, title *string) (Task, bool) {
	if column != nil && !ValidColumn(*column) {
		return Task{}, false
	}
	s.mu.Lock()
	t, ok := s.byID[id]
	if !ok {
		s.mu.Unlock()
		return Task{}, false
	}
	if column != nil {
		t.Column = *column
	}
	if title != nil {
		t.Title = *title
	}
	t.UpdatedAt = time.Now()
	s.byID[id] = t
	s.mu.Unlock()
	s.persist()
	s.broadcast(t)
	return t, true
}

func (s *Store) Remove(id string) bool {
	s.mu.Lock()
	_, ok := s.byID[id]
	if ok {
		delete(s.byID, id)
	}
	s.mu.Unlock()
	if ok {
		s.persist()
		s.broadcastRemoved(id)
	}
	return ok
}

func (s *Store) Subscribe() *Sub {
	ch := make(chan Task, subBuffer)
	rm := make(chan string, subBuffer)
	sub := &Sub{C: ch, ch: ch, Removed: rm, removedCh: rm}
	s.mu.Lock()
	s.subs[sub] = struct{}{}
	s.mu.Unlock()
	return sub
}

func (s *Store) Unsubscribe(sub *Sub) {
	s.mu.Lock()
	delete(s.subs, sub)
	s.mu.Unlock()
}

func (s *Store) broadcast(t Task) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for sub := range s.subs {
		select {
		case sub.ch <- t:
		default: // subscriber lento: descarta (recupera no snapshot)
		}
	}
}

func (s *Store) broadcastRemoved(id string) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for sub := range s.subs {
		select {
		case sub.removedCh <- id:
		default:
		}
	}
}
