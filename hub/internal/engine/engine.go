// Package engine é o State Engine: consome eventos normalizados e move cada
// sessão pela máquina de estados (docs/03-modelo-de-estado.md), atualizando o
// Registry. É a única peça que escreve o estado das sessões.
//
// [16/08/2026] Ressalva: esta frase é o contrato central do projeto, e não é
// enfraquecida pelo que segue — mas hoje ela não é 100% literal. Existem
// bypasses conhecidos que decidem/escrevem estado de sessão sem passar por
// aqui (em internal/launcher/launcher.go — ver o comentário revisado no topo
// daquele arquivo —, e também em internal/registry/registry.go SetPane e
// internal/reaper/reaper.go), catalogados com linha, motivo e proteção na
// tabela "Bypasses conhecidos do contrato" de docs/02-arquitetura.md. São
// dívida técnica conhecida e indesejada, não permissão: o Engine continua
// sendo a ÚNICA peça que DEVERIA escrever estado, e todo bypass novo deve
// entrar naquela tabela, não crescer por fora dela em silêncio.
package engine

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/event"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// HistoryWriter é o write-through opcional do histórico (Postgres). O Engine —
// único escritor do estado — alimenta cada transição/evento aqui, de forma
// ASSÍNCRONA (fila + goroutine), para o Apply nunca bloquear em I/O de banco.
// Definido aqui (não importa o pacote history) para não inverter a dependência.
type HistoryWriter interface {
	UpsertSession(ctx context.Context, s session.Session) error
	AppendEvent(ctx context.Context, ev event.Event) error
}

// histBuffer é o teto da fila de escrita do histórico. Cheia (Postgres lento/
// fora do ar) → o evento é descartado (best-effort), NUNCA trava o Apply.
const histBuffer = 2048

// histWriteTimeout limita cada escrita no banco para uma conexão pendurada não
// segurar a goroutine de histórico para sempre.
const histWriteTimeout = 5 * time.Second

// maxCASAttempts é o teto defensivo dos loops de releitura+CAS (Sequências A e
// D, [16/08/2026]). Na prática só 2-3 escritores concorrentes são plausíveis
// por sessão — o teto existe só para uma contenção patológica futura não
// travar Apply/ensureRunning num loop indefinido; excedê-lo loga um Warn e
// desiste (a mesma filosofia "falha e conta" da Opção 2, nunca um hang mudo).
const maxCASAttempts = 8

// Engine aplica eventos ao Registry.
type Engine struct {
	reg      *registry.Registry
	hist     HistoryWriter
	histCh   chan histOp
	histDone chan struct{}
}

// histOp é uma escrita enfileirada: sempre um AppendEvent; upsert=true também
// grava/atualiza a linha da sessão (transições e criação).
type histOp struct {
	ev     event.Event
	upsert bool
}

// New cria um State Engine sobre o Registry dado (sem histórico).
func New(reg *registry.Registry) *Engine {
	return &Engine{reg: reg}
}

// NewWithHistory cria um Engine que faz write-through assíncrono do histórico.
// Chame Close no shutdown para drenar a fila.
func NewWithHistory(reg *registry.Registry, hist HistoryWriter) *Engine {
	e := &Engine{
		reg:      reg,
		hist:     hist,
		histCh:   make(chan histOp, histBuffer),
		histDone: make(chan struct{}),
	}
	go e.histLoop()
	return e
}

// record enfileira uma escrita de histórico (não-bloqueante: fila cheia dropa).
func (e *Engine) record(ev event.Event, upsert bool) {
	if e.hist == nil {
		return
	}
	select {
	case e.histCh <- histOp{ev: ev, upsert: upsert}:
	default:
		slog.Warn("history: fila cheia, evento descartado", "session", ev.SessionID, "type", ev.Type)
	}
}

// histLoop drena a fila e escreve no banco (best-effort; erro só loga).
func (e *Engine) histLoop() {
	defer close(e.histDone)
	for op := range e.histCh {
		ctx, cancel := context.WithTimeout(context.Background(), histWriteTimeout)
		if err := e.hist.AppendEvent(ctx, op.ev); err != nil {
			slog.Warn("history: falha ao gravar evento", "session", op.ev.SessionID, "err", err)
		}
		if op.upsert {
			// Relê a sessão no momento da escrita: reflete o estado já aplicado.
			if s, ok := e.reg.Get(op.ev.SessionID); ok {
				if err := e.hist.UpsertSession(ctx, s); err != nil {
					slog.Warn("history: falha ao gravar sessão", "session", op.ev.SessionID, "err", err)
				}
			}
		}
		cancel()
	}
}

