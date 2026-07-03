package registry

// maxOutputChunks é quantos pedaços de output são guardados por sessão. Cobre
// tanto o output ao vivo quanto o histórico importado ao adotar uma sessão do
// Mac (Launcher.Adopt → importTranscript); mantém os mais recentes. 500 cobre
// a grande maioria das conversas; sessões maiores mostram os 500 chunks finais.
const maxOutputChunks = 500

// OutputChunk é um pedaço de output TIPADO de uma sessão: Kind ∈
// {user, assistant, tool, tool_result} (ver internal/event) e o texto já
// resumido/truncado pelo adapter. É o contrato exposto ao app (REST
// GET /sessions/{id}/output e WS output_chunk).
type OutputChunk struct {
	Kind string `json:"kind"`
	Text string `json:"text"`
}

// OutputEvent é um pedaço de output de uma sessão, entregue aos subscribers.
type OutputEvent struct {
	SessionID string `json:"session_id"`
	Kind      string `json:"kind"`
	Text      string `json:"data"`
}

// AppendOutput guarda mais um pedaço de output tipado da sessão (mantendo só
// os maxOutputChunks mais recentes) e notifica os subscribers de output.
func (r *Registry) AppendOutput(sessionID, kind, text string) {
	r.mu.Lock()
	buf := append(r.outputs[sessionID], OutputChunk{Kind: kind, Text: text})
	if len(buf) > maxOutputChunks {
		// Mantém a janela dos mais recentes, copiando para não segurar o array
		// antigo inteiro em memória.
		trimmed := make([]OutputChunk, maxOutputChunks)
		copy(trimmed, buf[len(buf)-maxOutputChunks:])
		buf = trimmed
	}
	r.outputs[sessionID] = buf
	r.mu.Unlock()

	r.broadcastOutput(OutputEvent{SessionID: sessionID, Kind: kind, Text: text})
}

// Output retorna uma cópia dos pedaços de output guardados para a sessão.
func (r *Registry) Output(sessionID string) []OutputChunk {
	r.mu.RLock()
	defer r.mu.RUnlock()
	src := r.outputs[sessionID]
	if len(src) == 0 {
		return nil
	}
	out := make([]OutputChunk, len(src))
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

// OutputSub é a inscrição no stream de output. Consuma de C e chame
// UnsubscribeOutput ao terminar.
type OutputSub struct {
	C  <-chan OutputEvent
	ch chan OutputEvent
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
