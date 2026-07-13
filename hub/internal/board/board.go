// Package board mantém o quadro Kanban dos agentes: fonte da verdade das
// tarefas (Task) conhecidas pelo hub. Thread-safe, com persistência JSON
// opcional e pub/sub para o WebSocket (espelha o padrão de internal/registry).
package board

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"sort"
	"sync"
	"time"
)

// Columns são as colunas do quadro, na ordem do fluxo.
var Columns = []string{"a_fazer", "em_progresso", "feito", "em_revisao", "concluido"}

// ValidColumn diz se c é uma coluna conhecida.
func ValidColumn(c string) bool {
	return slices.Contains(Columns, c)
}

// Task é um card do quadro.
type Task struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	Column    string    `json:"column"`
	Group     string    `json:"group"`
	Session   string    `json:"session"`
	// Type é o tipo do agente que criou o card (claude|codex|opencode|""), a 3ª
	// tag de identificação/filtro (além de group e session).
	Type string `json:"type,omitempty"`
	// Role é quem está fazendo (sub-agente/orquestrador: luka, ludmilla, marcus…).
	Role string `json:"role,omitempty"`
	// Encalhada = card em a_fazer que sobreviveu a ≥1 fechamento sem ser iniciado.
	// Setado no CloseWeek; limpo em qualquer movimentação. O dashboard mostra numa
	// coluna de alerta à esquerda do board.
	Encalhada bool `json:"encalhada,omitempty"`
	// Description é o texto longo do que está sendo feito (detalhe do card).
	Description string `json:"description,omitempty"`
	// Comments são as observações que os agentes (e a usuária) vão adicionando.
	Comments []Comment `json:"comments,omitempty"`
	// StartedAt/ReviewedAt/EndedAt são derivados internamente na 1ª entrada em
	// em_progresso / em_revisao / concluido. Nulos até lá.
	StartedAt  *time.Time `json:"started_at,omitempty"`
	ReviewedAt *time.Time `json:"reviewed_at,omitempty"`
	EndedAt    *time.Time `json:"ended_at,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	UpdatedAt  time.Time  `json:"updated_at"`
}

// Comment é uma observação num card: autor (role/quem) + texto + quando.
type Comment struct {
	Author    string    `json:"author"`
	Text      string    `json:"text"`
	CreatedAt time.Time `json:"created_at"`
}

// NewTask são os campos para criar um card (evita explosão de parâmetros posicionais).
type NewTask struct {
	Title, Group, Session, Type, Role, Description string
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
	// archive guarda os cards concluídos arquivados no fechamento semanal,
	// agrupados por rótulo de semana (ex.: "2026-W28"). Saem do board ativo.
	archive   map[string][]Task
	path      string
	persistMu sync.Mutex
}

func New() *Store {
	return &Store{byID: make(map[string]Task), subs: make(map[*Sub]struct{}), archive: make(map[string][]Task)}
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

// diskState é o formato em disco: cards ativos + arquivo por semana.
type diskState struct {
	Tasks   []Task            `json:"tasks"`
	Archive map[string][]Task `json:"archive,omitempty"`
}

func (s *Store) load() {
	if s.path == "" {
		return
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		return // best-effort
	}
	var st diskState
	if json.Unmarshal(b, &st) != nil || st.Tasks == nil {
		// Retrocompat: formato antigo era um array de Task cru.
		var tasks []Task
		if json.Unmarshal(b, &tasks) != nil {
			return
		}
		st = diskState{Tasks: tasks}
	}
	s.mu.Lock()
	for _, t := range st.Tasks {
		s.byID[t.ID] = t
	}
	if st.Archive != nil {
		s.archive = st.Archive
	}
	s.mu.Unlock()
}

func (s *Store) persist() {
	if s.path == "" {
		return
	}
	s.persistMu.Lock()
	defer s.persistMu.Unlock()
	s.mu.RLock()
	st := diskState{Tasks: make([]Task, 0, len(s.byID)), Archive: s.archive}
	for _, t := range s.byID {
		st.Tasks = append(st.Tasks, t)
	}
	s.mu.RUnlock()
	sort.Slice(st.Tasks, func(i, j int) bool { return st.Tasks[i].CreatedAt.Before(st.Tasks[j].CreatedAt) })
	b, err := json.MarshalIndent(st, "", " ")
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

// weekLabel devolve o rótulo ISO da semana de t (ex.: "2026-W28").
func weekLabel(t time.Time) string {
	y, w := t.ISOWeek()
	return fmt.Sprintf("%d-W%02d", y, w)
}

// startOfISOWeek devolve a segunda-feira 00:00 (na loc de t) da semana de t.
func startOfISOWeek(t time.Time) time.Time {
	wd := int(t.Weekday())
	if wd == 0 {
		wd = 7 // domingo
	}
	d := time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, t.Location())
	return d.AddDate(0, 0, -(wd - 1))
}

// isoWeekStartDate devolve a segunda-feira (UTC) do início de uma semana ISO.
func isoWeekStartDate(year, week int) time.Time {
	jan4 := time.Date(year, 1, 4, 0, 0, 0, 0, time.UTC)
	wd := int(jan4.Weekday())
	if wd == 0 {
		wd = 7
	}
	week1Mon := jan4.AddDate(0, 0, -(wd - 1))
	return week1Mon.AddDate(0, 0, (week-1)*7)
}

// CloseWeek arquiva os cards concluídos na semana de `now` e marca como encalhada
// os a_fazer que já existiam antes do início dessa semana. Retorna as contagens.
func (s *Store) CloseWeek(now time.Time) (archived, stalled int) {
	label := weekLabel(now)
	weekStart := startOfISOWeek(now)
	var removed []string
	var updated []Task
	s.mu.Lock()
	for id, t := range s.byID {
		switch {
		case t.Column == "concluido":
			s.archive[label] = append(s.archive[label], t)
			delete(s.byID, id)
			removed = append(removed, id)
			archived++
		case t.Column == "a_fazer" && !t.Encalhada && t.CreatedAt.Before(weekStart):
			t.Encalhada = true
			s.byID[id] = t
			updated = append(updated, t)
			stalled++
		}
	}
	s.mu.Unlock()
	if archived > 0 || stalled > 0 {
		s.persist()
	}
	for _, id := range removed {
		s.broadcastRemoved(id)
	}
	for _, t := range updated {
		s.broadcast(t)
	}
	return archived, stalled
}

// ArchivedWeek é uma semana do arquivo, para exibição.
type ArchivedWeek struct {
	Label string `json:"label"`
	Start string `json:"start"`
	End   string `json:"end"`
	Tasks []Task `json:"tasks"`
}

// ArchivedWeeks devolve o arquivo agrupado por semana, mais recente primeiro.
func (s *Store) ArchivedWeeks() []ArchivedWeek {
	s.mu.RLock()
	labels := make([]string, 0, len(s.archive))
	cp := make(map[string][]Task, len(s.archive))
	for l, ts := range s.archive {
		labels = append(labels, l)
		cp[l] = append([]Task(nil), ts...)
	}
	s.mu.RUnlock()
	sort.Sort(sort.Reverse(sort.StringSlice(labels))) // 2026-W28 antes de W27
	out := make([]ArchivedWeek, 0, len(labels))
	for _, l := range labels {
		var y, w int
		fmt.Sscanf(l, "%d-W%d", &y, &w)
		start := isoWeekStartDate(y, w)
		out = append(out, ArchivedWeek{
			Label: l, Start: start.Format("2006-01-02"),
			End: start.AddDate(0, 0, 6).Format("2006-01-02"), Tasks: cp[l],
		})
	}
	return out
}

// StartWeeklyCloser dispara CloseWeek automaticamente todo domingo 23:59 na loc.
func StartWeeklyCloser(s *Store, loc *time.Location) {
	go func() {
		for {
			time.Sleep(time.Until(nextSundayClose(time.Now().In(loc))))
			s.CloseWeek(time.Now().In(loc))
		}
	}()
}

// nextSundayClose devolve o próximo domingo 23:59 (na loc de now).
func nextSundayClose(now time.Time) time.Time {
	daysUntilSun := (7 - int(now.Weekday())) % 7 // domingo = 0
	cand := time.Date(now.Year(), now.Month(), now.Day(), 23, 59, 0, 0, now.Location()).AddDate(0, 0, daysUntilSun)
	if !cand.After(now) {
		cand = cand.AddDate(0, 0, 7)
	}
	return cand
}

func (s *Store) Add(n NewTask) Task {
	now := time.Now()
	t := Task{
		ID: newID(), Title: n.Title, Column: "a_fazer",
		Group: n.Group, Session: n.Session, Type: n.Type, Role: n.Role, Description: n.Description,
		CreatedAt: now, UpdatedAt: now,
	}
	s.mu.Lock()
	s.byID[t.ID] = t
	s.mu.Unlock()
	s.persist()
	s.broadcast(t)
	return t
}

// Update altera coluna e/ou título (ponteiros nil = não mexe). Retorna a task
// atualizada e ok=false se o id não existir ou a coluna for inválida.
func (s *Store) Update(id string, column, title, description, role *string) (Task, bool) {
	if column != nil && !ValidColumn(*column) {
		return Task{}, false
	}
	s.mu.Lock()
	t, ok := s.byID[id]
	if !ok {
		s.mu.Unlock()
		return Task{}, false
	}
	now := time.Now()
	if column != nil {
		t.Column = *column
		// Qualquer movimentação explícita limpa a marca de encalhada — alguém tocou
		// no card (seja iniciando o trabalho ou "revivendo" de volta pra A fazer).
		t.Encalhada = false
		// Datas derivadas na 1ª entrada em cada estágio.
		if *column == "em_progresso" && t.StartedAt == nil {
			t.StartedAt = &now
		}
		if *column == "em_revisao" && t.ReviewedAt == nil {
			t.ReviewedAt = &now
		}
		if *column == "concluido" && t.EndedAt == nil {
			t.EndedAt = &now
		}
	}
	if title != nil {
		t.Title = *title
	}
	if description != nil {
		t.Description = *description
	}
	if role != nil {
		t.Role = *role
	}
	t.UpdatedAt = now
	s.byID[id] = t
	s.mu.Unlock()
	s.persist()
	s.broadcast(t)
	return t, true
}

// SetEncalhada marca/desmarca um card como encalhado manualmente (arrastar para a
// coluna Encalhadas no dashboard). Retorna a task atualizada e ok=false se o id
// não existir.
func (s *Store) SetEncalhada(id string, v bool) (Task, bool) {
	s.mu.Lock()
	t, ok := s.byID[id]
	if !ok {
		s.mu.Unlock()
		return Task{}, false
	}
	t.Encalhada = v
	t.UpdatedAt = time.Now()
	s.byID[id] = t
	s.mu.Unlock()
	s.persist()
	s.broadcast(t)
	return t, true
}

// AddComment adiciona uma observação ao card. Retorna a task atualizada e
// ok=false se o id não existir.
func (s *Store) AddComment(id, author, text string) (Task, bool) {
	s.mu.Lock()
	t, ok := s.byID[id]
	if !ok {
		s.mu.Unlock()
		return Task{}, false
	}
	now := time.Now()
	t.Comments = append(t.Comments, Comment{Author: author, Text: text, CreatedAt: now})
	t.UpdatedAt = now
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

// broadcast entrega best-effort e sem ordenação garantida (igual ao registry):
// envio não-bloqueante, e como roda fora de s.mu a ordem entre eventos de ids
// diferentes/iguais não é garantida. Consumidores são idempotentes por id e
// recuperam o estado completo no snapshot ao (re)conectar.
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

// broadcastRemoved segue a mesma semântica best-effort de broadcast (ver
// comentário acima).
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