// Close drena a fila de histórico e espera a goroutine terminar (shutdown).
func (e *Engine) Close() {
	if e.hist == nil {
		return
	}
	close(e.histCh)
	<-e.histDone
}

// Apply processa um evento normalizado, ajustando o estado da sessão.
//
//   - session_started: cria a sessão (running) se não existir, ou a devolve a
//     running (novo disparo sobre idle/done/error).
//   - output_chunk: mantém o estado (a sessão segue running); o armazenamento
//     do output é feito à parte (ver registry.AppendOutput).
//   - needs_input / permission_requested: → needs_you (e guarda o PendingPrompt).
//   - user_responded: → running (a usuária aprovou/respondeu).
//   - finished: → done.
//   - errored: → error.
//   - session_ended: → idle, mas SÓ saindo de running/needs_you (o processo do
//     agente saiu; done/error já têm veredito e não são rebaixados).
//
// Regra de desempate (doc 03): na dúvida, prefira needs_you a assumir done —
// por isso needs_input/permission_requested levam a needs_you a partir de
// qualquer estado, inclusive done. Eventos para sessões desconhecidas (exceto
// session_started) e transições redundantes são ignorados sem erro.
func (e *Engine) Apply(ev event.Event) {
	switch ev.Type {
	case event.SessionStarted:
		e.ensureRunning(ev)
		e.record(ev, true) // cria/atualiza a linha da sessão no histórico
		return
	case event.OutputChunk:
		// Mantém o estado (a sessão segue running); só guarda o output para o
		// stream ao vivo. Ignora output de sessão desconhecida.
		if _, ok := e.reg.Get(ev.SessionID); ok {
			e.reg.AppendOutput(ev.SessionID, ev.Kind, ev.Data)
			e.record(ev, false) // log do output (só append; estado não muda)
		}
		return
	}

	target, ok := targetState(ev.Type)
	if !ok {
		return // tipo sem efeito de estado
	}
	// [16/08/2026] Sequência A (nota de memória "Backend — Corrida Lógica no
	// Engine.Apply", ACHADO 2): ler o estado fora de lock e escrever cego com
	// UpdateState é TOCTOU — um user_responded e um evento terminal concorrentes
	// para a mesma sessão podiam se entrelaçar de forma que o terminal fosse
	// sobrescrito de volta a "running". A troca ingênua para um CAS de TIRO
	// ÚNICO (from = snapshot lido uma vez) só troca de metade do bug: se o
	// user_responded escreve primeiro, é o CAS do evento terminal que perde (seu
	// `from` ficou obsoleto) e o veredito terminal é descartado — mesmo sintoma,
	// ordem espelhada. O loop abaixo RELÊ fresco a cada tentativa e reavalia as
	// MESMAS guards com o valor fresco: eventos terminais não têm guard
	// restritiva de origem, então a segunda tentativa deles sempre converge;
	// user_responded tem (a linha logo abaixo), e desiste corretamente quando já
	// não vale mais. Decisão da dona do projeto (16/08, opção 2 "falha e
	// conta"): é evento de sistema, não há usuária para avisar — perde → não
	// aplica, e o fato fica OBSERVÁVEL via slog.Debug, nunca engolido em
	// silêncio (mas também sem fingir no histórico que uma transição ocorreu:
	// e.record só roda depois do `break`, nunca dentro do loop).
	for attempt := 0; ; attempt++ {
		cur, exists := e.reg.Get(ev.SessionID)
		if !exists {
			return // sessão desconhecida: ignora
		}
		// user_responded só faz sentido saindo de needs_you (a usuária respondeu ao
		// pedido). De qualquer outro estado é no-op: evita regredir done→running numa
		// corrida entre a resposta (goroutine HTTP) e o evento terminal do stream
		// (goroutine do Runner) — ambos chamam Apply.
		if ev.Type == event.UserResponded && cur.State != session.StateNeedsYou {
			return
		}
		// session_ended (o processo do agente saiu) só rebaixa uma sessão que o hub
		// ainda achava ATIVA. De running é o caso comum; de needs_you é o mais
		// importante — uma pergunta cujo processo morreu não vai ser respondida
		// nunca, e sem isso o notifier fica re-cutucando para sempre. De done/error
		// é no-op: a sessão já tem veredito e trocá-lo por idle apagaria
		// "concluída"/"falhou" do app sem ganhar nada.
		if ev.Type == event.SessionEnded &&
			cur.State != session.StateRunning && cur.State != session.StateNeedsYou {
			return
		}
		if cur.State == target {
			return // CAS(X,X) NÃO é no-op (registry.go:346 ainda bumpa UpdatedAt e faz broadcast) — early-return continua obrigatório
		}
		if e.reg.UpdateStateIfCurrent(ev.SessionID, cur.State, target) {
			break
		}
		// Perdeu a corrida: outra goroutine escreveu entre o Get e o
		// UpdateStateIfCurrent. Só 2-3 escritores concorrentes são plausíveis por
		// sessão na prática — o teto abaixo é uma defesa contra contenção
		// patológica futura não travar o Apply num loop indefinido, não um
		// comportamento esperado do dia a dia.
		if attempt+1 >= maxCASAttempts {
			slog.Warn("engine: CAS excedeu o teto de tentativas, evento descartado (contenção patológica?)",
				"session", ev.SessionID, "event_type", ev.Type, "attempts", attempt+1)
			return
		}
		slog.Debug("engine: CAS perdeu a corrida, tentando de novo com estado fresco",
			"session", ev.SessionID, "event_type", ev.Type)
	}
	e.record(ev, true) // transição de estado → histórico

	// PendingPrompt (o texto que o app exibe): entra em needs_you com o resumo
	// do pedido; some ao sair de needs_you (aprovou/terminou/errou). O Engine
	// segue o único escritor do Registry.
	if target == session.StateNeedsYou {
		// PendingQuestions (o seletor que o app mostra em vez do sim/não): só
		// quando o pedido é a ferramenta nativa de seleção AskUserQuestion. Nos
		// demais needs_you (permissão comum ou needs_input), garante limpo —
		// senão uma pergunta de seleção anterior "vazaria" pro pedido seguinte.
		// É setado ANTES do PendingPrompt de propósito: o push de needs_you
		// dispara no broadcast do PendingPrompt, então as questions já precisam
		// estar no snapshot para o push escolher a categoria de pergunta.
		if ev.Type == event.PermissionRequested && ev.ToolName == "AskUserQuestion" {
			if qs, ok := parseQuestions(ev.Input); ok {
				e.reg.SetPendingQuestions(ev.SessionID, qs)
			} else {
				e.reg.ClearPendingQuestions(ev.SessionID)
			}
		} else {
			e.reg.ClearPendingQuestions(ev.SessionID)
		}
		e.reg.SetPendingPrompt(ev.SessionID, ev.Data)
	} else {
		e.reg.ClearPendingPrompt(ev.SessionID) // já limpa PendingQuestions junto
	}
}

