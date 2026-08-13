// Package board mantém o quadro Kanban dos agentes: fonte da verdade das
// tarefas (Task) conhecidas pelo hub. Thread-safe, com persistência JSON
// opcional e pub/sub para o WebSocket (espelha o padrão de internal/registry).
package board

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"slices"
	"sort"
	"strings"
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
	// Archived é transitório: só preenchido nos resultados de Search para o card
	// arquivado (não é persistido; o arquivo real é o archived_week/archive).
	Archived bool `json:"archived,omitempty"`
	// Description é o texto longo do que está sendo feito (detalhe do card).
	Description string `json:"description,omitempty"`
	// Comments são as observações que os agentes (e a usuária) vão adicionando.
	Comments []Comment `json:"comments,omitempty"`
	// Activity é o histórico de ações no card (criou, moveu, encalhou…).
	Activity []Activity `json:"activity,omitempty"`
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

// Activity é uma entrada do histórico do card: quem fez o quê e quando (ex.:
// "marcus moveu para Em progresso"). Alimenta o log de atividade no detalhe.
type Activity struct {
	Actor  string    `json:"actor"`
	Action string    `json:"action"`
	At     time.Time `json:"at"`
}

// colLabelPT mapeia a coluna para o rótulo pt-BR usado no log de atividade.
var colLabelPT = map[string]string{
	"a_fazer": "A fazer", "em_progresso": "Em progresso", "feito": "Feito",
	"em_revisao": "Em revisão", "concluido": "Concluído",
}

