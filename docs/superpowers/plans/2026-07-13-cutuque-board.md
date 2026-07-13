# Cutuque Board Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Um Kanban dos agentes ("Trello dos agentes") alimentado por uma CLI `cutuque` e visível/manipulável numa nova aba do dashboard, com store durável no hub.

**Architecture:** Aditivo ao hub existente. Um `board.Store` (Go) espelha o padrão do `registry` (mutex + persistência JSON + pub/sub). Novos endpoints REST `/board*` e eventos WS `board_*` no WebSocket existente. Uma CLI Node `cutuque` que os agentes rodam no tmux (identificação automática grupo+sessão). Uma aba "Board" no dashboard servido pelo hub, com Kanban e drag-and-drop.

**Tech Stack:** Go (hub, `go:embed`, `net/http`, `encoding/json`, `crypto/rand`), Node.js ESM (CLI, `node:test`), HTML/CSS/JS (dashboard, sem framework).

## Global Constraints

- **Estritamente aditivo:** não alterar comportamento/contrato existente do hub nem `app/`. Board de status (Sessões) intacto. Só somar: pacote `board`, handlers `/board*`, eventos WS `board_*`, aba nova no dashboard, CLI nova.
- **Colunas (ordem exata):** `a_fazer` → `em_progresso` → `feito` → `em_revisao` → `concluido`.
- **Tags de identificação:** `group` (grupo tmux) e `session` (sessão tmux).
- **Auth:** endpoints `/board*` protegidos pelo mesmo token do hub (`requireAuth(cfg.Token, …)`); WS já autentica por `?token=`.
- **Persistência:** JSON durável no hub, escritor único sob mutex. A CLI NUNCA escreve o arquivo — só chama a API.
- **Módulo Go:** `github.com/vxfontes/cutuque/hub`.
- **Hub base/env:** dev `http://127.0.0.1:8787` (token `dev-token`); WS `/ws?token=`.

## Shared Types (contratos entre tarefas)

```go
// board.Task (hub/internal/board)
type Task struct {
    ID        string    `json:"id"`
    Title     string    `json:"title"`
    Column    string    `json:"column"`   // a_fazer|em_progresso|feito|em_revisao|concluido
    Group     string    `json:"group"`
    Session   string    `json:"session"`
    CreatedAt time.Time `json:"created_at"`
    UpdatedAt time.Time `json:"updated_at"`
}
```

```
// WS (aditivo, mesmo /ws):
//  {type:"board_snapshot", tasks:[Task]}   // ao conectar
//  {type:"board_updated",  task:Task}      // create/update
//  {type:"board_removed",  id:"..."}       // delete
// REST:
//  GET    /board                 -> {tasks:[Task]}
//  POST   /board/tasks           {title,group,session} -> Task (201)
//  PATCH  /board/tasks/{id}       {column?,title?}      -> Task (200) | 404
//  DELETE /board/tasks/{id}                             -> 204 | 404
```

## File Structure

```
hub/internal/board/
  board.go            # Task, Columns, ValidColumn, Store (mutex + pub/sub + JSON persist)
  board_test.go
hub/internal/server/
  board_http.go       # handlers REST /board*
  board_http_test.go
  ws.go               # (MOD) subscreve o board store, emite board_*
  server.go           # (MOD) registra rotas /board*, passa store ao WSHandler
  dashboard.html      # (MOD) aba "Board" + Kanban + WS board + drag-and-drop
cmd/hub/main.go        # (MOD) instancia o board.Store (NewAt) e passa às rotas
board/                 # CLI cutuque (Node)
  package.json
  bin/cutuque.js       # entrypoint / parse de args
  src/config.js        # hub url + token (env)
  src/tmuxIdentity.js  # {group, session} do tmux
  src/hubClient.js     # REST (add/list/move) com Bearer
  src/commands.js      # add/list/move (formatação de saída)
  test/*.test.js
docs/board-protocol.md # instrução para os agentes
```

---

### Task 1: Board model + Store (Go)

**Files:**
- Create: `hub/internal/board/board.go`
- Test: `hub/internal/board/board_test.go`

**Interfaces:**
- Produces:
  - `Columns = []string{"a_fazer","em_progresso","feito","em_revisao","concluido"}`
  - `func ValidColumn(c string) bool`
  - `type Task struct {…}` (ver Shared Types)
  - `type Store` com: `New() *Store`, `NewAt(path string) *Store`, `List() []Task`, `Add(title, group, session string) Task`, `Update(id string, column, title *string) (Task, bool)`, `Remove(id string) bool`, `Get(id string) (Task, bool)`, `Subscribe() *Sub`, `Unsubscribe(*Sub)`.
  - `type Sub struct { C <-chan Task; Removed <-chan string; … }`
  - Persistência: `NewAt` carrega do JSON; toda mutação salva (mutex). `New()` só memória.