// askUserQuestionsInput espelha o schema de input.questions do AskUserQuestion
// (protocolo verificado na CLI 2.1.198/2.1.206, ver docs/03): cada pergunta tem
// o texto, um header curto, se aceita múltiplas escolhas e as opções (rótulo +
// descrição) que o app oferece à usuária.
type askUserQuestionsInput struct {
	Questions []struct {
		Question    string `json:"question"`
		Header      string `json:"header"`
		MultiSelect bool   `json:"multiSelect"`
		Options     []struct {
			Label       string `json:"label"`
			Description string `json:"description"`
		} `json:"options"`
	} `json:"questions"`
}

// parseQuestions decodifica o input bruto de um AskUserQuestion em
// []session.Question (o formato que o Registry guarda e o app renderiza).
// ok=false se o input não tiver questions (JSON inválido ou array vazio) — o
// chamador trata como "sem seleção disponível" (limpa PendingQuestions).
func parseQuestions(raw json.RawMessage) ([]session.Question, bool) {
	if len(raw) == 0 {
		return nil, false
	}
	var in askUserQuestionsInput
	if err := json.Unmarshal(raw, &in); err != nil || len(in.Questions) == 0 {
		return nil, false
	}
	qs := make([]session.Question, 0, len(in.Questions))
	for _, q := range in.Questions {
		opts := make([]session.QuestionOption, 0, len(q.Options))
		for _, o := range q.Options {
			opts = append(opts, session.QuestionOption{Label: o.Label, Description: o.Description})
		}
		qs = append(qs, session.Question{
			Question:    q.Question,
			Header:      q.Header,
			MultiSelect: q.MultiSelect,
			Options:     opts,
		})
	}
	return qs, true
}