// actorOr devolve o ator ou "?" quando vazio (cliente antigo sem actor).
func actorOr(a string) string {
	if a == "" {
		return "?"
	}
	return a
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

// Store é a fonte da verdade do quadro. Duas implementações: MemStore (memória +
// JSON, para dev/testes) e PostgresStore (durável/consultável, para produção). Os
// handlers e o WS dependem só desta interface.
type Store interface {
	List() []Task
	Get(id string) (Task, bool)
	Add(n NewTask) Task
	Update(id string, column, title, description, role *string, actor string) (Task, bool)
	SetEncalhada(id string, v bool, actor string) (Task, bool)
	AddComment(id, author, text string) (Task, bool)
	Remove(id string) bool
	// CloseWeek arquiva os concluídos. `week` vazio = a semana de `now` (é o que
	// o fechamento automático de domingo usa); preenchido, arquiva NAQUELE rótulo
	// — é como o trabalho de madrugada de segunda entra na semana que acabou.
	CloseWeek(now time.Time, week string) (archived, stalled int)
	// CloseOptions são as semanas candidatas a receber o próximo fechamento.
	CloseOptions(now time.Time) CloseOptions
	ArchivedWeeks() []ArchivedWeek
	// Search acha cards (ativos E arquivados) cujo título, descrição OU algum
	// comentário contenha q (case-insensitive). Nos arquivados, Archived=true.
	Search(q string) []Task
	Subscribe() *Sub
	Unsubscribe(sub *Sub)
}

// MemStore guarda as tarefas em memória de forma thread-safe, com persistência
// JSON opcional (path != "").
type MemStore struct {
	mu        sync.RWMutex
	byID      map[string]Task
	subs      map[*Sub]struct{}
	// archive guarda os cards concluídos arquivados no fechamento semanal,
	// agrupados por rótulo de semana (ex.: "2026-W28"). Saem do board ativo.
	archive   map[string][]Task
	path      string
	persistMu sync.Mutex
}

func New() *MemStore {
	return &MemStore{byID: make(map[string]Task), subs: make(map[*Sub]struct{}), archive: make(map[string][]Task)}
}

func NewAt(path string) *MemStore {
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

func (s *MemStore) load() {
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

func (s *MemStore) persist() {
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

func (s *MemStore) List() []Task {
	s.mu.RLock()
	out := make([]Task, 0, len(s.byID))
	for _, t := range s.byID {
		out = append(out, t)
	}
	s.mu.RUnlock()
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out
}

func (s *MemStore) Get(id string) (Task, bool) {
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

// weekStartFor devolve a segunda-feira 00:00 (na loc de now) da semana rotulada
// por `label`, junto do rótulo efetivamente usado. Rótulo vazio ou malformado cai
// na semana de `now` — o chamador HTTP já valida, isto é o cinto de segurança
// para não gravar um arquivo em "0000-W00".
func weekStartFor(label string, now time.Time) (time.Time, string) {
	var y, w int
	if n, err := fmt.Sscanf(label, "%d-W%d", &y, &w); n != 2 || err != nil ||
		y < 2000 || y > 9999 || w < 1 || w > 53 {
		return startOfISOWeek(now), weekLabel(now)
	}
	d := isoWeekStartDate(y, w)
	return time.Date(d.Year(), d.Month(), d.Day(), 0, 0, 0, 0, now.Location()), label
}

// weekCutoffFor devolve o FIM da semana rotulada — a segunda-feira 00:00
// seguinte, limite EXCLUSIVO — junto do rótulo usado. É o corte da encalhada:
// entra tudo que nasceu em qualquer momento dentro da semana fechada; fica de
// fora o que nasceu depois dela (o card das 00:30 da segunda, quando o
// fechamento da semana anterior roda de madrugada, é da semana nova).
func weekCutoffFor(label string, now time.Time) (time.Time, string) {
	start, usado := weekStartFor(label, now)
	return start.AddDate(0, 0, 7), usado
}

// CloseWeek arquiva os cards concluídos e marca como encalhada os a_fazer que
// atravessaram a semana fechada sem nunca sair da coluna. Retorna as contagens.
//
// `week` é o rótulo de destino ("2026-W30"); vazio = a semana de `now`, que é o
// caminho do fechamento automático de domingo 23:59. Passar um rótulo anterior é
// o que resolve a virada de madrugada: o que foi concluído às 00:30 de segunda
// entra na semana em que o trabalho aconteceu, em vez de abrir uma semana nova.
//
// O corte da encalhada é o FIM da semana rotulada (weekCutoffFor): quem nasceu
// dentro dela e não começou é marcado no fechamento dela mesma.
//
// [13/08/2026] O corte era o INÍCIO da semana rotulada, e isto estava escrito
// aqui como intencional: "o corte da encalhada acompanha o rótulo escolhido, e
// não o relógio: fechando na W30, um a_fazer criado durante a W30 não vira
// encalhado no mesmo fechamento que encerra a semana dele" (commit bdec684). O
// efeito era uma semana inteira de carência extra — um card nascido na W32 só
// seria marcado no fechamento da W33 — enquanto o /board-protocol promete o
// contrário: encalhada é quem "atravessa a virada da semana sem nunca ter
// começado", e a virada que ele atravessa é a do domingo seguinte ao nascimento.
// Decisão da Vanessa em 13/08/2026: corte no fim da semana. O caso que o corte
// antigo protegia segue protegido pelo limite exclusivo — fechando a W30 às
// 00:30 da segunda, o card nascido àquela hora é da W31 e não encalha.
func (s *MemStore) CloseWeek(now time.Time, week string) (archived, stalled int) {
	cutoff, label := weekCutoffFor(week, now)
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
		case t.Column == "a_fazer" && !t.Encalhada && t.CreatedAt.Before(cutoff):
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

// WeekOption é uma semana candidata a receber o fechamento, com o intervalo já
// resolvido para o cliente não precisar refazer aritmética de semana ISO.
type WeekOption struct {
	Label string `json:"label"`
	Start string `json:"start"`
	End   string `json:"end"`
	// Count é quantos cards JÁ estão arquivados nessa semana.
	Count int `json:"count"`
}

// CloseOptions é o que o fechamento manual oferece de escolha.
//
// `Last` é a semana arquivada mais recente que NÃO é a atual — a opção "juntar
// no que já foi arquivado". É nula quando não existe (arquivo vazio, ou só a
// semana atual lá dentro); nesse caso não há escolha a fazer e o cliente mostra
// a confirmação simples de sempre.
type CloseOptions struct {
	Current WeekOption  `json:"current"`
	Last    *WeekOption `json:"last,omitempty"`
	// Pending é quantos concluídos seriam arquivados agora.
	Pending int `json:"pending"`
}

// weekOption monta a opção a partir do rótulo (datas derivadas dele).
func weekOption(label string, count int) WeekOption {
	var y, w int
	fmt.Sscanf(label, "%d-W%d", &y, &w)
	start := isoWeekStartDate(y, w)
	return WeekOption{
		Label: label, Start: start.Format("2006-01-02"),
		End: start.AddDate(0, 0, 6).Format("2006-01-02"), Count: count,
	}
}

// lastDistinct devolve o rótulo arquivado mais recente diferente de `current`.
func lastDistinct(counts map[string]int, current string) (string, bool) {
	labels := make([]string, 0, len(counts))
	for l := range counts {
		if l != current {
			labels = append(labels, l)
		}
	}
	if len(labels) == 0 {
		return "", false
	}
	sort.Sort(sort.Reverse(sort.StringSlice(labels))) // 2026-W30 antes de W29
	return labels[0], true
}

// CloseOptions lista as semanas que podem receber o fechamento manual.
func (s *MemStore) CloseOptions(now time.Time) CloseOptions {
	current := weekLabel(now)
	counts := map[string]int{}
	pending := 0
	s.mu.RLock()
	for l, ts := range s.archive {
		counts[l] = len(ts)
	}
	for _, t := range s.byID {
		if t.Column == "concluido" {
			pending++
		}
	}
	s.mu.RUnlock()
	return buildCloseOptions(current, counts, pending)
}

// buildCloseOptions é a parte pura, compartilhada pelos dois stores.
func buildCloseOptions(current string, counts map[string]int, pending int) CloseOptions {
	out := CloseOptions{Current: weekOption(current, counts[current]), Pending: pending}
	if l, ok := lastDistinct(counts, current); ok {
		opt := weekOption(l, counts[l])
		out.Last = &opt
	}
	return out
}

// ArchivedWeek é uma semana do arquivo, para exibição.
type ArchivedWeek struct {
	Label string `json:"label"`
	Start string `json:"start"`
	End   string `json:"end"`
	Tasks []Task `json:"tasks"`
}

// ArchivedWeeks devolve o arquivo agrupado por semana, mais recente primeiro.
func (s *MemStore) ArchivedWeeks() []ArchivedWeek {
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

// Search acha cards (ativos + arquivados) por título/descrição/comentário.
func (s *MemStore) Search(q string) []Task {
	q = strings.ToLower(strings.TrimSpace(q))
	if q == "" {
		return []Task{}
	}
	match := func(t Task) bool {
		if strings.Contains(strings.ToLower(t.Title), q) || strings.Contains(strings.ToLower(t.Description), q) {
			return true
		}
		for _, c := range t.Comments {
			if strings.Contains(strings.ToLower(c.Text), q) {
				return true
			}
		}
		return false
	}
	var out []Task
	s.mu.RLock()
	for _, t := range s.byID {
		if match(t) {
			out = append(out, t)
		}
	}
	for _, ts := range s.archive {
		for _, t := range ts {
			if match(t) {
				t.Archived = true
				out = append(out, t)
			}
		}
	}
	s.mu.RUnlock()
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt.After(out[j].UpdatedAt) })
	return out
}

// StartWeeklyCloser dispara CloseWeek automaticamente todo domingo 23:59 na loc.
//
// Loga o horário agendado e as contagens de cada rodada. Não é enfeite: com 0
// arquivado e 0 encalhado, um fechamento que rodou e um que nunca rodou são
// indistinguíveis no board — e foi isso que fez o diagnóstico do corte da
// encalhada (13/08/2026) virar eliminação de hipóteses em vez de leitura de log.
func StartWeeklyCloser(s Store, loc *time.Location) {
	go func() {
		for {
			prox := nextSundayClose(time.Now().In(loc))
			log.Printf("board: próximo fechamento automático da semana em %s", prox.Format(time.RFC3339))
			time.Sleep(time.Until(prox))
			// Rótulo vazio: domingo 23:59 a semana do relógio É a semana certa.
			arquivados, encalhados := s.CloseWeek(time.Now().In(loc), "")
			log.Printf("board: fechamento automático da semana concluído: %d arquivado(s), %d encalhado(s)",
				arquivados, encalhados)
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

func (s *MemStore) Add(n NewTask) Task {
	now := time.Now()
	actor := n.Role
	if actor == "" {
		actor = n.Type
	}
	t := Task{
		ID: newID(), Title: n.Title, Column: "a_fazer",
		Group: n.Group, Session: n.Session, Type: n.Type, Role: n.Role, Description: n.Description,
		Activity:  []Activity{{Actor: actorOr(actor), Action: "criou o card", At: now}},
		CreatedAt: now, UpdatedAt: now,
	}
	s.mu.Lock()
	s.byID[t.ID] = t
	s.mu.Unlock()
	s.persist()
	s.broadcast(t)
	return t
}

// Update altera coluna e/ou título (ponteiros nil = não mexe). `actor` é quem fez a
// ação (para o log de atividade em mudanças de coluna). Retorna a task atualizada e
// ok=false se o id não existir ou a coluna for inválida.
func (s *MemStore) Update(id string, column, title, description, role *string, actor string) (Task, bool) {
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
		if *column != t.Column {
			label := colLabelPT[*column]
			if label == "" {
				label = *column
			}
			t.Activity = append(t.Activity, Activity{Actor: actorOr(actor), Action: "moveu para " + label, At: now})
		}
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
func (s *MemStore) SetEncalhada(id string, v bool, actor string) (Task, bool) {
	s.mu.Lock()
	t, ok := s.byID[id]
	if !ok {
		s.mu.Unlock()
		return Task{}, false
	}
	now := time.Now()
	if v != t.Encalhada {
		action := "reativou o card"
		if v {
			action = "marcou como encalhada"
		}
		t.Activity = append(t.Activity, Activity{Actor: actorOr(actor), Action: action, At: now})
	}
	t.Encalhada = v
	t.UpdatedAt = now
	s.byID[id] = t
	s.mu.Unlock()
	s.persist()
	s.broadcast(t)
	return t, true
}

// AddComment adiciona uma observação ao card. Retorna a task atualizada e
// ok=false se o id não existir.
func (s *MemStore) AddComment(id, author, text string) (Task, bool) {
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

func (s *MemStore) Remove(id string) bool {
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

func (s *MemStore) Subscribe() *Sub {
	ch := make(chan Task, subBuffer)
	rm := make(chan string, subBuffer)
	sub := &Sub{C: ch, ch: ch, Removed: rm, removedCh: rm}
	s.mu.Lock()
	s.subs[sub] = struct{}{}
	s.mu.Unlock()
	return sub
}

func (s *MemStore) Unsubscribe(sub *Sub) {
	s.mu.Lock()
	delete(s.subs, sub)
	s.mu.Unlock()
}

// broadcast entrega best-effort e sem ordenação garantida (igual ao registry):
// envio não-bloqueante, e como roda fora de s.mu a ordem entre eventos de ids
// diferentes/iguais não é garantida. Consumidores são idempotentes por id e
// recuperam o estado completo no snapshot ao (re)conectar.
func (s *MemStore) broadcast(t Task) {
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
func (s *MemStore) broadcastRemoved(id string) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for sub := range s.subs {
		select {
		case sub.removedCh <- id:
		default:
		}
	}
}