- [ ] **Step 1: Escrever o teste que falha**

```go
// hub/internal/board/board_test.go
package board

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAddListUpdateRemove(t *testing.T) {
	s := New()
	a := s.Add("rodar testes", "interconexao", "cutuque")
	if a.ID == "" || a.Column != "a_fazer" {
		t.Fatalf("Add: id vazio ou coluna inicial errada: %+v", a)
	}
	if got := s.List(); len(got) != 1 {
		t.Fatalf("List: esperava 1, veio %d", len(got))
	}
	col := "em_progresso"
	u, ok := s.Update(a.ID, &col, nil)
	if !ok || u.Column != "em_progresso" {
		t.Fatalf("Update coluna falhou: ok=%v %+v", ok, u)
	}
	if !u.UpdatedAt.After(a.UpdatedAt) && !u.UpdatedAt.Equal(a.UpdatedAt) {
		t.Fatalf("UpdatedAt não avançou")
	}
	if _, ok := s.Update("inexistente", &col, nil); ok {
		t.Fatalf("Update de id inexistente deveria falhar")
	}
	if !s.Remove(a.ID) {
		t.Fatalf("Remove deveria retornar true")
	}
	if len(s.List()) != 0 {
		t.Fatalf("List após remove deveria ser 0")
	}
}

func TestValidColumn(t *testing.T) {
	for _, c := range Columns {
		if !ValidColumn(c) {
			t.Fatalf("ValidColumn(%q) deveria ser true", c)
		}
	}
	if ValidColumn("zzz") {
		t.Fatalf("ValidColumn(zzz) deveria ser false")
	}
}

func TestPersistLoad(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "board.json")
	s1 := NewAt(p)
	task := s1.Add("persistir", "g", "s")
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("arquivo não foi escrito: %v", err)
	}
	s2 := NewAt(p)
	got := s2.List()
	if len(got) != 1 || got[0].ID != task.ID {
		t.Fatalf("não recarregou do disco: %+v", got)
	}
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd hub && go test ./internal/board/`
Expected: FAIL (pacote/símbolos não existem)

- [ ] **Step 3: Implementar `hub/internal/board/board.go`**

```go
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
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd hub && go test ./internal/board/`
Expected: PASS (3 testes)

- [ ] **Step 5: Commit**

```bash
git add hub/internal/board/board.go hub/internal/board/board_test.go
git commit -m "feat(hub): board.Store (Kanban dos agentes) com persistência + pub/sub"
```

---

### Task 2: REST handlers `/board*` (Go)

**Files:**
- Create: `hub/internal/server/board_http.go`
- Test: `hub/internal/server/board_http_test.go`
- Modify: `hub/internal/server/server.go` (registrar rotas)
- Modify: `hub/cmd/hub/main.go` (instanciar o store)

**Interfaces:**
- Consumes: `board.Store` (Task 1).
- Produces handlers: `BoardListHandler(*board.Store)`, `BoardCreateHandler(*board.Store)`, `BoardPatchHandler(*board.Store)`, `BoardDeleteHandler(*board.Store)`.
- Router registra (protegido por token):
  - `GET /board`, `POST /board/tasks`, `PATCH /board/tasks/{id}`, `DELETE /board/tasks/{id}`.

- [ ] **Step 1: Escrever o teste que falha**