// ensureRunning garante que a sessão exista e esteja em running. Na criação,
// usa os metadados (Machine/Agent/Title) vindos do adapter no session_started —
// mantendo o Engine como único escritor do Registry.
func (e *Engine) ensureRunning(ev event.Event) {
	now := time.Now()
	// Reivindicação atômica (checa presença + insere no MESMO lock): fecha a
	// corrida entre Get e Add quando hook e Runner criam a MESMA sessão nova ao
	// mesmo tempo — um Add bruto sobrescreveria silenciosamente o estado que o
	// outro já avançou (ex.: needs_you + PendingPrompt), deixando o processo real
	// travado sem badge visível (review SEC-106, mesmo padrão do SEC-103).
	cur, added := e.reg.AddIfAbsent(session.Session{
		ID:      ev.SessionID,
		Machine: ev.Machine,
		Agent:   ev.Agent,
		Title:   ev.Title,
		State:   session.StateRunning,
		Cwd:     ev.Cwd,
		Model:   ev.Model,
		// Pane entra VAZIO de propósito: quem grava o pane é SEMPRE o SetPane
		// abaixo, porque é lá (e só lá) que o dono anterior daquele pane é
		// despejado. Nascer já com o pane preenchido era o bug que deixava três
		// sessões "vivas" reivindicando o mesmo terminal.
		Pane:      "",
		External:  ev.External,
		CreatedAt: now,
		UpdatedAt: now,
	})
	if added {
		e.reg.SetPane(ev.SessionID, ev.Pane)
		return
	}
	// Já existia (re-disparo ou corrida): reconcilia sem sobrescrever.
	// Se o evento é do Runner (autoritativo, !External) e a sessão foi
	// pré-criada como external por um hook, o hub reassume o controle dela
	// (senão aprovar/negar ficaria escondido pra sempre — #1).
	if !ev.External && cur.External {
		e.reg.Reclaim(ev.SessionID, ev.Title, ev.Machine, ev.Agent)
	} else if ev.Title != "" && ev.Title != cur.Title {
		// Hook trouxe um título e a sessão JÁ existia. Sem isto o título só era
		// gravado no AddIfAbsent acima, e o Reclaim (única outra escrita) exige
		// evento do Runner — então uma sessão registrada antes de o nome ser
		// conhecido ficava com o palpite pelo cwd PARA SEMPRE. Na prática: todo
		// agente do Maestri aparecia como "personal", porque o cwd é
		// .maestri/roles/<uuid> e o hub cai na pasta significativa mais próxima.
		// O nome vem do role.json, que só existe na máquina de origem — o hub
		// roda no macmini e não tem como descobrir sozinho.
		// SetTitleIfExternal recusa sessão do Runner: lá a autoridade é dele.
		e.reg.SetTitleIfExternal(ev.SessionID, ev.Title)
	}
	// [16/08/2026] `cur` vem do AddIfAbsent no TOPO de ensureRunning — pode estar
	// obsoleto: uma escrita concorrente de OUTRO evento (ex.: Finished/Errored
	// via Apply, para a MESMA sessão) pode ter mudado o estado real nesta
	// janela. session_started tem um contrato diferente do da Sequência A: não
	// existe um `from` único — é "force running seja qual for o estado
	// anterior" — então não há guard de origem que precise desistir; a segunda
	// tentativa do loop sempre converge. Relendo fresco a cada iteração (em vez
	// de confiar no `cur` velho) preserva esse override incondicional sem
	// arriscar pular a escrita (achando erradamente que já era running) nem
	// sobrescrever um veredito terminal genuíno que chegou nessa janela.
	for attempt := 0; ; attempt++ {
		fresh, ok := e.reg.Get(ev.SessionID)
		if !ok {
			break // sessão sumiu (Remove concorrente) — nada a forçar
		}
		if fresh.State == session.StateRunning {
			break // já é running (idempotente)
		}
		if e.reg.UpdateStateIfCurrent(ev.SessionID, fresh.State, session.StateRunning) {
			break
		}
		if attempt+1 >= maxCASAttempts {
			slog.Warn("engine: ensureRunning CAS excedeu o teto de tentativas, desistindo (contenção patológica?)",
				"session", ev.SessionID, "attempts", attempt+1)
			break
		}
		// perdeu: tenta de novo com o estado fresco (mesmo raciocínio da Sequência A acima)
	}
	e.reg.SetPane(ev.SessionID, ev.Pane)
}

