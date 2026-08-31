package registry

// maxOutputChunks é quantos pedaços de output são guardados por sessão. Cobre
// tanto o output ao vivo quanto o histórico importado ao adotar uma sessão do
// Mac (Launcher.Adopt → importTranscript); mantém os mais recentes.
//
// 31/08/2026 — subiu de 500 para 2000 a pedido da Vanessa ("aumente o view de
// mensagens antigas, acho que ta 500, pode subir pra 2000"): no iPhone e no
// iPad a conversa inteira precisa caber na tela sem ter de pedir resumo. O
// teto do app (`SessionDetailViewModel.maxChunks`) é o MESMO número de
// propósito — app e hub cortando em pontos diferentes davam a impressão de
// mensagem sumida.
const maxOutputChunks = 2000

// maxOutputBytes é o orçamento de texto por sessão. Existe porque
// maxOutputChunks sozinho não limita memória: um chunk de assistant não tem
// teto de tamanho (só tool e tool_result têm), então 2000 chunks gordos de uma
// sessão longa poderiam pesar mais do que o Mac mini quer segurar por sessão.
//
// Com os dois tetos o pior caso de uma sessão é 8 MiB de texto, com UMA
// exceção que o trimOutput assume de propósito: um único chunk maior que o
// orçamento inteiro fica sozinho na janela e a estoura por conta própria. É
// melhor que a alternativa (devolver janela vazia), mas não é um teto duro —
// quem quiser um teto duro precisa truncar o chunk no adapter, onde hoje só
// tool e tool_result são truncados.
//
// O corte é sempre pelos MAIS ANTIGOS, igual ao corte por quantidade — quem
// abre a tela quer o fim da conversa.
const maxOutputBytes = 8 << 20

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
// os mais recentes que cabem nos dois tetos — maxOutputChunks e
// maxOutputBytes) e notifica os subscribers de output.
func (r *Registry) AppendOutput(sessionID, kind, text string) {
	r.mu.Lock()
	r.outputs[sessionID] = trimOutput(append(r.outputs[sessionID], OutputChunk{Kind: kind, Text: text}))
	r.mu.Unlock()

	r.broadcastOutput(OutputEvent{SessionID: sessionID, Kind: kind, Text: text})
}

// trimOutput corta o buffer da sessão pelos MAIS ANTIGOS até caber nos dois
// tetos, devolvendo sempre uma fatia nova quando corta — copiar é o que solta
// o array antigo inteiro para o GC em vez de segurá-lo por uma fatia curta.
//
// A conta de bytes é uma varredura, não um contador guardado ao lado do mapa:
// `outputs` é apagado em dois pontos do registry (Remove e Forget — o reaper
// chega lá pelo próprio Forget, não apaga por fora), e um contador paralelo
// teria de ser zerado nos dois — um esquecimento ali vazaria orçamento para
// sempre. A varredura é no máximo maxOutputChunks
// leituras de `len(string)` (O(1) cada) por chunk recebido, o que é ruído
// perto do custo de já ter falado com o agente pela rede.
func trimOutput(buf []OutputChunk) []OutputChunk {
	corte := 0
	if len(buf) > maxOutputChunks {
		corte = len(buf) - maxOutputChunks
	}
	bytes := 0
	for i := len(buf) - 1; i >= corte; i-- {
		bytes += len(buf[i].Text)
		if bytes > maxOutputBytes {
			// O chunk `i` é o que estourou: a janela começa no seguinte. Um
			// único chunk maior que o orçamento inteiro cai aqui também e a
			// janela fica só com ele (i == len(buf)-1 → corte = len(buf)-1),
			// que é o certo: melhor a última mensagem sozinha do que nenhuma.
			corte = i + 1
			if corte > len(buf)-1 {
				corte = len(buf) - 1
			}
			break
		}
	}
	if corte == 0 {
		return buf
	}
	trimmed := make([]OutputChunk, len(buf)-corte)
	copy(trimmed, buf[corte:])
	return trimmed
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
