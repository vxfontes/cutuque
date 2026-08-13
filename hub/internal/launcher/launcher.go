// Package launcher lança tarefas nas máquinas-alvo e fecha o laço de controle
// bidirecional: aprovar/negar pedidos de permissão e enviar texto às sessões
// vivas (docs/02-arquitetura.md, Command API → Adapter).
//
// O Launcher decora o State Engine como um Applier: intercepta os eventos do
// Runner para guardar o pedido de permissão pendente (o request_id nativo e o
// input original da ferramenta), mas delega SEMPRE ao Engine — que segue o
// único escritor do Registry. Aprovar/negar exige que a sessão esteja mesmo em
// needs_you (rejeita ação obsoleta) e nunca aprova sem que o app tenha exibido
// o texto do pedido (invariante de segurança do docs/03).
package launcher

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/event"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// Erros tipados, mapeados para os status HTTP pelos handlers REST.
var (
	ErrUnknownMachine   = errors.New("launcher: máquina desconhecida")
	ErrUnknownAgent     = errors.New("launcher: agente desconhecido")
	ErrLaunchTimeout    = errors.New("launcher: timeout esperando session_started")
	ErrUnknownSession   = errors.New("launcher: sessão desconhecida")
	ErrStaleState       = errors.New("launcher: estado obsoleto (não está em needs_you)")
	ErrNoHandle         = errors.New("launcher: sessão sem canal vivo")
	ErrTooManySessions  = errors.New("launcher: limite de sessões concorrentes atingido (SEC-007)")
	ErrShuttingDown     = errors.New("launcher: hub está encerrando")
	ErrInvalidSessionID = errors.New("launcher: id de sessão inválido")
	ErrDiscoverFailed   = errors.New("launcher: falha ao descobrir sessões na máquina")
	ErrInvalidAnswer    = errors.New("launcher: resposta inválida (pergunta desconhecida ou vazia)")
	ErrNoShell          = errors.New("launcher: máquina não abre terminal (é o próprio hub)")
)

// toolAskUserQuestion é o tool_name nativo da pergunta de seleção do Claude Code.
// O pending guarda o toolName para distinguir uma pergunta (respondida via
// Answer, com updatedInput{questions,answers}) de um pedido comum de permissão
// (Approve/Deny binário). Sem essa checagem, um /answer numa permissão de Bash
// mandaria "allow" com o input da ferramenta substituído (SEC-111).
const toolAskUserQuestion = "AskUserQuestion"