// SetPane atualiza o alvo tmux de uma sessão existente (usado pelos hooks para
// gravar o pane numa sessão que já foi registrada antes de o pane ser conhecido).
func (e *Engine) SetPane(id, pane string) { e.reg.SetPane(id, pane) }

// EnsureRegistered registra a sessão (como running) se ela ainda NÃO existir —
// usado pelos hooks do Claude Code para que QUALQUER sessão no Mac (não só as
// lançadas pelo hub) apareça e possa cutucar. No-op se já conhecida (não mexe
// no estado atual). machine/agent vazios ganham defaults.
func (e *Engine) EnsureRegistered(id, machine, agent, title, cwd, pane string) {
	if id == "" {
		return
	}
	if machine == "" {
		machine = "mac"
	}
	if agent == "" {
		agent = "claude-code"
	}
	now := time.Now()
	// Reivindicação atômica (checa dismissed + insere no MESMO lock): fecha a
	// corrida entre Get/Dismissed/Add e o Undismiss+AddIfAbsent do Adopt (#2).
	e.reg.AddIfAllowed(session.Session{
		ID:      id,
		Machine: machine,
		Agent:   agent,
		Title:   title,
		State:   session.StateRunning,
		Cwd:     cwd,
		// Pane vazio aqui pelo mesmo motivo do ensureRunning: só o SetPane
		// abaixo despeja o dono anterior do terminal.
		Pane:      "",
		External:  true, // veio de hook — o hub não controla o gate dela
		CreatedAt: now,
		UpdatedAt: now,
	})
	e.reg.SetPane(id, pane)
}

// Idle rebaixa para idle uma sessão que o reaper concluiu estar parada, mas SÓ
// se o estado atual ainda for `from`. O compare-and-swap é o que fecha a corrida
// inerente ao reaper: entre consultar o oráculo (ssh, até 15s) e escrever, a
// sessão pode ter voltado a rodar ou virado needs_you. ok=false = alguém chegou
// primeiro, e o reaper não insiste.
//
// idle não dispara push (o notifier trata running/idle no ramo default), então
// ceifar N zumbis não vira N notificações falsas de "concluído" no celular.
func (e *Engine) Idle(id string, from session.State) bool {
	if !e.reg.UpdateStateIfCurrent(id, from, session.StateIdle) {
		return false
	}
	e.reg.ClearPendingPrompt(id) // limpa PendingQuestions junto
	e.record(event.Event{
		SessionID: id,
		Type:      event.Reaped,
		Data:      "reaper: sessão parada, transcript ainda no disco → idle",
		At:        time.Now(),
	}, true)
	return true
}

// RecordForgotten deixa rastro no histórico de uma sessão que o reaper apagou do
// Registry (Registry.Forget). Sem isso a última linha em cutuque.sessions ficaria
// congelada em "running" para sempre, e a usuária não teria como entender, dias
// depois, por que uma sessão sumiu sem nunca ter dado Stop. upsert=false: a
// sessão já não existe no Registry para ser relida.
func (e *Engine) RecordForgotten(id string) {
	e.record(event.Event{
		SessionID: id,
		Type:      event.Reaped,
		Data:      "reaper: transcript não existe mais no disco → esquecida",
		At:        time.Now(),
	}, false)
}

// targetState mapeia um tipo de evento para o estado-alvo. ok=false quando o
// tipo não altera o estado.
func targetState(t event.Type) (session.State, bool) {
	switch t {
	case event.NeedsInput, event.PermissionRequested:
		return session.StateNeedsYou, true
	case event.UserResponded:
		return session.StateRunning, true
	case event.Finished:
		return session.StateDone, true
	case event.Errored:
		return session.StateError, true
	case event.SessionEnded:
		return session.StateIdle, true
	default:
		return "", false
	}
}
