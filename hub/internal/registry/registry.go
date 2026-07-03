// Package registry mantém o Session Registry em memória: a fonte da verdade
// das sessões conhecidas pelo hub (ver docs/02-arquitetura.md). É thread-safe e
// permite que interessados (ex.: o WebSocket) assinem mudanças via canal.
package registry

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

// subBuffer é o tamanho do buffer de cada canal de subscriber. Envios são
// não-bloqueantes: se um subscriber lento encher o buffer, o evento é
// descartado para nunca travar o Registry. O subscriber recupera o estado
// completo no snapshot inicial ao reconectar.
const subBuffer = 32

// Subscription é a inscrição de um interessado nas mudanças do Registry.
// Consuma de C; ao terminar, chame Registry.Unsubscribe.
type Subscription struct {
	C  <-chan session.Session
	ch chan session.Session
	// Removed recebe o id de cada sessão removida (Registry.Remove) — o WS
	// traduz em {"type":"session_removed",...}. Canal separado de C porque
	// remoção não carrega uma Session; sem ordenação garantida entre os dois
	// (best-effort, como o resto do pub/sub).
	Removed   <-chan string
	removedCh chan string
}

// Registry guarda as sessões em memória de forma thread-safe.
type Registry struct {
	mu        sync.RWMutex
	byID      map[string]session.Session
	subs      map[*Subscription]struct{}
	outputs   map[string][]OutputChunk
	outSubs   map[*OutputSub]struct{}
	dismissed map[string]bool // sessões que a usuária apagou: não re-registrar por hook

	// Persistência opcional (metadata das sessões + dismissed, SEM output): sem
	// isso, um restart/deploy do hub esquece TODO o estado e sessões concluídas
	// reaparecem como "rodando" até falarem com o hub de novo. path=="" → só
	// memória. persistMu serializa as gravações (mesma corrida de I/O do SEC-105).
	path      string
	persistMu sync.Mutex
}

// persistState é o formato em disco: sessões (sem output) + ids apagados.
type persistState struct {
	Sessions  []session.Session `json:"sessions"`
	Dismissed []string          `json:"dismissed"`
}

// persistSessionTTL descarta, no load, sessões paradas há mais que isso — evita
// o arquivo crescer sem limite com sessões velhas que ninguém vai mais abrir.
const persistSessionTTL = 7 * 24 * time.Hour

// New cria um Registry vazio, só em memória.
func New() *Registry {
	return &Registry{
		byID:      make(map[string]session.Session),
		subs:      make(map[*Subscription]struct{}),
		outputs:   make(map[string][]OutputChunk),
		outSubs:   make(map[*OutputSub]struct{}),
		dismissed: make(map[string]bool),
	}
}

// NewAt cria um Registry que persiste metadata das sessões em JSON no arquivo
// path e recarrega o que houver lá (as sessões sobrevivem a restart/deploy). O
// output NÃO é persistido (é re-obtido ao vivo). Erros de leitura são tolerados.
func NewAt(path string) *Registry {
	r := New()
	r.path = path
	r.load()
	return r
}

// load recarrega sessões + dismissed do disco (best-effort, só no boot). Sessões
// paradas há mais que o TTL são descartadas.
func (r *Registry) load() {
	if r.path == "" {
		return
	}
	b, err := os.ReadFile(r.path)
	if err != nil {
		return
	}
	var ps persistState
	if err := json.Unmarshal(b, &ps); err != nil {
		return
	}
	cutoff := time.Now().Add(-persistSessionTTL)
	r.mu.Lock()
	for _, s := range ps.Sessions {
		if s.ID == "" || s.UpdatedAt.Before(cutoff) {
			continue
		}
		r.byID[s.ID] = s
	}
	for _, id := range ps.Dismissed {
		if id != "" {
			r.dismissed[id] = true
		}
	}
	r.mu.Unlock()
}

// snapshot copia o estado persistível sob RLock (para o persist gravar fora do
// lock de escrita).
func (r *Registry) snapshot() persistState {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ps := persistState{
		Sessions:  make([]session.Session, 0, len(r.byID)),
		Dismissed: make([]string, 0, len(r.dismissed)),
	}
	for _, s := range r.byID {
		ps.Sessions = append(ps.Sessions, s)
	}
	for id, d := range r.dismissed {
		if d {
			ps.Dismissed = append(ps.Dismissed, id)
		}
	}
	return ps
}

// persist grava o estado no disco de forma atômica (tmp+rename). No-op sem path.
// DEVE ser chamado FORA do r.mu (snapshot faz RLock). persistMu serializa as
// gravações concorrentes (SEC-105).
func (r *Registry) persist() {
	if r.path == "" {
		return
	}
	r.persistMu.Lock()
	defer r.persistMu.Unlock()

	b, err := json.Marshal(r.snapshot())
	if err != nil {
		return
	}
	tmp := r.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return
	}
	_ = os.Rename(tmp, r.path)
}