// sessionIDPattern valida o id de uma sessão adotada. Cobre os formatos dos três
// agentes: UUID do Claude/Codex (hex + hífens) e o `ses_<base62>` do OpenCode
// (alfanumérico + underscore). Allowlist estrita (sem metacaractere de shell,
// espaço ou aspas) — defesa em profundidade contra qualquer coisa perigosa
// chegar em `--resume`/`-s <id>` (SEC-101), além do escape estrutural do comando.
var sessionIDPattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{8,80}$`)

// discoverTimeout limita quanto Discover espera o ssh/python remoto responder,
// para um alvo pendurado (rede/NFS travada) não segurar o request HTTP nem o
// processo até o Shutdown do hub.
const discoverTimeout = 15 * time.Second

// agentClaudeCode é o único agente suportado nesta fase (dev).
const agentClaudeCode = "claude-code"

// denyMessage é a justificativa enviada ao agente ao negar uma permissão.
const denyMessage = "negado pela usuária via Cutuque"

// defaultMaxSessions é o teto de sessões concorrentes vivas quando ninguém
// chama SetMaxSessions (SEC-007). cmd/hub sobrescreve com CUTUQUE_MAX_SESSIONS.
const defaultMaxSessions = 20

// launchTimeout é quanto Launch espera pelo session_started antes de desistir.
// Var (não const) para os testes poderem encurtar.
var launchTimeout = 20 * time.Second

// pending é o pedido de permissão vivo de uma sessão: o request_id nativo (alvo
// do control_response), o input original da ferramenta (devolvido intacto como
// updatedInput ao aprovar — protocolo verificado na CLI 2.1.198) e o
// toolName/toolUseID nativos (o tool_use_id é ecoado no control_response como
// "toolUseID", camelCase, fora do updatedInput — confirmado no SDK oficial).
// toolName distingue uma pergunta de seleção (AskUserQuestion, respondida via
// Answer) de um pedido comum de permissão (respondido via Approve/Deny).
type pending struct {
	requestID string
	input     json.RawMessage
	toolName  string
	toolUseID string
}

// Launcher lança e controla sessões de agentes nas máquinas registradas.
type Launcher struct {
	eng *engine.Engine
	reg *registry.Registry
	// targets é indexado por máquina → agente ("claude-code"|"codex") → alvo.
	// Uma máquina roda mais de um agente; o launch escolhe pelo agente pedido e o
	// resume pelo agente da sessão.
	//
	// Deixou de ser fixo em New: a aba Máquinas cadastra máquinas em runtime e o
	// alvo delas nasce junto do cadastro. As mutações SUBSTITUEM o mapa
	// (copy-on-write) em vez de escrever nele, então uma leitura em voo nunca vê
	// o mapa pela metade — mas o ponteiro em si precisa do targetsMu.
	targetsMu sync.RWMutex
	targets   map[string]map[string]claudecode.Target
	// machineKnownHosts é o known_hosts das máquinas cadastradas pelo app,
	// fixado no boot. Vazio = cadastro desligado (sem CUTUQUE_MACHINES_DIR).
	machineKnownHosts string

	// wg rastreia as goroutines de observação (uma por Launch, rodando
	// runner.Run) ainda vivas. Shutdown espera todas terminarem depois de
	// fechar os Handles — mesmo padrão do notifier (Close cancela e só
	// depois dá wg.Wait) para não vazar goroutine (review/patterns.md,
	// "recurso-de-longa-duração-sem-cancelamento").
	wg sync.WaitGroup

	// baseCtx é o contexto de vida das sessões (NÃO o ctx do request, que é
	// Background e nunca cancela). Shutdown cancela baseCancel para matar os
	// processos em voo — inclusive sessões cujo Handle ainda nem foi registrado
	// (review F5, achado bloqueante #2).
	baseCtx    context.Context
	baseCancel context.CancelFunc

	mu          sync.Mutex
	closed      bool                          // Shutdown em curso: Launch falha rápido
	handles     map[string]*claudecode.Handle // canal stdin/stdout por sessão viva
	pending     map[string]pending            // permissão aguardando resposta, por sessão
	maxSessions int                           // teto de sessões concorrentes vivas (SEC-007)
	histImport  map[string]struct{}           // sessões cujo transcript já foi importado (evita duplicar)
}

// New cria um Launcher sobre o Engine/Registry dados e o mapa de alvos
// (nome da máquina → Target). O Registry é consultado para validar o estado
// antes de aprovar/negar. O teto de sessões concorrentes começa em
// defaultMaxSessions; cmd/hub ajusta via SetMaxSessions com CUTUQUE_MAX_SESSIONS.
func New(eng *engine.Engine, reg *registry.Registry, targets map[string]map[string]claudecode.Target) *Launcher {
	ctx, cancel := context.WithCancel(context.Background())
	return &Launcher{
		eng:         eng,
		reg:         reg,
		targets:     targets,
		baseCtx:     ctx,
		baseCancel:  cancel,
		handles:     make(map[string]*claudecode.Handle),
		pending:     make(map[string]pending),
		maxSessions: defaultMaxSessions,
		histImport:  make(map[string]struct{}),
	}
}

// SetMaxSessions ajusta o teto de sessões concorrentes vivas (SEC-007).
// Valores não-positivos são ignorados (mantém o teto atual) — mesmo padrão de
// validação do Notifier.SetRenudgeInterval.
func (l *Launcher) SetMaxSessions(n int) {
	if n <= 0 {
		return
	}
	l.mu.Lock()
	l.maxSessions = n
	l.mu.Unlock()
}

// target resolve o alvo de um agente específico numa máquina.
func (l *Launcher) target(machine, agent string) (claudecode.Target, bool) {
	byAgent, ok := l.snapshot()[machine]
	if !ok {
		return nil, false
	}
	t, ok := byAgent[agent]
	return t, ok
}

// anyTarget resolve QUALQUER alvo da máquina, para operações agnósticas de
// agente (listar pastas, tmux, descoberta). Prefere o claude-code, preservando
// o comportamento das rotas que hoje só existem para ele.
func (l *Launcher) anyTarget(machine string) (claudecode.Target, bool) {
	byAgent, ok := l.snapshot()[machine]
	if !ok || len(byAgent) == 0 {
		return nil, false
	}
	if t, ok := byAgent[agentClaudeCode]; ok {
		return t, true
	}
	for _, t := range byAgent {
		return t, true
	}
	return nil, false
}

// Launch inicia uma tarefa na máquina dada com o prompt dado, observando-a em
// uma goroutine. Valida machine/agent (dev: só máquinas registradas + claude-code),
// rejeita acima do teto de sessões concorrentes (SEC-007, ErrTooManySessions),
// envia o prompt inicial pelo stdin e espera o session_started (até launchTimeout)
// para devolver a Session criada. cwd é a pasta onde o `claude` roda; vazio → home.
func (l *Launcher) Launch(ctx context.Context, machine, agent, prompt, cwd, model, effort, sandbox string) (session.Session, error) {
	if _, known := l.snapshot()[machine]; !known {
		return session.Session{}, ErrUnknownMachine
	}
	tgt, ok := l.target(machine, agent)
	if !ok {
		return session.Session{}, ErrUnknownAgent
	}

	// Porta fechada + teto + registro do em-voo, tudo sob o MESMO mutex:
	//   - closed: se o Shutdown começou, Launch falha rápido (não cria órfão).
	//   - teto de sessões (SEC-007): rejeita acima de maxSessions.
	//   - wg.Add ANTES do Start: a sessão em voo já conta no WaitGroup, então
	//     Shutdown sempre a espera, mesmo antes do Handle ser registrado no
	//     session_started (review F5, achado bloqueante #2).
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return session.Session{}, ErrShuttingDown
	}
	if len(l.handles) >= l.maxSessions {
		l.mu.Unlock()
		return session.Session{}, ErrTooManySessions
	}
	l.wg.Add(1)
	l.mu.Unlock()

	// A partir do wg.Add, TODA saída precisa liberar o wg (Done manual nos erros
	// abaixo; defer wg.Done na goroutine no caminho feliz). Usa l.baseCtx (não o
	// ctx do request, que é Background e nunca cancela) para que o Shutdown mate
	// o processo em voo cancelando baseCtx.
	// Start manda o prompt inicial pelo canal do agente (stdin no Claude, argumento
	// no Codex). Usa l.baseCtx (não o ctx do request, que é Background e nunca
	// cancela) para que o Shutdown mate o processo em voo cancelando baseCtx.
	handle, err := tgt.Start(l.baseCtx, "", cwd, model, effort, sandbox, prompt)
	if err != nil {
		l.wg.Done()
		return session.Session{}, err
	}

	started := make(chan session.Session, 1)
	app := &launchApplier{l: l, handle: handle, started: started, prompt: prompt}
	runner := tgt.NewRunner(app)
	go func() {
		defer l.wg.Done()
		_ = runner.Run(l.baseCtx, handle, claudecode.Meta{Machine: machine, Prompt: prompt, Cwd: cwd, Model: model})
		// Fim do stream: a sessão não tem mais canal vivo.
		if app.sessionID != "" {
			l.removeHandle(app.sessionID)
		}
		_ = handle.Close()
	}()

	select {
	case s := <-started:
		return s, nil
	case <-time.After(launchTimeout):
		_ = handle.Close()
		return session.Session{}, ErrLaunchTimeout
	}
}

// Discover lista as sessões do Claude Code já existentes na máquina (lendo
// ~/.claude/projects lá), inclusive as não lançadas pelo Cutuque. Retorna
// ErrUnknownMachine se a máquina não existe ou não suporta descoberta.
func (l *Launcher) Discover(machine string) ([]session.Discovered, error) {
	byAgent, ok := l.snapshot()[machine]
	if !ok {
		return nil, ErrUnknownMachine
	}
	// Mescla a descoberta de TODOS os agentes da máquina (Claude lê ~/.claude,
	// Codex lê ~/.codex), etiquetando cada sessão com o agente que a gerou —
	// para a adoção usar o alvo/transcript certo. Ordena por mais recente.
	var all []session.Discovered
	var lastErr error
	anyOK := false
	for kind, tgt := range byAgent {
		d, ok := tgt.(claudecode.Discoverer)
		if !ok {
			continue
		}
		ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
		list, err := d.Discover(ctx)
		cancel()
		if err != nil {
			lastErr = err
			continue
		}
		anyOK = true
		for i := range list {
			list[i].Agent = kind
		}
		all = append(all, list...)
	}
	// Todos os discoverers falharam (ssh caiu, python3 ausente…) → erro distinto
	// de "máquina desconhecida", para o handler não mascarar como 404.
	if !anyOK && lastErr != nil {
		return nil, fmt.Errorf("%w: %v", ErrDiscoverFailed, lastErr)
	}
	sort.Slice(all, func(i, j int) bool { return all[i].Modified > all[j].Modified })
	return all, nil
}

// TmuxList lista os panes do tmux rodando claude na máquina (a ponte para
// controlar/observar sessões vivas de terminal). Devolve no shape Discovered
// (id = pane_id) para o app reusar o mesmo modelo.
func (l *Launcher) TmuxList(machine string) ([]session.Discovered, error) {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return nil, ErrUnknownMachine
	}
	tm, ok := tgt.(claudecode.Tmuxer)
	if !ok {
		return nil, ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	panes, err := tm.TmuxList(ctx)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrDiscoverFailed, err)
	}
	out := make([]session.Discovered, 0, len(panes))
	for _, p := range panes {
		out = append(out, claudecode.TmuxPaneAsDiscovered(p))
	}
	return out, nil
}

// TmuxNewSession cria uma sessão tmux na máquina e devolve o alvo composto do pane
// criado ("<socket>\t<pane>"), pronto para capture/send-keys. Grupo = servidor tmux
// (-L), que é o mesmo identificador do escopo do board.
func (l *Launcher) TmuxNewSession(machine, group, sess, cwd, agent string) (string, error) {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return "", ErrUnknownMachine
	}
	tm, ok := tgt.(claudecode.Tmuxer)
	if !ok {
		return "", ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	target, err := tm.TmuxNewSession(ctx, group, sess, cwd, agent)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrDiscoverFailed, err)
	}
	return target, nil
}

// TmuxCapture devolve a tela atual do pane (espelho ao vivo).
func (l *Launcher) TmuxCapture(machine, target string) (string, error) {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return "", ErrUnknownMachine
	}
	tm, ok := tgt.(claudecode.Tmuxer)
	if !ok {
		return "", ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	screen, err := tm.TmuxCapture(ctx, target)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrDiscoverFailed, err)
	}
	return screen, nil
}

// TmuxResize fixa/restaura o tamanho da janela do pane (para caber no celular).
func (l *Launcher) TmuxResize(machine, target string, cols, rows int) error {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return ErrUnknownMachine
	}
	tm, ok := tgt.(claudecode.Tmuxer)
	if !ok {
		return ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	if err := tm.TmuxResize(ctx, target, cols, rows); err != nil {
		return fmt.Errorf("%w: %v", ErrDiscoverFailed, err)
	}
	return nil
}

// TmuxSend digita texto no pane e submete (Enter) — a mensagem do celular caindo
// no terminal que já roda.
func (l *Launcher) TmuxSend(machine, target, text string) error {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return ErrUnknownMachine
	}
	tm, ok := tgt.(claudecode.Tmuxer)
	if !ok {
		return ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	if err := tm.TmuxSend(ctx, target, text); err != nil {
		return fmt.Errorf("%w: %v", ErrDiscoverFailed, err)
	}
	return nil
}

// TmuxKey envia uma tecla nomeada (Ctrl+C, setas, Esc…) ao pane.
func (l *Launcher) TmuxKey(machine, target, key string) error {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return ErrUnknownMachine
	}
	tm, ok := tgt.(claudecode.Tmuxer)
	if !ok {
		return ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	if err := tm.TmuxKey(ctx, target, key); err != nil {
		return fmt.Errorf("%w: %v", ErrDiscoverFailed, err)
	}
	return nil
}

// TmuxKill encerra o pane alvo (kill-pane): fecha o Claude daquele terminal.
func (l *Launcher) TmuxKill(machine, target string) error {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return ErrUnknownMachine
	}
	tm, ok := tgt.(claudecode.Tmuxer)
	if !ok {
		return ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	if err := tm.TmuxKill(ctx, target); err != nil {
		return fmt.Errorf("%w: %v", ErrDiscoverFailed, err)
	}
	return nil
}

// TmuxKillServer encerra o servidor tmux inteiro do socket (todos os panes).
func (l *Launcher) TmuxKillServer(machine, socket string) error {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return ErrUnknownMachine
	}
	tm, ok := tgt.(claudecode.Tmuxer)
	if !ok {
		return ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	if err := tm.TmuxKillServer(ctx, socket); err != nil {
		return fmt.Errorf("%w: %v", ErrDiscoverFailed, err)
	}
	return nil
}

// Live lista as sessões DAQUELE AGENTE que estão RODANDO agora na máquina
// (processo vivo + transcript recente). Mesmos erros/timeout do Discover.
// agent vazio = claude-code (mesma convenção legada do Adopt).
//
// O agente é obrigatório no roteamento porque este resultado virou veredito de
// vida para o reaper. Com anyTarget, uma sessão codex era medida pelo oráculo do
// claude-code — que obviamente não a enxerga — e ia parar em Forget. Alvo que
// não implementa Liver devolve erro de propósito: "não tenho oráculo para este
// agente" tem que chegar no chamador como "não sei", nunca como lista vazia.
func (l *Launcher) Live(machine, agent string) ([]session.Discovered, error) {
	if agent == "" {
		agent = agentClaudeCode
	}
	tgt, ok := l.target(machine, agent)
	if !ok {
		return nil, ErrUnknownMachine
	}
	lv, ok := tgt.(claudecode.Liver)
	if !ok {
		return nil, ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	list, err := lv.Live(ctx)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrDiscoverFailed, err)
	}
	return list, nil
}

// HasHandle diz se o hub mantém um processo VIVO desta sessão (stdin/stdout
// abertos). É o sinal de liveness mais forte que existe — não depende de ssh,
// de ps nem de mtime de transcript — e por isso o reaper o consulta antes de
// qualquer oráculo: nada que o próprio hub está tocando pode ser ceifado.
func (l *Launcher) HasHandle(id string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	_, ok := l.handles[id]
	return ok
}

// TranscriptIDs lista os ids de TODA sessão DAQUELE AGENTE que ainda tem
// transcript no disco da máquina — resposta exata, sem corte, para "essa sessão
// ainda existe lá?". agent vazio = claude-code.
//
// Erro (ssh caído, máquina desconhecida, agente sem lister) NUNCA pode ser lido
// como "não existe": o chamador tem que tratar erro como "não sei" e não agir.
// O roteamento por agente importa duplamente aqui, porque é esta lista que
// separa "vira idle" de "some do Registry": perguntar ao ~/.claude por uma
// sessão do codex responderia "não existe" e apagaria o card.
func (l *Launcher) TranscriptIDs(machine, agent string) ([]string, error) {
	if agent == "" {
		agent = agentClaudeCode
	}
	tgt, ok := l.target(machine, agent)
	if !ok {
		return nil, ErrUnknownMachine
	}
	tl, ok := tgt.(claudecode.TranscriptLister)
	if !ok {
		return nil, ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	ids, err := tl.TranscriptIDs(ctx)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrDiscoverFailed, err)
	}
	return ids, nil
}

// Adopt registra no Registry uma sessão descoberta (idle), para que a usuária
// possa abri-la e continuar a conversa (SendText → --resume). Se já for
// conhecida, devolve a existente. ErrUnknownMachine se a máquina não existe.
func (l *Launcher) Adopt(machine, id, cwd, title, agent string) (session.Session, error) {
	if agent == "" {
		agent = agentClaudeCode // legado: adoção sem agente = Claude
	}
	tgt, ok := l.target(machine, agent)
	if !ok {
		return session.Session{}, ErrUnknownMachine
	}
	// id vira `--resume <id>` num comando remoto: só aceita o formato real de
	// session id (UUID). Defesa em profundidade contra SEC-101 além do escape
	// estrutural do remoteClaudeCommand.
	if !sessionIDPattern.MatchString(id) {
		return session.Session{}, ErrInvalidSessionID
	}
	l.reg.Undismiss(id) // adoção explícita cancela um "apagar" anterior
	now := time.Now()
	s := session.Session{
		ID:        id,
		Machine:   machine,
		Agent:     agent,
		Title:     title,
		State:     session.StateIdle,
		Cwd:       cwd,
		External:  true, // adotada (não lançada pelo hub)
		CreatedAt: now,
		UpdatedAt: now,
	}
	// Reivindicação atômica: se já existir (inclusive numa corrida entre dois
	// Adopt do mesmo id), devolve a existente e NÃO reimporta o histórico —
	// senão as mensagens apareceriam duplicadas no chat (review 2026-07-03, #3).
	existing, added := l.reg.AddIfAbsent(s)
	if !added {
		return existing, nil
	}
	// Importa o histórico do transcript do Mac (se o alvo suportar) para o chat
	// mostrar as mensagens anteriores ao abrir a sessão adotada — sem isso o
	// output começaria vazio e só o `--resume` traria conteúdo novo. Feito ANTES
	// de devolver, para que o GET /output logo após o adopt já traga o histórico.
	// Falha (ssh/python/timeout) degrada graciosamente: adota sem histórico.
	l.importTranscript(tgt, id)
	return s, nil
}

// ImportHistory carrega, SOB DEMANDA, o histórico (transcript) de uma sessão já
// registrada — usado quando a usuária abre no app uma sessão externa (de hook)
// que não foi lançada nem adotada pelo hub, para o chat mostrar a conversa em vez
// de "sem mensagens ainda" (ideia da usuária: registrar tudo e dar o recap ao
// entrar). Idempotente: importa só na primeira vez por sessão (histImport),
// senão as mensagens duplicariam. Best-effort — falha degrada para "sem histórico".
func (l *Launcher) ImportHistory(id string) error {
	s, ok := l.reg.Get(id)
	if !ok {
		return ErrUnknownSession
	}
	tgt, ok := l.target(s.Machine, s.Agent)
	if !ok {
		return ErrUnknownMachine
	}
	// id vira `--resume`/glob num comando remoto lá no adapter: valida o formato.
	if !sessionIDPattern.MatchString(id) {
		return ErrInvalidSessionID
	}
	l.mu.Lock()
	if _, done := l.histImport[id]; done {
		l.mu.Unlock()
		return nil // já importado nesta vida do hub
	}
	l.histImport[id] = struct{}{}
	l.mu.Unlock()

	l.importTranscript(tgt, id)
	return nil
}

// importTranscript lê o transcript da sessão no alvo e o adiciona ao output do
// registry, na ordem cronológica (o registry mantém os mais recentes até o
// teto). Best-effort: qualquer erro é silenciado (a adoção não deve falhar por
// causa do histórico).
func (l *Launcher) importTranscript(tgt claudecode.Target, id string) {
	tr, ok := tgt.(claudecode.Transcriber)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	chunks, err := tr.Transcript(ctx, id)
	if err != nil {
		return
	}
	for _, ch := range chunks {
		l.reg.AppendOutput(id, ch.Kind, ch.Text)
	}
}

// ListDirs lista as subpastas de path na máquina (seletor de pastas do app ao
// criar uma sessão). path vazio → home da máquina. ErrUnknownMachine se a
// máquina não existe ou não suporta listar pastas.
func (l *Launcher) ListDirs(machine, path string) (session.DirListing, error) {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return session.DirListing{}, ErrUnknownMachine
	}
	lister, ok := tgt.(claudecode.DirLister)
	if !ok {
		return session.DirListing{}, ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	return lister.ListDirs(ctx, path)
}

// ListFiles lista pastas E arquivos de path na máquina (painel Arquivos da aba
// Máquinas). path vazio → home. ErrUnknownMachine se a máquina não existe ou o
// agente dela não sabe listar arquivos.
func (l *Launcher) ListFiles(machine, path string) (session.FileListing, error) {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return session.FileListing{}, ErrUnknownMachine
	}
	lister, ok := tgt.(claudecode.FileLister)
	if !ok {
		return session.FileListing{}, ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	return lister.ListFiles(ctx, path)
}

// ReadFile lê um arquivo de texto na máquina (visualizador da aba Máquinas).
// Binário volta sem conteúdo, marcado — não é erro. Texto acima do teto volta
// com a CAUDA do arquivo (ver session.FileContent.Tail), não mais vazio
// (12/08/2026).
func (l *Launcher) ReadFile(machine, path string) (session.FileContent, error) {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return session.FileContent{}, ErrUnknownMachine
	}
	reader, ok := tgt.(claudecode.FileReader)
	if !ok {
		return session.FileContent{}, ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	return reader.ReadFile(ctx, path)
}

// WriteFile salva um arquivo de texto na máquina (editor da aba Máquinas). Só
// sobrescreve arquivo que já existe: caminho inexistente devolve
// claudecode.ErrNotAFile, que o handler traduz em 404.
func (l *Launcher) WriteFile(machine, path string, content []byte) (session.FileWrite, error) {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return session.FileWrite{}, ErrUnknownMachine
	}
	writer, ok := tgt.(claudecode.FileWriter)
	if !ok {
		return session.FileWrite{}, ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	return writer.WriteFile(ctx, path, content)
}

// downloadTimeout é o TETO PRÓPRIO do download — não os 15s do
// discoverTimeout (um arquivo de verdade pode legitimamente levar mais que
// isso para atravessar a rede), mas também não infinito. Generoso o bastante
// para o teto de 50 MB que o app aplica ANTES de pedir o download (ver desenho
// "O teto de 50 MB"), mesmo numa conexão ruim.
//
// REESCRITO 12/08/2026 (achado #2 da revisão adversarial do Task H): a versão
// anterior desta função tirou o discoverTimeout citando "a mesma razão do
// ShellCommand", mas não é a mesma razão — ShellCommand recebe o ctx de quem
// chama (a conexão WebSocket real, ver comentário dele), enquanto DownloadFile
// não recebia ctx nenhum e ficava preso só ao baseCtx (vive até o hub
// desligar). Resultado: um mount de rede travado, ou o comando remoto preso
// (o ServerAliveInterval do ssh não pega isso — é o transporte que fica de
// pé, não o comando dentro dele), nunca acionava o Close() — que só roda
// quando io.Copy retorna — e o processo cat/ssh ficava vivo até reiniciar o
// hub manualmente (a Vanessa não faz isso, ver downloadReadCloser). Trocou-se
// "download grande derruba o hub por memória" por "download travado nunca
// termina". Agora DownloadFile some as duas pontas: o ctx do handler HTTP
// (r.Context(), morre se a usuária sai da tela) E este teto próprio,
// combinados — o que vier primeiro cancela.
const downloadTimeout = 10 * time.Minute

// DownloadFile traz os bytes crus de um arquivo na máquina, EM FLUXO (download
// da aba Máquinas — inclusive binário, que o visualizador não mostra). Quem
// chama TEM que fechar o ReadCloser (defer) — é o Close() dele que espera o
// processo (cat/ssh) e evita zumbi (ver claudecode.downloadReadCloser).
//
// ctx é o da requisição HTTP (o handler passa r.Context()), somado ao teto
// próprio downloadTimeout — ver o comentário dele para a razão de existir.
func (l *Launcher) DownloadFile(ctx context.Context, machine, path string) (io.ReadCloser, error) {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return nil, ErrUnknownMachine
	}
	dl, ok := tgt.(claudecode.FileDownloader)
	if !ok {
		return nil, ErrUnknownMachine
	}
	dctx, cancel := context.WithTimeout(ctx, downloadTimeout)
	rc, err := dl.DownloadFile(dctx, path)
	if err != nil {
		cancel()
		return nil, err
	}
	return &cancelOnCloseReader{ReadCloser: rc, cancel: cancel}, nil
}

// cancelOnCloseReader libera o cancel do context.WithTimeout assim que o
// download termina (o Close do handler) — sem isto o timer do teto ficaria
// vivo até estourar sozinho mesmo num download rápido. Não chamar cancel()
// antes do Close (ex.: via defer logo após criar o contexto) cancelaria o ctx
// na hora e mataria o processo remoto imediatamente — exec.CommandContext
// mata o processo assim que o ctx é cancelado, não só quando ele expira.
type cancelOnCloseReader struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (c *cancelOnCloseReader) Close() error {
	err := c.ReadCloser.Close()
	c.cancel()
	return err
}

// ShellCommand monta (sem rodar) o comando de um shell interativo na máquina —
// o terminal livre da aba Máquinas. Quem liga o PTY e roda é o handler do
// WebSocket, que é quem tem a conexão para ligar nas duas pontas.
//
// O ctx é o da conexão, não o baseCtx com discoverTimeout: um terminal aberto
// não tem prazo, e amarrá-lo a um timeout de descoberta o mataria em 30s.
//
// ErrUnknownMachine se a máquina não existe; ErrNoShell se ela existe mas é o
// próprio hub — abrir um shell dentro do container não é entrar numa máquina, e
// a diferença precisa chegar ao app como coisas distintas.
func (l *Launcher) ShellCommand(ctx context.Context, machine string) (*exec.Cmd, error) {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return nil, ErrUnknownMachine
	}
	dialer, ok := tgt.(claudecode.ShellDialer)
	if !ok {
		return nil, ErrNoShell
	}
	return dialer.ShellCommand(ctx), nil
}

// Resolve tira uma sessão de needs_you marcando-a como concluída (done), sem
// apagá-la — usado pelo swipe "Concluir" no app quando a usuária já respondeu no
// terminal. Não marca como dismissed: a sessão pode voltar a precisar de você e
// cutucar de novo. ErrUnknownSession se não existir.
func (l *Launcher) Resolve(id string) error {
	if err := l.reg.UpdateState(id, session.StateDone); err != nil {
		return ErrUnknownSession
	}
	return nil
}

// Machines devolve os nomes dos alvos registrados, ordenados.
func (l *Launcher) Machines() []string {
	snap := l.snapshot()
	names := make([]string, 0, len(snap))
	for name := range snap {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// Remove apaga uma sessão: fecha o Handle vivo (encerra o processo ssh/claude,
// se houver) e a remove do Registry junto do output. ErrUnknownSession se não
// havia nem handle vivo nem sessão no Registry.
func (l *Launcher) Remove(id string) error {
	l.mu.Lock()
	h, hadHandle := l.handles[id]
	delete(l.handles, id)
	delete(l.pending, id)
	l.mu.Unlock()

	if hadHandle {
		_ = h.Close() // mata o processo; a goroutine de Run termina no EOF
	}
	removed := l.reg.Remove(id)
	if !hadHandle && !removed {
		return ErrUnknownSession
	}
	return nil
}

// InterruptEffect descreve o efeito REAL de um Interrupt bem-sucedido — a API
// devolve isto explicitamente para o app rotular a UI certa (card
// 6b74500a1fd9a1f2): "pausou" (sessão tmux, continua viva) é bem diferente de
// "encerrou" (sessão pipe-mode, processo morto).
type InterruptEffect string

const (
	// InterruptEffectPaused: sessão tmux (session.Pane != "") — manda Esc ao
	// pane (mesma tecla que a usuária apertaria no terminal pra abortar o
	// turno). A sessão CONTINUA viva, volta a aceitar prompt novo.
	InterruptEffectPaused InterruptEffect = "paused"
	// InterruptEffectEnded: sessão pipe-mode (claude -p --input-format
	// stream-json, sem pty) — o protocolo do CLI headless não tem hoje um
	// interrupt "suave" que aborte só o turno preservando o processo (feature
	// request aberta e não implementada, anthropics/claude-code#41665). A
	// única ação possível é ENCERRAR o processo; a sessão vai a done/error e
	// precisa de --resume para continuar a conversa.
	InterruptEffectEnded InterruptEffect = "ended"
)

// Interrupt para o agente em execução da sessão {id}. Só faz sentido com a
// sessão running — devolve ErrStaleState fora disso (mesma convenção de
// respond/claimPending), para o app não confundir estado.
//
//   - session.Pane != "" (sessão tmux, TUI interativo de verdade por trás):
//     manda a tecla Esc ao pane via TmuxKey (mesma infra do
//     TmuxKeyHandler) — InterruptEffectPaused, sessão segue viva.
//   - Sem Pane (caminho principal, LocalTarget/SSHTarget em stream-json): não
//     há primitiva de interrupt no protocolo hoje, então a única opção
//     honesta é encerrar o processo (h.Close(), mesma ação de Remove sem
//     apagar do Registry) — InterruptEffectEnded.
//
// O erro de Close (ex.: "signal: killed") é DESCARTADO de propósito — mesmo
// padrão do Remove: matar o processo É o sucesso esperado aqui, não falha.
// A sessão é marcada errored explicitamente por ESTE método (não confiamos no
// Runner detectar sozinho: ele só aplica Errored no EOF PURO do stdout —
// agent/runner.go — e fechar o Stdout enquanto o Runner está bloqueado num
// Read concorrente pode devolver um erro de "already closed" em vez de
// io.EOF, o que faria o Runner retornar sem marcar terminal e a sessão ficar
// presa em running pra sempre).
//
// TOCTOU corrigido na revisão da Ludmilla (card 6b74500a1fd9a1f2): entre o
// Get() de checagem no topo deste método e o h.Close() logo abaixo, o
// processo pode terminar NATURALMENTE (Finished→done, aplicado pelo Runner
// numa goroutine concorrente) — o handle só sai de l.handles DEPOIS que
// runner.Run retorna (launcher.go, goroutine de Launch), então ainda está
// "live" nesse instante. Um Apply(Errored) incondicional aqui pisaria num
// Done legítimo: o Engine só no-opa transições REDUNDANTES (cur == target),
// não protege contra sobrescrever um estado terminal DIFERENTE. Por isso a
// transição usa Registry.UpdateStateIfCurrent (mesmo espírito atômico de
// AddIfAbsent/AddIfAllowed: checa+escreve sob o mesmo lock) condicionada a
// StateRunning — se a sessão já saiu de running por conta própria, esta
// chamada é um no-op e o Done legítimo sobrevive. h.Close() continua
// incondicional: é idempotente (sync.Once) e seguro mesmo se o caminho normal
// também estiver fechando o handle nesse instante (launcher.go:238).
//
// TODO(#interrupt-stdin): quando o CLI headless suportar um interrupt real no
// stdin (ex.: {"type":"interrupt"}), trocar o branch sem Pane para escrevê-lo
// via h.WriteJSON em vez de h.Close() — daria InterruptEffectPaused também
// para sessões em pipe, sem matar o processo.
func (l *Launcher) Interrupt(id string) (InterruptEffect, error) {
	s, ok := l.reg.Get(id)
	if !ok {
		return "", ErrUnknownSession
	}
	if s.State != session.StateRunning {
		return "", ErrStaleState
	}

	if s.Pane != "" {
		if err := l.TmuxKey(s.Machine, s.Pane, "Escape"); err != nil {
			return "", err
		}
		return InterruptEffectPaused, nil
	}

	l.mu.Lock()
	h, live := l.handles[id]
	l.mu.Unlock()
	if !live {
		return "", ErrNoHandle
	}
	_ = h.Close() // mata o processo; erro de saída (SIGKILL/exit) é esperado, não falha do Interrupt
	l.reg.UpdateStateIfCurrent(id, session.StateRunning, session.StateError)
	return InterruptEffectEnded, nil
}

// Approve aprova o pedido de permissão pendente da sessão (behavior=allow, com
// o input original como updatedInput).
func (l *Launcher) Approve(id string) error { return l.respond(id, true) }

// Deny nega o pedido de permissão pendente da sessão (behavior=deny + message).
func (l *Launcher) Deny(id string) error { return l.respond(id, false) }

// respond valida o estado (needs_you) e o pendente, escreve o control_response
// pelo stdin e aplica user_responded (→ running) ao Engine.
func (l *Launcher) respond(id string, allow bool) error {
	p, h, err := l.claimPending(id)
	if err != nil {
		return err
	}
	// Aprovar às cegas uma pergunta de seleção mandaria "allow" com o input
	// original (sem answers) → a ferramenta roda sem resposta e o Claude reporta
	// "usuário não respondeu". Approve de pergunta exige /answer (SEC-111).
	// Deny (recusar a pergunta) segue válido — behavior=deny é aceito por
	// qualquer ferramenta.
	if allow && p.toolName == toolAskUserQuestion {
		l.setPending(id, p)
		return ErrStaleState
	}
	if err := h.WriteJSON(buildControlResponse(p, allow)); err != nil {
		// Falha de I/O: devolve o pendente para permitir nova tentativa.
		l.setPending(id, p)
		return err
	}
	l.eng.Apply(event.Event{SessionID: id, Type: event.UserResponded, At: time.Now()})
	return nil
}

// Answer responde a uma pergunta de seleção pendente (a ferramenta nativa
// AskUserQuestion): monta o updatedInput com o array `questions` ORIGINAL
// ecoado (inalterado) e o mapa `answers` (question completa → rótulo(s)
// escolhido(s), juntados com ", " em seleção múltipla — protocolo verificado
// de ponta a ponta com o SDK oficial). Mesma reivindicação atômica do
// respond — a sessão precisa estar em needs_you com um pendente vivo; se a
// escrita falhar, devolve o pendente para permitir nova tentativa.
func (l *Launcher) Answer(id string, answers []session.QuestionAnswer) error {
	p, h, err := l.claimPending(id)
	if err != nil {
		return err
	}
	// Só uma pergunta de seleção aceita Answer: responder um pedido comum de
	// permissão (Bash etc.) mandaria "allow" com o input da ferramenta trocado
	// por {questions,answers} — allow indevido de execução (SEC-111). Devolve o
	// pendente para a ação correta (Approve/Deny) ainda ser possível.
	if p.toolName != toolAskUserQuestion {
		l.setPending(id, p)
		return ErrStaleState
	}
	// Cada resposta precisa casar com uma pergunta REAL do pedido (senão a chave
	// em `answers` não corresponde a nada e a pergunta real fica sem resposta,
	// silenciosamente). Selected também não pode ser vazio.
	if err := validateAnswers(p.input, answers); err != nil {
		l.setPending(id, p)
		return err
	}
	// Eco ANTES do envio ao CLI (mesma ordem cronológica do SendText/resume,
	// launcher.go:742/803): sem isso a escolha da usuária não aparece como
	// bolha no transcrito do app — parece que o agente seguiu sozinho (card
	// cf66236a1b68488b). Só depois de validar (não ecoa resposta inválida).
	l.eng.Apply(event.Event{SessionID: id, Type: event.OutputChunk, Kind: event.KindUser, Data: buildAnswerEcho(p, answers), At: time.Now()})
	if err := h.WriteJSON(buildAnswerResponse(p, answers)); err != nil {
		l.setPending(id, p)
		return err
	}
	l.eng.Apply(event.Event{SessionID: id, Type: event.UserResponded, At: time.Now()})
	return nil
}

// answerEchoMaxLen é o teto de tamanho do eco (kind=user) de uma resposta a
// AskUserQuestion — mesmo padrão dos ~200 chars usados no truncamento de
// tool_result (adapter/claudecode/parser.go), para uma pergunta com opções
// muito longas não estourar a bolha do app.
const answerEchoMaxLen = 200

// buildAnswerEcho monta o texto do eco (kind=user) de uma resposta de seleção,
// na ORDEM do pedido original (não da resposta do cliente): pergunta única →
// só o(s) rótulo(s) escolhido(s); 2+ perguntas → "Header: rótulo(s)" por
// linha, usando o `header` curto (≤12 chars) do protocolo nativo em vez do
// enunciado completo (formato acordado com o app, card cf66236a1b68488b).
// Trunca em answerEchoMaxLen runas.
func buildAnswerEcho(p pending, answers []session.QuestionAnswer) string {
	var in struct {
		Questions []struct {
			Question string `json:"question"`
			Header   string `json:"header"`
		} `json:"questions"`
	}
	_ = json.Unmarshal(p.input, &in)

	selected := make(map[string]string, len(answers))
	for _, a := range answers {
		selected[a.Question] = strings.Join(a.Selected, ", ")
	}

	single := len(in.Questions) == 1
	lines := make([]string, 0, len(in.Questions))
	for _, q := range in.Questions {
		val, ok := selected[q.Question]
		if !ok {
			continue
		}
		if single {
			lines = append(lines, val)
			continue
		}
		header := q.Header
		if header == "" {
			header = q.Question
		}
		lines = append(lines, header+": "+val)
	}
	if len(lines) == 0 {
		// Defensivo: não deveria acontecer pós-validateAnswers (toda answer bate
		// com uma pergunta real), mas evita eco vazio se o input divergir.
		for _, a := range answers {
			lines = append(lines, strings.Join(a.Selected, ", "))
		}
	}
	return truncateRunes(strings.Join(lines, "\n"), answerEchoMaxLen)
}

// truncateRunes corta s em n runas (não bytes, para não quebrar UTF-8 no meio
// de um caractere multi-byte).
func truncateRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

// validateAnswers confere que toda resposta referencia uma pergunta existente no
// input do pedido e traz ao menos um rótulo selecionado. Sem exigir que TODAS as
// perguntas sejam respondidas (o app cobre isso na UI); o objetivo aqui é barrar
// chave inexistente / seleção vazia antes de escrever no stdin do CLI.
func validateAnswers(input json.RawMessage, answers []session.QuestionAnswer) error {
	if len(answers) == 0 {
		return ErrInvalidAnswer
	}
	var in struct {
		Questions []struct {
			Question string `json:"question"`
		} `json:"questions"`
	}
	if err := json.Unmarshal(input, &in); err != nil {
		return ErrInvalidAnswer
	}
	known := make(map[string]bool, len(in.Questions))
	for _, q := range in.Questions {
		known[q.Question] = true
	}
	for _, a := range answers {
		if len(a.Selected) == 0 || !known[a.Question] {
			return ErrInvalidAnswer
		}
	}
	return nil
}

// claimPending é a reivindicação ATÔMICA do pendente de uma sessão em
// needs_you: ler E remover o pendente na mesma seção crítica, junto do handle
// vivo. Sem isso, duas ações concorrentes (Approve/Deny/Answer) passam ambas
// pela validação e escrevem dois control_response para o MESMO request_id
// (review F3, achado #2). Usado por respond e Answer.
func (l *Launcher) claimPending(id string) (pending, *claudecode.Handle, error) {
	s, ok := l.reg.Get(id)
	if !ok {
		return pending{}, nil, ErrUnknownSession
	}
	if s.State != session.StateNeedsYou {
		return pending{}, nil, ErrStaleState // ação obsoleta: a sessão não está mais pedindo
	}

	l.mu.Lock()
	p, hasPending := l.pending[id]
	h, hasHandle := l.handles[id]
	if hasPending && hasHandle {
		delete(l.pending, id) // só o vencedor da corrida chega à escrita
	}
	l.mu.Unlock()
	if !hasPending || !hasHandle {
		return pending{}, nil, ErrStaleState // needs_you sem permissão viva (ex.: era só uma pergunta)
	}
	return p, h, nil
}

// SendText continua a conversa da sessão. Se há um processo VIVO (turno em
// andamento / needs_you), manda o texto pro stdin dele. Se a sessão já ENCERROU
// (done/error/idle, sem processo), retoma a MESMA conversa com `claude --resume`
// — preservando o contexto (mesmo session_id, verificado na CLI 2.1.199). É o
// que dá continuidade: perguntar de novo responde na mesma sessão.
func (l *Launcher) SendText(id, text string) error {
	s, ok := l.reg.Get(id)
	if !ok {
		return ErrUnknownSession
	}
	l.mu.Lock()
	h, live := l.handles[id]
	l.mu.Unlock()

	if live && h.AcceptsInput() {
		// Canal bidirecional vivo (Claude): manda pro stdin. Eco ANTES do envio,
		// para o texto da usuária aparecer no transcript antes da resposta do
		// agente (ordem cronológica).
		l.eng.Apply(event.Event{SessionID: id, Type: event.OutputChunk, Kind: event.KindUser, Data: text, At: time.Now()})
		if err := h.SendUserMessage(text); err != nil {
			return err
		}
		l.eng.Apply(event.Event{SessionID: id, Type: event.UserResponded, At: time.Now()})
		return nil
	}
	if live {
		// Processo vivo mas SEM canal de stdin (Codex é one-shot: o turno em
		// andamento não aceita injeção). Rejeita em vez de estourar nil deref —
		// a usuária tenta de novo quando o turno terminar (aí cai no resume).
		return ErrNoHandle
	}
	// Sessão encerrada: retoma com --resume, roteando tudo para o MESMO id.
	return l.resume(s, text)
}

// Reply entrega uma resposta em texto à sessão, ROTEANDO pelo canal certo — é o
// que a resposta vinda direto do push (notification action) usa, sem o app saber
// os detalhes: sessão com pane de tmux → digita no terminal (send-keys); senão →
// stdin/resume (SendText). ErrUnknownSession se não existir.
func (l *Launcher) Reply(id, text string) error {
	s, ok := l.reg.Get(id)
	if !ok {
		return ErrUnknownSession
	}
	if s.Pane != "" {
		return l.TmuxSend(s.Machine, s.Pane, text)
	}
	return l.SendText(id, text)
}

// resume retoma uma conversa encerrada rodando `claude --resume <id>` na mesma
// máquina, roteando TODO o stream para o mesmo session id (forcedID). Espelha o
// Launch, mas não espera um novo session_started nem checa teto (é continuação).
func (l *Launcher) resume(s session.Session, prompt string) error {
	tgt, ok := l.target(s.Machine, s.Agent)
	if !ok {
		return ErrUnknownMachine
	}

	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return ErrShuttingDown
	}
	l.wg.Add(1)
	l.mu.Unlock()

	// Retoma na MESMA pasta da sessão (s.Cwd): importa pras sessões adotadas do
	// Mac (o --resume restaura a conversa, mas as ferramentas operam no cwd). O
	// prompt vai pelo canal do agente dentro do Start (mantém o modelo da sessão).
	// Reusa o modelo escolhido no launch (persistido em s.Model): o OpenCode
	// exige -m em toda invocação, senão o resume cairia no default (SEC-109).
	handle, err := tgt.Start(l.baseCtx, s.ID, s.Cwd, s.Model, "", "", prompt)
	if err != nil {
		l.wg.Done()
		return err
	}
	// Eco do texto da usuária: aplicado ANTES de a goroutine do runner processar
	// qualquer resposta (mesma ordem cronológica do caminho ao vivo).
	l.eng.Apply(event.Event{SessionID: s.ID, Type: event.OutputChunk, Kind: event.KindUser, Data: prompt, At: time.Now()})
	// Registra o handle já para o id conhecido: aprovar/negar do turno retomado
	// funciona mesmo antes do session_started chegar.
	l.setHandle(s.ID, handle)

	app := &launchApplier{l: l, handle: handle, forcedID: s.ID}
	runner := tgt.NewRunner(app)
	go func() {
		defer l.wg.Done()
		_ = runner.Run(l.baseCtx, handle, claudecode.Meta{Machine: s.Machine, Prompt: prompt, SessionID: s.ID})
		l.removeHandle(s.ID)
		_ = handle.Close()
	}()
	return nil
}

func (l *Launcher) setPending(id string, p pending) {
	l.mu.Lock()
	l.pending[id] = p
	l.mu.Unlock()
}

func (l *Launcher) clearPending(id string) {
	l.mu.Lock()
	delete(l.pending, id)
	l.mu.Unlock()
}

func (l *Launcher) setHandle(id string, h *claudecode.Handle) {
	l.mu.Lock()
	l.handles[id] = h
	l.mu.Unlock()
}

func (l *Launcher) removeHandle(id string) {
	l.mu.Lock()
	delete(l.handles, id)
	l.mu.Unlock()
}

// Shutdown encerra TODAS as sessões vivas: fecha cada Handle (sinaliza EOF ao
// agente e espera o processo terminar, via Handle.Close) e limpa os mapas
// internos. Chamado no graceful shutdown do processo (cmd/hub/main.go), DEPOIS
// de srv.Shutdown ter parado de aceitar requests novos — se um Launch ainda
// estivesse em voo, seu Handle não estaria em l.handles ainda (só entra no
// session_started) e não seria fechado aqui; a ordem do main.go evita essa
// janela.
//
// Fecha os Handles FORA do lock: Close() pode bloquear esperando o processo
// terminar, e a goroutine de observação de cada Launch (Run) também precisa do
// mesmo mutex para chamar removeHandle no fim natural do stream — segurar o
// lock durante o Close causaria deadlock. Só depois de soltar o lock e fechar
// tudo é que esperamos wg.Wait(): mesmo padrão do Notifier.Close (cancela
// primeiro, espera depois) para não vazar goroutine
// (review/patterns.md#recurso-de-longa-duração-sem-cancelamento).
func (l *Launcher) Shutdown() {
	l.mu.Lock()
	l.closed = true // fecha a porta na MESMA seção do snapshot: Launch novo falha rápido
	handles := make([]*claudecode.Handle, 0, len(l.handles))
	for _, h := range l.handles {
		handles = append(handles, h)
	}
	l.handles = make(map[string]*claudecode.Handle)
	l.pending = make(map[string]pending)
	l.mu.Unlock()

	// Cancela o contexto-base: mata os processos em voo, inclusive sessões cujo
	// Handle ainda não foi registrado (Start em andamento) — sem isso, wg.Wait
	// abaixo travaria esperando uma goroutine cujo processo ninguém fechou.
	l.baseCancel()
	for _, h := range handles {
		_ = h.Close()
	}
	l.wg.Wait()
}

// launchApplier decora o Engine para uma sessão em observação: guarda/limpa o
// pendente conforme os eventos e delega SEMPRE ao Engine (único escritor).
type launchApplier struct {
	l         *Launcher
	handle    *claudecode.Handle
	started   chan session.Session
	sessionID string // preenchido no session_started (usado na limpeza ao fim)
	forcedID  string // resume: força todos os eventos para este id (continuidade)
	prompt    string // prompt inicial do Launch, ecoado (kind "user") no session_started
}

func (a *launchApplier) Apply(ev event.Event) {
	// Resume: garante que TODO evento vá para a sessão que estamos continuando,
	// independente do que o claude reporte no init (defesa; o id é o mesmo).
	if a.forcedID != "" {
		ev.SessionID = a.forcedID
	}
	switch ev.Type {
	case event.PermissionRequested:
		a.l.setPending(ev.SessionID, pending{requestID: ev.ControlID, input: ev.Input, toolName: ev.ToolName, toolUseID: ev.ToolUseID})
	case event.NeedsInput, event.UserResponded, event.Finished, event.Errored:
		// Qualquer outro evento de estado: não há permissão viva a responder.
		a.l.clearPending(ev.SessionID)
	}

	a.l.eng.Apply(ev) // delega SEMPRE ao Engine

	if ev.Type == event.SessionStarted {
		a.sessionID = ev.SessionID
		a.l.setHandle(ev.SessionID, a.handle)
		// Eco do prompt inicial (kind "user"): grava DEPOIS do session_started
		// (id já conhecido) e ANTES de sinalizar started, garantindo que o
		// eco apareça no transcript antes de qualquer resposta do agente —
		// que só é processada em linhas posteriores do mesmo stream, na mesma
		// goroutine do Runner.
		if a.prompt != "" {
			a.l.eng.Apply(event.Event{SessionID: ev.SessionID, Type: event.OutputChunk, Kind: event.KindUser, Data: a.prompt, At: time.Now()})
		}
		if s, ok := a.l.reg.Get(ev.SessionID); ok {
			select {
			case a.started <- s:
			default:
			}
		}
	}
}

// controlResponse é a resposta ao control_request nativo (shape verificado na
// CLI 2.1.198). O wrapper tem subtype "success" (o protocolo de controle deu
// certo); o response interno carrega a decisão (allow/deny).
type controlResponse struct {
	Type     string              `json:"type"`
	Response controlResponseBody `json:"response"`
}

type controlResponseBody struct {
	Subtype   string   `json:"subtype"`
	RequestID string   `json:"request_id"`
	Response  decision `json:"response"`
}

type decision struct {
	Behavior     string          `json:"behavior"`
	UpdatedInput json.RawMessage `json:"updatedInput,omitempty"` // allow: input original intacto
	Message      string          `json:"message,omitempty"`      // deny: justificativa
	// ToolUseID é o tool_use_id nativo da ferramenta, ecoado em camelCase
	// ("toolUseID") FORA do updatedInput — confirmado de ponta a ponta com o SDK
	// oficial, presente tanto no allow quanto no deny. omitempty: fixtures sem
	// tool_use_id (ex.: os testes sintéticos de Bash) simplesmente não o emitem.
	ToolUseID string `json:"toolUseID,omitempty"`
}

// buildControlResponse monta o control_response de allow (devolvendo o input
// original como updatedInput) ou deny (com a mensagem padrão), ecoando o
// toolUseID do pendente em ambos.
func buildControlResponse(p pending, allow bool) controlResponse {
	d := decision{ToolUseID: p.toolUseID}
	if allow {
		d.Behavior = "allow"
		input := p.input
		if len(input) == 0 {
			input = json.RawMessage(`{}`)
		}
		d.UpdatedInput = input
	} else {
		d.Behavior = "deny"
		d.Message = denyMessage
	}
	return controlResponse{
		Type: "control_response",
		Response: controlResponseBody{
			Subtype:   "success",
			RequestID: p.requestID,
			Response:  d,
		},
	}
}

// answerUpdatedInput é o updatedInput do allow de uma pergunta de seleção
// (AskUserQuestion): o array `questions` ORIGINAL ecoado inalterado (contrato
// verificado do protocolo) + o mapa `answers` (question completa → rótulo(s)
// escolhido(s)). A ordem dos campos no struct (Questions antes de Answers)
// mantém o shape do exemplo verificado: {"questions":[...],"answers":{...}}.
type answerUpdatedInput struct {
	Questions json.RawMessage   `json:"questions"`
	Answers   map[string]string `json:"answers"`
}

// buildAnswerResponse monta o control_response de allow de uma resposta a
// AskUserQuestion: `answers` é um map[question]="label" (seleção única) ou
// "label1, label2" (múltipla, juntado com ", " — verificado com o SDK oficial;
// NUNCA um array). `questions` é ecoado inalterado a partir do input original do
// pendente (não do array vindo do handler — defesa contra a usuária/app mandar
// um `question` que não bate com o pedido nativo).
func buildAnswerResponse(p pending, answers []session.QuestionAnswer) controlResponse {
	m := make(map[string]string, len(answers))
	for _, a := range answers {
		m[a.Question] = strings.Join(a.Selected, ", ")
	}
	updated, _ := json.Marshal(answerUpdatedInput{
		Questions: originalQuestions(p.input),
		Answers:   m,
	})
	d := decision{
		Behavior:     "allow",
		UpdatedInput: updated,
		ToolUseID:    p.toolUseID,
	}
	return controlResponse{
		Type: "control_response",
		Response: controlResponseBody{
			Subtype:   "success",
			RequestID: p.requestID,
			Response:  d,
		},
	}
}

// originalQuestions extrai o array `questions` bruto do input original do
// AskUserQuestion (guardado no pendente), para ecoar inalterado no
// updatedInput — protocolo verificado: "questions deve ser ecoado inalterado".
func originalQuestions(input json.RawMessage) json.RawMessage {
	var in struct {
		Questions json.RawMessage `json:"questions"`
	}
	if len(input) == 0 {
		return json.RawMessage(`[]`)
	}
	if err := json.Unmarshal(input, &in); err != nil || len(in.Questions) == 0 {
		return json.RawMessage(`[]`)
	}
	return in.Questions
}
