// Package agent define a base compartilhada dos adapters de agente de codígo
// (Claude Code, Codex, …): o canal de processo (Handle), o Runner que traduz o
// stream de saída em eventos normalizados e a interface Target que cada agente
// implementa. O contrato de eventos vive em internal/event (agnóstico de
// agente); aqui mora a plataforma de execução que os adapters concretos reusam.
//
// claudecode reexporta estes tipos por alias (ex.: claudecode.Handle =
// agent.Handle), então o código que já referencia claudecode.* segue compilando;
// codex importa este pacote diretamente.
package agent

import (
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// closeWaitTimeout é quanto Close espera o processo sair sozinho (após fechar
// stdin/stdout) antes de matar com SIGKILL. Sem esse teto, um filho pendurado
// (ex.: ssh travado no connect) faria Close — e o graceful shutdown — travar
// para sempre (review F5, achado bloqueante #1).
const closeWaitTimeout = 5 * time.Second

// Handle é o canal de uma sessão viva de um agente: lê-se o stream de saída pelo
// Stdout e escreve-se pelo Stdin (mensagens de usuário e, no Claude,
// control_response de aprovação/negação). Fechar encerra o processo.
//
// As escritas passam por WriteJSON/SendUserMessage, serializadas por writeMu:
// aprovar e enviar texto podem vir de goroutines diferentes (handlers HTTP) e
// não podem intercalar bytes numa mesma linha do stdin.
//
// Agentes one-shot (ex.: `codex exec`, que recebe o prompt como argumento e sai
// ao fim do turno) simplesmente não usam Stdin/SendUserMessage — o Handle
// continua servindo para ler o Stdout e colher o processo no Close.
type Handle struct {
	Stdout  io.ReadCloser
	Stdin   io.WriteCloser
	wait    func() error // cmd.Wait — colhe o processo
	kill    func() error // cmd.Process.Kill (SIGKILL) — fallback do Close
	writeMu sync.Mutex

	// closeOnce garante um único cmd.Wait(): Close pode ser chamado em corrida
	// pelo timeout do Launch e pelo fim natural do Runner, e Wait concorrente é
	// data race na stdlib (review F3, achado #1).
	closeOnce sync.Once
	closeErr  error
}

// NewHandle liga o stdin/stdout de um cmd já iniciado a um Handle. Os adapters
// concretos (LocalTarget/SSHTarget de cada agente) o usam depois de cmd.Start().
func NewHandle(stdout io.ReadCloser, stdin io.WriteCloser, cmd *exec.Cmd) *Handle {
	return &Handle{Stdout: stdout, Stdin: stdin, wait: cmd.Wait, kill: procKill(cmd)}
}

// Close fecha o stdin (sinaliza EOF ao agente) e espera o processo terminar,
// para não deixar zumbis. É seguro (e idempotente) chamar de várias goroutines:
// só a primeira executa; as demais recebem o mesmo resultado. Se o processo não
// sair em closeWaitTimeout (ex.: ssh pendurado), é morto com SIGKILL — Close
// nunca bloqueia indefinidamente (review F5, achado bloqueante #1).
func (h *Handle) Close() error {
	h.closeOnce.Do(func() {
		if h.Stdin != nil {
			_ = h.Stdin.Close()
		}
		if h.Stdout != nil {
			_ = h.Stdout.Close()
		}
		if h.wait == nil {
			return
		}
		done := make(chan error, 1)
		go func() { done <- h.wait() }()
		select {
		case err := <-done:
			h.closeErr = err
		case <-time.After(closeWaitTimeout):
			if h.kill != nil {
				_ = h.kill()
			}
			h.closeErr = <-done // Wait retorna após o SIGKILL
		}
	})
	return h.closeErr
}

// procKill devolve uma função que mata o processo do cmd com SIGKILL (nil-safe).
func procKill(cmd *exec.Cmd) func() error {
	return func() error {
		if cmd.Process != nil {
			return cmd.Process.Kill()
		}
		return nil
	}
}

// userMessage é a mensagem de usuário no formato stream-json que o CLI do Claude
// aceita no stdin (verificado na CLI 2.1.198):
//
//	{"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}]}}
type userMessage struct {
	Type    string          `json:"type"`
	Message userMessageBody `json:"message"`
}

type userMessageBody struct {
	Role    string         `json:"role"`
	Content []userTextItem `json:"content"`
}

type userTextItem struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

// WriteJSON serializa v em uma linha JSON (com newline) no stdin, de forma
// thread-safe. É como o Launcher escreve o control_response de aprovação/negação.
func (h *Handle) WriteJSON(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	h.writeMu.Lock()
	defer h.writeMu.Unlock()
	_, err = h.Stdin.Write(b)
	return err
}

// SendUserMessage escreve uma mensagem de usuário (o prompt inicial ou um input
// posterior) no stdin, no formato stream-json do Claude seguido de newline.
// Agentes one-shot não a usam.
func (h *Handle) SendUserMessage(text string) error {
	return h.WriteJSON(userMessage{
		Type: "user",
		Message: userMessageBody{
			Role:    "user",
			Content: []userTextItem{{Type: "text", Text: text}},
		},
	})
}

// ChildEnv monta o ambiente mínimo do processo do agente: só o necessário para
// o agente funcionar (HOME p/ config/credenciais, PATH p/ binários, locale).
// Allowlist, nunca herança de os.Environ() (review F3, SEC-006): o filho NÃO
// herda o ambiente do hub, que carrega CUTUQUE_TOKEN (e credenciais APNs).
func ChildEnv() []string {
	keep := []string{"HOME", "PATH", "USER", "LANG", "LC_ALL", "TERM", "TMPDIR"}
	env := make([]string, 0, len(keep))
	for _, k := range keep {
		if v, ok := os.LookupEnv(k); ok {
			env = append(env, k+"="+v)
		}
	}
	return env
}

// SingleQuote envolve s em aspas simples, escapando aspas simples internas com o
// idioma '\''. Protege UM nível de parse de shell contra QUALQUER conteúdo
// (inclusive input do cliente): tudo entre as aspas é literal. Para dois níveis
// aninhados (ssh → login shell), ver remoteClaudeCommand no claudecode — quoting
// sozinho não basta lá.
func SingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
