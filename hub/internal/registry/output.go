package registry

// maxOutputChunks é quantos pedaços de output são guardados por sessão. Só o
// output recente interessa (output ao vivo no app); o histórico completo vive
// na sessão real do agente.
const maxOutputChunks = 200

// OutputEvent é um pedaço de output de uma sessão, entregue aos subscribers.
type OutputEvent struct {
	SessionID string `json:"session_id"`
	Data      string `json:"data"`
}

// OutputSub é a inscrição no stream de output. Consuma de C e chame
// UnsubscribeOutput ao terminar.
type OutputSub struct {
	C  <-chan OutputEvent
	ch chan OutputEvent
}

// AppendOutput guarda mais um pedaço de output da sessão (mantendo só os
// maxOutputChunks mais recentes) e notifica os subscribers de output.
func (r *Registry) AppendOutput(sessionID, data string) {
	r.mu.Lock()
	buf := append(r.outputs[sessionID], data)
	if len(buf) > maxOutputChunks {
		// Mantém a janela dos mais recentes, copiando para não segurar o array
		// antigo inteiro em memória.
		trimmed := make([]string, maxOutputChunks)
		copy(trimmed, buf[len(buf)-maxOutputChunks:])
		buf = trimmed
	}
	r.outputs[sessionID] = buf
	r.mu.Unlock()

	r.broadcastOutput(OutputEvent{SessionID: sessionID, Data: data})
}

// Output retorna uma cópia dos pedaços de output guardados para a sessão.
func (r *Registry) Output(sessionID string) []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	src := r.outputs[sessionID]
	if len(src) == 0 {
		return nil
	}
	out := make([]string, len(src))
	copy(out, src)
	return out
}

// SubscribeOutput cria uma inscrição no stream de output das sessões.
func (r *Registry) SubscribeOutput() *OutputSub {
	ch := make(chan OutputEvent, subBuffer)
	sub := &OutputSub{C: ch, ch: ch}
	r.mu.Lock()
	r.outSubs[sub] = struct{}{}
	r.mu.Unlock()
	return sub
}

// UnsubscribeOutput encerra a inscrição de output e fecha seu canal. É idempotente.
func (r *Registry) UnsubscribeOutput(sub *OutputSub) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.outSubs[sub]; !ok {
		return
	}
	delete(r.outSubs, sub)
	close(sub.ch)
}

// broadcastOutput envia o evento a todos os subscribers de output, sem bloquear.
func (r *Registry) broadcastOutput(ev OutputEvent) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for sub := range r.outSubs {
		select {
		case sub.ch <- ev:
		default: // subscriber lento: descarta em vez de travar
		}
	}
}