```go
// hub/internal/server/board_http_test.go
package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/board"
)

func TestBoardCreateAndList(t *testing.T) {
	st := board.New()

	// POST cria
	body := bytes.NewBufferString(`{"title":"rodar testes","group":"interconexao","session":"cutuque"}`)
	rec := httptest.NewRecorder()
	BoardCreateHandler(st).ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/board/tasks", body))
	if rec.Code != http.StatusCreated {
		t.Fatalf("POST status: %d", rec.Code)
	}
	var created board.Task
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	if created.ID == "" || created.Column != "a_fazer" {
		t.Fatalf("POST body: %+v", created)
	}

	// GET lista
	rec = httptest.NewRecorder()
	BoardListHandler(st).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/board", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET status: %d", rec.Code)
	}
}

func TestBoardPatchMoveAndDelete(t *testing.T) {
	st := board.New()
	task := st.Add("x", "g", "s")

	// PATCH move
	req := httptest.NewRequest(http.MethodPatch, "/board/tasks/"+task.ID, bytes.NewBufferString(`{"column":"feito"}`))
	req.SetPathValue("id", task.ID)
	rec := httptest.NewRecorder()
	BoardPatchHandler(st).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH status: %d", rec.Code)
	}
	var moved board.Task
	_ = json.Unmarshal(rec.Body.Bytes(), &moved)
	if moved.Column != "feito" {
		t.Fatalf("PATCH não moveu: %+v", moved)
	}

	// PATCH coluna inválida -> 400
	req = httptest.NewRequest(http.MethodPatch, "/board/tasks/"+task.ID, bytes.NewBufferString(`{"column":"zzz"}`))
	req.SetPathValue("id", task.ID)
	rec = httptest.NewRecorder()
	BoardPatchHandler(st).ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("PATCH inválido status: %d", rec.Code)
	}

	// DELETE
	req = httptest.NewRequest(http.MethodDelete, "/board/tasks/"+task.ID, nil)
	req.SetPathValue("id", task.ID)
	rec = httptest.NewRecorder()
	BoardDeleteHandler(st).ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("DELETE status: %d", rec.Code)
	}

	// PATCH de id inexistente -> 404
	req = httptest.NewRequest(http.MethodPatch, "/board/tasks/none", bytes.NewBufferString(`{"column":"feito"}`))
	req.SetPathValue("id", "none")
	rec = httptest.NewRecorder()
	BoardPatchHandler(st).ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("PATCH 404 status: %d", rec.Code)
	}
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd hub && go test ./internal/server/ -run TestBoard`
Expected: FAIL (handlers não existem)

- [ ] **Step 3: Implementar `hub/internal/server/board_http.go`**

```go
package server

import (
	"encoding/json"
	"net/http"

	"github.com/vxfontes/cutuque/hub/internal/board"
)

// NOTA: reusa o helper JÁ EXISTENTE `writeJSONResp(w, status, v)` (settings.go).
// NÃO declarar `writeJSON` aqui — o pacote server já tem um `writeJSON` com
// outra assinatura (ws.go), o que causaria erro de redeclaração.

// BoardListHandler responde a lista de tarefas.
func BoardListHandler(st *board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tasks := st.List()
		if tasks == nil {
			tasks = []board.Task{}
		}
		writeJSONResp(w, http.StatusOK, map[string]any{"tasks": tasks})
	}
}

// BoardCreateHandler cria uma tarefa (coluna inicial a_fazer).
func BoardCreateHandler(st *board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Title, Group, Session string }
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&in) != nil || in.Title == "" {
			writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "bad_request"})
			return
		}
		writeJSONResp(w, http.StatusCreated, st.Add(in.Title, in.Group, in.Session))
	}
}

// BoardPatchHandler move/edita uma tarefa.
func BoardPatchHandler(st *board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		var in struct {
			Column *string `json:"column"`
			Title  *string `json:"title"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&in) != nil {
			writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "bad_request"})
			return
		}
		if in.Column != nil && !board.ValidColumn(*in.Column) {
			writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "invalid_column"})
			return
		}
		t, ok := st.Update(id, in.Column, in.Title)
		if !ok {
			writeJSONResp(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		writeJSONResp(w, http.StatusOK, t)
	}
}

