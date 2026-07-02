// Package registry mantém o Session Registry em memória: a fonte da verdade
// das sessões conhecidas pelo hub (ver docs/02-arquitetura.md). É thread-safe e
// permite que interessados (ex.: o WebSocket) assinem mudanças via canal.
package registry

import (
	"fmt"
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
}

// Registry guarda as sessões em memória de forma thread-safe.
type Registry struct {
	mu      sync.RWMutex
	byID    map[string]session.Session
	subs    map[*Subscription]struct{}
	outputs map[string][]string
	outSubs map[*OutputSub]struct{}
}

// New cria um Registry vazio.
func New() *Registry {
	return &Registry{
		byID:    make(map[string]session.Session),
		subs:    make(map[*Subscription]struct{}),
		outputs: make(map[string][]string),
		outSubs: make(map[*OutputSub]struct{}),
	}
}

// Add insere ou substitui uma sessão e notifica os subscribers.
func (r *Registry) Add(s session.Session) {
	r.mu.Lock()
	r.byID[s.ID] = s
	r.mu.Unlock()
	r.broadcast(s)
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
	return nil
}

// Subscribe cria uma inscrição nas mudanças do Registry. Cada Add/UpdateState
// envia a sessão afetada para C.
func (r *Registry) Subscribe() *Subscription {
	ch := make(chan session.Session, subBuffer)
	sub := &Subscription{C: ch, ch: ch}
	r.mu.Lock()
	r.subs[sub] = struct{}{}
	r.mu.Unlock()
	return sub
}

// Unsubscribe encerra a inscrição e fecha seu canal. É idempotente.
func (r *Registry) Unsubscribe(sub *Subscription) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.subs[sub]; !ok {
		return
	}
	delete(r.subs, sub)
	close(sub.ch)
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