// Dismissed diz se a sessão foi apagada pela usuária (para o auto-registro por
// hook não trazê-la de volta — "apaguei e volta"). Sessões lançadas/adotadas
// explicitamente ignoram isso.
func (r *Registry) Dismissed(id string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.dismissed[id]
}

// Undismiss remove a marca de apagada (ex.: ao adotar/lançar a sessão de novo
// de propósito).
func (r *Registry) Undismiss(id string) {
	r.mu.Lock()
	delete(r.dismissed, id)
	r.mu.Unlock()
	r.persist()
}

// Add insere ou substitui uma sessão e notifica os subscribers.
func (r *Registry) Add(s session.Session) {
	r.mu.Lock()
	r.byID[s.ID] = s
	r.mu.Unlock()
	r.broadcast(s)
	r.persist()
}

// AddIfAllowed insere a sessão só se o id não existir E não estiver dismissed —
// tudo sob o MESMO lock (reivindicação atômica). Usado pelos hooks: fecha a
// corrida entre o check de dismissed e o insert (review 2026-07-03, #2). Devolve
// added=false (com a sessão existente, se houver) quando não inseriu.
func (r *Registry) AddIfAllowed(s session.Session) (existing session.Session, added bool) {
	r.mu.Lock()
	if r.dismissed[s.ID] {
		r.mu.Unlock()
		return session.Session{}, false
	}
	if cur, ok := r.byID[s.ID]; ok {
		r.mu.Unlock()
		return cur, false
	}
	r.byID[s.ID] = s
	r.mu.Unlock()
	r.broadcast(s)
	r.persist()
	return s, true
}

// Reclaim marca a sessão como do hub (External=false) e atualiza título/máquina/
// agente — usado quando o Runner (autoritativo) assume uma sessão que um hook
// pode ter pré-criado como external numa corrida (senão aprovar/negar ficaria
// escondido para sempre — review 2026-07-03, #1). No-op se não existir ou já
// for do hub. Campos vazios não sobrescrevem.
func (r *Registry) Reclaim(id, title, machine, agent string) {
	r.mu.Lock()
	s, ok := r.byID[id]
	if !ok || !s.External {
		r.mu.Unlock()
		return
	}
	s.External = false
	if title != "" {
		s.Title = title
	}
	if machine != "" {
		s.Machine = machine
	}
	if agent != "" {
		s.Agent = agent
	}
	r.byID[id] = s
	r.mu.Unlock()
	r.broadcast(s)
	r.persist()
}

// AddIfAbsent insere a sessão só se o id ainda não existir, sob o mesmo lock do
// lookup (reivindicação atômica). Devolve added=true quando inseriu; caso
// contrário devolve a sessão já existente e added=false — o chamador usa isso
// para não repetir efeitos colaterais (ex.: importar histórico do transcript
// duas vezes numa corrida entre dois Adopt do mesmo id). Só faz broadcast quando
// de fato insere.
func (r *Registry) AddIfAbsent(s session.Session) (existing session.Session, added bool) {
	r.mu.Lock()
	if cur, ok := r.byID[s.ID]; ok {
		r.mu.Unlock()
		return cur, false
	}
	r.byID[s.ID] = s
	r.mu.Unlock()
	r.broadcast(s)
	r.persist()
	return s, true
}

// Get retorna a sessão pelo id; ok é false se não existir.
func (r *Registry) Get(id string) (session.Session, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	s, ok := r.byID[id]
	return s, ok
}

// List retorna todas as sessões ordenadas por CreatedAt (mais antiga primeiro).
func (r *Registry) List() []session.Session {
	r.mu.RLock()
	out := make([]session.Session, 0, len(r.byID))
	for _, s := range r.byID {
		out = append(out, s)
	}
	r.mu.RUnlock()

	sort.Slice(out, func(i, j int) bool {
		return out[i].CreatedAt.Before(out[j].CreatedAt)
	})
	return out
}

// UpdateState muda o estado de uma sessão, atualiza UpdatedAt e notifica os
// subscribers. Retorna erro se o id não existir.
func (r *Registry) UpdateState(id string, st session.State) error {
	r.mu.Lock()
	s, ok := r.byID[id]
	if !ok {
		r.mu.Unlock()
		return fmt.Errorf("registry: sessão %q não encontrada", id)
	}
	s.State = st
	s.UpdatedAt = time.Now()
	r.byID[id] = s
	r.mu.Unlock()

	r.broadcast(s)
	r.persist()
	return nil
}