// BoardDeleteHandler remove uma tarefa.
func BoardDeleteHandler(st *board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !st.Remove(r.PathValue("id")) {
			writeJSONResp(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}
```

> **Nota (verificado):** o pacote `server` já tem `writeJSONResp(w, status, v)` (settings.go) — reusar. NÃO criar `writeJSON` (colide com o de ws.go).

- [ ] **Step 4: Registrar rotas em `hub/internal/server/server.go`**

Adicionar o parâmetro do board ao `Router` via uma `RouterOption` (padrão já usado no arquivo) OU um parâmetro direto. Implementação: adicionar um campo em `routerConfig` e uma opção `WithBoard(*board.Store)`, e registrar quando presente:

```go
// em server.go, junto das outras RouterOption:
func WithBoard(st *board.Store) RouterOption { return func(rc *routerConfig) { rc.board = st } }

// no bloco de rotas abertas/protegidas:
if rc.board != nil {
	mux.Handle("GET /board", requireAuth(cfg.Token, BoardListHandler(rc.board)))
	mux.Handle("POST /board/tasks", requireAuth(cfg.Token, BoardCreateHandler(rc.board)))
	mux.Handle("PATCH /board/tasks/{id}", requireAuth(cfg.Token, BoardPatchHandler(rc.board)))
	mux.Handle("DELETE /board/tasks/{id}", requireAuth(cfg.Token, BoardDeleteHandler(rc.board)))
}
```

(Adicionar `board *board.Store` ao struct `routerConfig` e o import do pacote `board`.)

- [ ] **Step 5: Instanciar o store em `hub/cmd/hub/main.go`**

Criar `board.NewAt(<data dir>/board.json)` (mesmo diretório da persistência de sessões) e passar `server.WithBoard(boardStore)` ao `Router`. Ver como o path de persistência de sessão é resolvido no main e reusar o mesmo diretório.

- [ ] **Step 6: Rodar e ver passar**

Run: `cd hub && go test ./internal/server/ -run TestBoard && go build ./...`
Expected: PASS + BUILD OK

- [ ] **Step 7: Commit**

```bash
git add hub/internal/server/board_http.go hub/internal/server/board_http_test.go hub/internal/server/server.go hub/cmd/hub/main.go
git commit -m "feat(hub): endpoints REST /board* + store no main"
```

---

### Task 3: Eventos WS `board_*` (Go)

**Files:**
- Modify: `hub/internal/server/ws.go`
- Modify: `hub/internal/server/server.go` (passar o store ao WSHandler)
- Test: `hub/internal/server/ws_board_test.go`

**Interfaces:**
- `WSHandler` passa a aceitar `*board.Store` (além do `*registry.Registry`). Ao conectar, envia `board_snapshot`; depois emite `board_updated`/`board_removed` conforme o store muda, no mesmo loop de select do WS.
- Mensagens: `{type:"board_snapshot",tasks:[]}`, `{type:"board_updated",task:{}}`, `{type:"board_removed",id:""}`.

- [ ] **Step 1: Escrever o teste que falha (unidade do formato das mensagens)**

```go
// hub/internal/server/ws_board_test.go
package server

import (
	"encoding/json"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/board"
)

func TestBoardWSMessages(t *testing.T) {
	snap := boardSnapshotMessage{Type: "board_snapshot", Tasks: []board.Task{{ID: "1", Column: "a_fazer"}}}
	b, _ := json.Marshal(snap)
	if string(b) == "" || snap.Type != "board_snapshot" {
		t.Fatalf("snapshot msg inválida: %s", b)
	}
	upd := boardUpdatedMessage{Type: "board_updated", Task: board.Task{ID: "1"}}
	if upd.Type != "board_updated" {
		t.Fatalf("updated msg inválida")
	}
	rem := boardRemovedMessage{Type: "board_removed", ID: "1"}
	if rem.Type != "board_removed" || rem.ID != "1" {
		t.Fatalf("removed msg inválida")
	}
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd hub && go test ./internal/server/ -run TestBoardWS`
Expected: FAIL (tipos não existem)

- [ ] **Step 3: Implementar em `hub/internal/server/ws.go`**

Adicionar os tipos e integrar ao handler. Structs:

```go
type boardSnapshotMessage struct {
	Type  string       `json:"type"` // "board_snapshot"
	Tasks []board.Task `json:"tasks"`
}
type boardUpdatedMessage struct {
	Type string     `json:"type"` // "board_updated"
	Task board.Task `json:"task"`
}
type boardRemovedMessage struct {
	Type string `json:"type"` // "board_removed"
	ID   string `json:"id"`
}
```

Mudar a assinatura para `WSHandler(reg *registry.Registry, bd *board.Store)`. Depois do snapshot de sessões, se `bd != nil`: assinar (`bsub := bd.Subscribe(); defer bd.Unsubscribe(bsub)`), enviar `boardSnapshotMessage{Type:"board_snapshot", Tasks: bd.List()}`, e no `for/select` adicionar os casos:

```go
case t, ok := <-bsub.C:
	if !ok { return }
	if err := writeJSON(ctx, c, boardUpdatedMessage{Type: "board_updated", Task: t}); err != nil { return }
case id, ok := <-bsub.Removed:
	if !ok { return }
	if err := writeJSON(ctx, c, boardRemovedMessage{Type: "board_removed", ID: id}); err != nil { return }
```

Se `bd == nil`, o handler funciona como antes (aditivo).

- [ ] **Step 4: Passar o store ao WSHandler em `server.go`**

```go
mux.Handle("GET /ws", requireAuth(cfg.Token, WSHandler(reg, rc.board)))
```

- [ ] **Step 5: Rodar e ver passar**

Run: `cd hub && go test ./internal/server/ && go build ./...`
Expected: PASS + BUILD OK (todos os testes existentes continuam verdes)

- [ ] **Step 6: Commit**

```bash
git add hub/internal/server/ws.go hub/internal/server/ws_board_test.go hub/internal/server/server.go
git commit -m "feat(hub): eventos WS board_snapshot/updated/removed no /ws"
```

---

### Task 4: CLI `cutuque` — scaffold + config + identidade tmux (Node)

**Files:**
- Create: `board/package.json`, `board/src/config.js`, `board/src/tmuxIdentity.js`
- Test: `board/test/config.test.js`, `board/test/tmuxIdentity.test.js`

**Interfaces:**
- `resolveConfig(env) -> { hubBaseUrl, token }` — `hubBaseUrl = env.CUTUQUE_HUB || env.CUTUQUE_DECK_HUB || "http://127.0.0.1:8787"`, `token = env.CUTUQUE_TOKEN || "dev-token"`.
- `tmuxIdentity(env, runCmd) -> { group, session }` — `session` via `runCmd("tmux display-message -p '#S'")` (trim); `group` = basename do socket em `env.TMUX` (parte antes da 1ª vírgula). Fora do tmux (`!env.TMUX`) → `{ group: env.HOSTNAME || "local", session: "default" }`. `runCmd` injetável p/ teste.

- [ ] **Step 1: `board/package.json`**

```json
{
  "name": "cutuque-cli",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "bin": { "cutuque": "bin/cutuque.js" },
  "scripts": { "test": "node --test" }
}
```

- [ ] **Step 2: Testes que falham**

```js
// board/test/config.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resolveConfig } from '../src/config.js';

test('defaults de dev', () => {
  const c = resolveConfig({});
  assert.equal(c.hubBaseUrl, 'http://127.0.0.1:8787');
  assert.equal(c.token, 'dev-token');
});
test('respeita env', () => {
  const c = resolveConfig({ CUTUQUE_HUB: 'http://h:9', CUTUQUE_TOKEN: 'tk' });
  assert.equal(c.hubBaseUrl, 'http://h:9');
  assert.equal(c.token, 'tk');
});
```

```js
// board/test/tmuxIdentity.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tmuxIdentity } from '../src/tmuxIdentity.js';

test('deriva group do socket TMUX e session do comando', () => {
  const id = tmuxIdentity(
    { TMUX: '/private/tmp/tmux-501/interconexao,12345,0' },
    () => 'cutuque\n',
  );
  assert.equal(id.group, 'interconexao');
  assert.equal(id.session, 'cutuque');
});
test('fora do tmux cai no fallback', () => {
  const id = tmuxIdentity({ HOSTNAME: 'macbook' }, () => { throw new Error('no tmux'); });
  assert.equal(id.group, 'macbook');
  assert.equal(id.session, 'default');
});
```

- [ ] **Step 3: Rodar e ver falhar**

Run: `cd board && node --test`
Expected: FAIL (módulos não existem)

- [ ] **Step 4: Implementar**

```js
// board/src/config.js
export function resolveConfig(env = {}) {
  return {
    hubBaseUrl: env.CUTUQUE_HUB || env.CUTUQUE_DECK_HUB || 'http://127.0.0.1:8787',
    token: env.CUTUQUE_TOKEN || 'dev-token',
  };
}
```

```js
// board/src/tmuxIdentity.js
import { execSync } from 'node:child_process';
import { basename } from 'node:path';

// Identidade da sessão a partir do tmux. group = nome do socket (tmux -L <group>),
// derivado do caminho do socket em $TMUX; session = nome da sessão atual.
export function tmuxIdentity(env = process.env, runCmd = defaultRun) {
  if (!env.TMUX) {
    return { group: env.HOSTNAME || 'local', session: 'default' };
  }
  const socketPath = String(env.TMUX).split(',')[0];
  const group = basename(socketPath) || 'default';
  let session = 'default';
  try { session = String(runCmd("tmux display-message -p '#S'")).trim() || 'default'; } catch { /* fallback */ }
  return { group, session };
}

function defaultRun(cmd) {
  return execSync(cmd, { encoding: 'utf8' });
}
```

- [ ] **Step 5: Rodar e ver passar**

Run: `cd board && node --test`
Expected: PASS (4 testes)

- [ ] **Step 6: Commit**

```bash
git add board/package.json board/src/config.js board/src/tmuxIdentity.js board/test/config.test.js board/test/tmuxIdentity.test.js
git commit -m "feat(cli): scaffold cutuque + config + identidade tmux"
```

---

### Task 5: CLI — hub client (REST) + comandos add/list/move

**Files:**
- Create: `board/src/hubClient.js`, `board/src/commands.js`
- Test: `board/test/commands.test.js`

**Interfaces:**
- Consumes: `resolveConfig`, `tmuxIdentity` (Task 4).
- `createHubClient({ hubBaseUrl, token, fetchImpl=fetch }) -> { listTasks(), createTask({title,group,session}), moveTask(id,column) }` (REST com `Authorization: Bearer`).
- `commands = { add(cli, title), list(cli), move(cli, id, column) }` onde `cli` é `{ client, identity, out }`. `add` cria e imprime o id; `list` filtra por `identity.group`+`identity.session` e imprime por coluna; `move` chama `moveTask`.

- [ ] **Step 1: Teste que falha (com client e out fakes)**

```js
// board/test/commands.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { commands } from '../src/commands.js';

function fakeCli(tasks = []) {
  const out = [];
  const created = [];
  const moved = [];
  return {
    _out: out, _created: created, _moved: moved,
    identity: { group: 'interconexao', session: 'cutuque' },
    out: (s) => out.push(s),
    client: {
      listTasks: async () => tasks,
      createTask: async (t) => { created.push(t); return { ...t, id: 'new1', column: 'a_fazer' }; },
      moveTask: async (id, col) => { moved.push([id, col]); return { id, column: col }; },
    },
  };
}

test('add cria com as tags da identidade e imprime id', async () => {
  const cli = fakeCli();
  await commands.add(cli, 'rodar testes');
  assert.equal(cli._created[0].title, 'rodar testes');
  assert.equal(cli._created[0].group, 'interconexao');
  assert.equal(cli._created[0].session, 'cutuque');
  assert.ok(cli._out.join('\n').includes('new1'));
});

test('list filtra pela sessão atual', async () => {
  const cli = fakeCli([
    { id: 'a', title: 't1', column: 'a_fazer', group: 'interconexao', session: 'cutuque' },
    { id: 'b', title: 't2', column: 'feito', group: 'outro', session: 'x' },
  ]);
  await commands.list(cli);
  const printed = cli._out.join('\n');
  assert.ok(printed.includes('t1'));
  assert.ok(!printed.includes('t2')); // de outra sessão, filtrado
});

test('move chama o client', async () => {
  const cli = fakeCli();
  await commands.move(cli, 'a', 'em_progresso');
  assert.deepEqual(cli._moved[0], ['a', 'em_progresso']);
});
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd board && node --test test/commands.test.js`
Expected: FAIL (módulos não existem)

- [ ] **Step 3: Implementar**

```js
// board/src/hubClient.js
export function createHubClient({ hubBaseUrl, token, fetchImpl = fetch }) {
  const h = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  async function req(method, path, body) {
    const res = await fetchImpl(`${hubBaseUrl}${path}`, {
      method, headers: h, body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) throw new Error(`${method} ${path}: HTTP ${res.status}`);
    if (res.status === 204) return null;
    return res.json();
  }
  return {
    async listTasks() { return (await req('GET', '/board')).tasks || []; },
    async createTask(t) { return req('POST', '/board/tasks', t); },
    async moveTask(id, column) { return req('PATCH', `/board/tasks/${id}`, { column }); },
  };
}
```

```js
// board/src/commands.js
const COLS = ['a_fazer', 'em_progresso', 'feito', 'em_revisao', 'concluido'];
const LABEL = { a_fazer: 'A fazer', em_progresso: 'Em progresso', feito: 'Feito', em_revisao: 'Em revisão', concluido: 'Concluído' };

export const commands = {
  async add(cli, title) {
    const t = await cli.client.createTask({ title, group: cli.identity.group, session: cli.identity.session });
    cli.out(`✓ criado ${t.id} em "A fazer": ${title}`);
  },
  async list(cli) {
    const all = await cli.client.listTasks();
    const mine = all.filter((t) => t.group === cli.identity.group && t.session === cli.identity.session);
    cli.out(`Board de ${cli.identity.group}/${cli.identity.session} (${mine.length}):`);
    for (const col of COLS) {
      const items = mine.filter((t) => t.column === col);
      if (!items.length) continue;
      cli.out(`\n${LABEL[col]}:`);
      for (const t of items) cli.out(`  ${t.id}  ${t.title}`);
    }
  },
  async move(cli, id, column) {
    if (!COLS.includes(column)) throw new Error(`coluna inválida: ${column} (use: ${COLS.join(', ')})`);
    await cli.client.moveTask(id, column);
    cli.out(`✓ ${id} → ${LABEL[column]}`);
  },
};
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd board && node --test`
Expected: PASS (todos)

- [ ] **Step 5: Commit**

```bash
git add board/src/hubClient.js board/src/commands.js board/test/commands.test.js
git commit -m "feat(cli): hub client REST + comandos add/list/move"
```

---

### Task 6: CLI — entrypoint `bin/cutuque.js`

**Files:**
- Create: `board/bin/cutuque.js`

**Interfaces:**
- Consumes: config, tmuxIdentity, hubClient, commands.
- Parse simples de `process.argv`: `cutuque task add "<title>"` | `cutuque task list` | `cutuque task move <id> <coluna>`. Sem subcomando/ajuda → imprime uso.

- [ ] **Step 1: Escrever `board/bin/cutuque.js`**

```js
#!/usr/bin/env node
import { resolveConfig } from '../src/config.js';
import { tmuxIdentity } from '../src/tmuxIdentity.js';
import { createHubClient } from '../src/hubClient.js';
import { commands } from '../src/commands.js';

const USAGE = `uso:
  cutuque task add "<título>"
  cutuque task list
  cutuque task move <id> <a_fazer|em_progresso|feito|em_revisao|concluido>`;

async function main() {
  const [, , area, action, ...rest] = process.argv;
  if (area !== 'task') { console.log(USAGE); process.exit(rest.length ? 1 : 0); }

  const cfg = resolveConfig(process.env);
  const cli = {
    identity: tmuxIdentity(process.env),
    client: createHubClient(cfg),
    out: (s) => console.log(s),
  };

  try {
    if (action === 'add') {
      const title = rest.join(' ').trim();
      if (!title) throw new Error('faltou o título');
      await commands.add(cli, title);
    } else if (action === 'list') {
      await commands.list(cli);
    } else if (action === 'move') {
      const [id, column] = rest;
      if (!id || !column) throw new Error('uso: cutuque task move <id> <coluna>');
      await commands.move(cli, id, column);
    } else {
      console.log(USAGE); process.exit(1);
    }
  } catch (err) {
    console.error(`erro: ${err.message}`); process.exit(1);
  }
}
main();
```

- [ ] **Step 2: Verificar (e2e contra o hub dev)**

```bash
cd board && chmod +x bin/cutuque.js
# hub dev rodando (CUTUQUE_ENV=dev go run ./cmd/hub)
node bin/cutuque.js task add "primeira tarefa"     # imprime ✓ criado <id>
node bin/cutuque.js task list                       # lista a tarefa desta sessão
node bin/cutuque.js task move <id> em_progresso     # move
```

Expected: os 3 comandos funcionam contra o hub dev; a tarefa aparece via `GET /board`.

- [ ] **Step 3: Commit**

```bash
git add board/bin/cutuque.js
git commit -m "feat(cli): entrypoint cutuque (task add/list/move)"
```

---

### Task 7: Dashboard — aba "Board" (Kanban + drag-and-drop + WS)

**Files:**
- Modify: `hub/internal/server/dashboard.html`

**Interfaces:**
- Consumes: eventos WS `board_snapshot`/`board_updated`/`board_removed` (Task 3) e `PATCH /board/tasks/{id}` (Task 2).
- Adiciona: nav de 2 abas ("Sessões" = board atual; "Board" = Kanban). Estado `tasks` (Map por id). Kanban com 5 colunas; cards mostram título + tags (grupo/sessão) + tempo. Drag-and-drop HTML5 (`draggable`, `dragstart`/`dragover`/`drop`) que chama `PATCH` com a nova coluna. Filtro por grupo/sessão. Reusa o mesmo WS/token já injetado.

- [ ] **Step 1: Adicionar a estrutura**

Adicionar ao `dashboard.html` (servido pelo hub):
- Uma barra de abas no header: botões "Sessões" e "Board" que alternam `document.body.dataset.view`.
- Uma `<section id="boardView">` com 5 colunas (`a_fazer`…`concluido`), cada uma um dropzone.
- No JS: um `Map` `tasks`; handlers WS:
  ```js
  else if (m.type === 'board_snapshot') { tasks.clear(); (m.tasks||[]).forEach(t=>tasks.set(t.id,t)); renderBoard(); }
  else if (m.type === 'board_updated') { tasks.set(m.task.id, m.task); renderBoard(); }
  else if (m.type === 'board_removed') { tasks.delete(m.id); renderBoard(); }
  ```
- `renderBoard()` agrupa `tasks` por coluna e monta os cards (título + tags + tempo). Cada card: `draggable="true"`, `dragstart` guarda o id; cada coluna: `dragover` (preventDefault) e `drop` → `moveTask(id, coluna)`.
- `moveTask(id,col)`: `fetch('/board/tasks/'+id, {method:'PATCH', headers:{Authorization:'Bearer '+TOKEN,'Content-Type':'application/json'}, body: JSON.stringify({column:col})})`. O eco vem pelo WS (`board_updated`) e re-renderiza.
- Filtro por grupo/sessão: um `<select>`/chips derivados das tags presentes; filtra o `renderBoard`.
- CSS das colunas: reutiliza as variáveis de estado existentes onde fizer sentido; colunas em `display:flex; gap` com scroll horizontal em telas pequenas (responsivo).

- [ ] **Step 2: Verificação visual (portal Maestri)**

```bash
# hub dev rodando + seed do board via CLI (algumas tarefas em colunas diferentes)
# abrir http://127.0.0.1:8787/dashboard, clicar na aba "Board"
```

Verificar: as tarefas aparecem nas colunas certas; arrastar um card entre colunas persiste (some do lugar antigo, aparece no novo) e sobrevive a reload; a aba "Sessões" continua funcionando igual. (Screenshot via portal, como no deck.)

- [ ] **Step 3: Commit**

```bash
git add hub/internal/server/dashboard.html
git commit -m "feat(dashboard): aba Board (Kanban dos agentes) com drag-and-drop ao vivo"
```

---

### Task 8: Instrução para os agentes (`docs/board-protocol.md`)

**Files:**
- Create: `docs/board-protocol.md`

- [ ] **Step 1: Escrever o protocolo**

`docs/board-protocol.md` com:
- Propósito do quadro + as 5 colunas e o significado de cada uma.
- Os comandos: `cutuque task list` (consultar antes de agir), `cutuque task add "…"`, `cutuque task move <id> <coluna>`.
- O protocolo passo-a-passo: consultar `list` ao começar → `add` das atividades pendentes → `em_progresso` ao iniciar → `feito` ao terminar → `em_revisao` ao revisar → `concluido` ao concluir.
- Um **bloco pronto para colar** no `CLAUDE.md`/regras de cada agente (curto e imperativo), instruindo o comportamento acima.
- Nota sobre a identificação automática (grupo tmux + sessão) — o agente não precisa passar tags.

- [ ] **Step 2: Commit**

```bash
git add docs/board-protocol.md
git commit -m "docs: protocolo do board para os agentes (+ bloco p/ CLAUDE.md)"
```

---

### Task 9: Verificação end-to-end + compatibilidade

- [ ] **Step 1: E2E completo**

```bash
# hub dev
cd hub && CUTUQUE_ENV=dev go run ./cmd/hub &
# CLI cria/move
cd board && node bin/cutuque.js task add "e2e A" && node bin/cutuque.js task add "e2e B"
ID=$(curl -s localhost:8787/board -H "Authorization: Bearer dev-token" | python3 -c "import sys,json;print(json.load(sys.stdin)['tasks'][0]['id'])")
node bin/cutuque.js task move "$ID" feito
# dashboard: aba Board mostra as duas, uma em "Feito"; arrastar persiste
curl -s localhost:8787/board -H "Authorization: Bearer dev-token" | python3 -m json.tool | head
```

Conferir: criação/movimento via CLI refletem no `GET /board` e ao vivo no dashboard; drag-and-drop no dashboard persiste; reiniciar o hub mantém as tarefas (persistência JSON).

- [ ] **Step 2: Checagem de compatibilidade (aditivo)**

```bash
cd hub && go build ./... && go test ./...          # tudo verde, sem regressão
cd ../board && node --test                          # CLI verde
git diff --name-only master..HEAD -- app | grep -q . && echo "ALERTA app/ mudou" || echo "app/ intacto ✅"
```

Expected: `go test ./...` PASS; `app/` sem mudanças; board de status (Sessões) inalterado.

- [ ] **Step 3: Commit (se houver ajustes)**

```bash
git add -A hub board docs && git commit -m "test(board): verificação e2e + compatibilidade" || true
```

---

## Self-Review

**Spec coverage:**
- Modelo Task + colunas → Task 1. ✅
- Store durável (JSON) + pub/sub → Task 1. ✅
- REST `/board*` → Task 2. ✅
- Eventos WS `board_*` → Task 3. ✅
- CLI `cutuque` (add/list/move) + identidade tmux → Tasks 4–6. ✅
- Consultar board antes de agir (`list`) → Task 5/6 + protocolo Task 8. ✅
- Dashboard aba "Board" + Kanban + drag-and-drop + ao vivo → Task 7. ✅
- Instrução .md para agentes → Task 8. ✅
- Aditivo / sem regressão → Task 9 (checagem). ✅

**Placeholders:** o path exato do `board.json` no `main.go` e o layout fino do HTML/CSS da aba Board estão descritos em prosa com o passo de verificação visual — decisões concretas ficam na execução, não são TODOs vagos. O `writeJSON` do pacote server tem nota explícita para não redeclarar.

**Type consistency:** `board.Task`, `Store` (`Add`/`Update`/`Remove`/`List`/`Subscribe`), handlers (`BoardListHandler`/`BoardCreateHandler`/`BoardPatchHandler`/`BoardDeleteHandler`), CLI (`resolveConfig`/`tmuxIdentity`/`createHubClient`/`commands`) e os tipos de mensagem WS (`board_snapshot|updated|removed`) usados de forma consistente entre as tarefas. ✅