// SetPane atualiza o alvo tmux ("<socket>\t<pane>") de uma sessão, se mudou.
// No-op se o id não existir, se pane vazio, ou se já for o atual (evita
// broadcast à toa). Não mexe em UpdatedAt.
func (r *Registry) SetPane(id, pane string) {
	if pane == "" {
		return
	}
	r.mu.Lock()
	s, ok := r.byID[id]
	if !ok {
		r.mu.Unlock()
		return
	}
	// Evita pane reusado apontar pra duas sessões: uma pane só pertence a UMA
	// sessão. Se outra sessão tinha essa pane (processo antigo morreu e a pane
	// foi reusada por um claude novo), tira a pane dela e, se estiver travada em
	// needs_you, marca done (é stale) — senão tocar nela abriria o terminal do
	// processo NOVO (review 2026-07-03, #3).
	var evicted []session.Session
	if s.Pane != pane {
		for oid, os := range r.byID {
			// Só colide DENTRO da mesma máquina: o alvo composto "<socket>\t<pane>"
			// não carrega a máquina, e defaults do tmux (socket "default", pane
			// "%0") coincidem entre máquinas diferentes — sem o filtro de machine,
			// uma sessão de outra máquina seria evictada à toa (review SEC-104).
			if oid != id && os.Pane == pane && os.Machine == s.Machine {
				os.Pane = ""
				if os.State == session.StateNeedsYou {
					os.State = session.StateDone
					os.UpdatedAt = time.Now()
					os.PendingPrompt = ""
				}
				r.byID[oid] = os
				evicted = append(evicted, os)
			}
		}
	}
	changed := s.Pane != pane
	s.Pane = pane
	r.byID[id] = s
	r.mu.Unlock()

	for _, e := range evicted {
		r.broadcast(e)
	}
	if changed {
		r.broadcast(s)
	}
	if changed || len(evicted) > 0 {
		r.persist()
	}
}

// SetPendingPrompt define o texto do pedido pendente de uma sessão e notifica
// os subscribers (o app precisa exibir o texto antes de a usuária aprovar).
// No-op se o id não existir ou se o texto já for o atual (evita broadcast à
// toa). Não mexe em UpdatedAt: a transição de estado é quem marca o tempo.
func (r *Registry) SetPendingPrompt(id, text string) {
	r.mu.Lock()
	s, ok := r.byID[id]
	if !ok || s.PendingPrompt == text {
		r.mu.Unlock()
		return
	}
	s.PendingPrompt = text
	r.byID[id] = s
	r.mu.Unlock()

	r.broadcast(s)
	r.persist()
}

// ClearPendingPrompt limpa o pedido pendente e notifica os subscribers. No-op
// se o id não existir ou se já estiver vazio (idempotente, sem broadcast à toa).
func (r *Registry) ClearPendingPrompt(id string) {
	r.mu.Lock()
	s, ok := r.byID[id]
	if !ok || s.PendingPrompt == "" {
		r.mu.Unlock()
		return
	}
	s.PendingPrompt = ""
	r.byID[id] = s
	r.mu.Unlock()

	r.broadcast(s)
	r.persist()
}

// Subscribe cria uma inscrição nas mudanças do Registry. Cada Add/UpdateState
// envia a sessão afetada para C.
func (r *Registry) Subscribe() *Subscription {
	ch := make(chan session.Session, subBuffer)
	rch := make(chan string, subBuffer)
	sub := &Subscription{C: ch, ch: ch, Removed: rch, removedCh: rch}
	r.mu.Lock()
	r.subs[sub] = struct{}{}
	r.mu.Unlock()
	return sub
}

// Unsubscribe encerra a inscrição e fecha seus canais. É idempotente.
func (r *Registry) Unsubscribe(sub *Subscription) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.subs[sub]; !ok {
		return
	}
	delete(r.subs, sub)
	close(sub.ch)
	close(sub.removedCh)
}

// Remove apaga a sessão e seu buffer de output; retorna false se não existia.
// Notifica os subscribers pelo canal Removed. Remoção NÃO é transição de estado
// (o Engine segue o único a fazer UpdateState) — é uma operação de ciclo de vida
// que o Registry expõe direto, usada pelo Launcher.Remove (apagar sessão).
func (r *Registry) Remove(id string) bool {
	r.mu.Lock()
	_, hadSession := r.byID[id]
	_, hadOutput := r.outputs[id]
	delete(r.byID, id)
	delete(r.outputs, id)
	r.dismissed[id] = true // apagada de propósito: não deixar hook re-criar
	r.mu.Unlock()
	r.persist() // dismissed mudou (e talvez byID); grava mesmo se a sessão não existia
	if !hadSession && !hadOutput {
		return false
	}
	r.broadcastRemoved(id)
	return true
}

// broadcastRemoved envia o id removido a todos os subscribers, sem bloquear.
// Só corre sob RLock; Unsubscribe (que fecha removedCh) usa Lock exclusivo, então
// close nunca corre concorrente com este send (sem panic de send-on-closed).
func (r *Registry) broadcastRemoved(id string) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for sub := range r.subs {
		select {
		case sub.removedCh <- id:
		default:
		}
	}
}

// broadcast envia a sessão a todos os subscribers, sem bloquear.
func (r *Registry) broadcast(s session.Session) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for sub := range r.subs {
		select {
		case sub.ch <- s:
		default: // subscriber lento: descarta em vez de travar
		}
	}
}
