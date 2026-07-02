package claudecode

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os/exec"
	"sync"
)

// Handle é o canal bidirecional de uma sessão viva do Claude Code: lê-se o
// stream-json pelo Stdout e escreve-se pelo Stdin (mensagens de usuário e
// control_response de aprovação/negação). Fechar encerra o processo.
//
// As escritas passam por WriteJSON/SendUserMessage, serializadas por writeMu:
// aprovar e enviar texto podem vir de goroutines diferentes (handlers HTTP) e
// não podem intercalar bytes numa mesma linha do stdin.
type Handle struct {
	Stdout  io.ReadCloser
	Stdin   io.WriteCloser
	closer  func() error
	writeMu sync.Mutex
}

// Close fecha o stdin (sinaliza EOF ao agente) e espera o processo terminar,
// para não deixar zumbis. É seguro chamar mais de uma vez.
func (h *Handle) Close() error {
	if h.Stdin != nil {
		_ = h.Stdin.Close()
	}
	if h.Stdout != nil {
		_ = h.Stdout.Close()
	}
	if h.closer != nil {
		return h.closer()
	}
	return nil
}

// userMessage é a mensagem de usuário no formato stream-json que o CLI aceita
// no stdin (verificado na CLI 2.1.198):
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
// posterior) no stdin, no formato stream-json seguido de newline.
func (h *Handle) SendUserMessage(text string) error {
	return h.WriteJSON(userMessage{
		Type: "user",
		Message: userMessageBody{
			Role:    "user",
			Content: []userTextItem{{Type: "text", Text: text}},
		},
	})
}

// Target é uma máquina/canal onde uma sessão do Claude Code é lançada e
// observada. Start dispara a sessão e devolve um Handle bidirecional; o prompt
// inicial é enviado por quem lança, via Handle.SendUserMessage.
type Target interface {
	Name() string
	Start(ctx context.Context) (*Handle, error)
}

// LocalTarget roda o Claude Code como um processo local, em modo stream-json
// bidirecional. Em produção executa (verificado na CLI 2.1.198):
//
//	claude -p --input-format stream-json --output-format stream-json \
//	       --permission-mode default --permission-prompt-tool stdio --verbose
//
// Nesse modo o CLI emite control_request (can_use_tool) no stdout e aguarda o
// control_response no stdin — o canal de aprovação nativo do Cutuque.
type LocalTarget struct {
	name      string
	prog      string
	buildArgs func() []string
}

// NewLocalTarget cria um LocalTarget que roda o `claude` real localmente.
func NewLocalTarget(name string) *LocalTarget {
	return newLocalCommand(name, "claude", func() []string {
		return []string{
			"-p",
			"--input-format", "stream-json",
			"--output-format", "stream-json",
			"--permission-mode", "default",
			"--permission-prompt-tool", "stdio",
			"--verbose",
		}
	})
}

// newLocalCommand cria um LocalTarget parametrizável (usado em teste para trocar
// `claude` por um comando como `cat` de uma fixture).
func newLocalCommand(name, prog string, buildArgs func() []string) *LocalTarget {
	return &LocalTarget{name: name, prog: prog, buildArgs: buildArgs}
}

// Name identifica o alvo (vira o campo Machine da sessão).
func (t *LocalTarget) Name() string { return t.name }

// Start executa o comando e liga stdin/stdout ao Handle. Fechar o Handle
// encerra o processo (via cancelamento do ctx + close do stdin) e libera os
// recursos.
func (t *LocalTarget) Start(ctx context.Context) (*Handle, error) {
	cmd := exec.CommandContext(ctx, t.prog, t.buildArgs()...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &Handle{
		Stdout: stdout,
		Stdin:  stdin,
		closer: cmd.Wait,
	}, nil
}

// SSHTarget observará uma sessão numa máquina remota via `tailscale ssh`.
// Stub documentado — implementação real fica para a Fase 3/v1.
type SSHTarget struct {
	name string
}

// NewSSHTarget cria o stub de um alvo remoto.
func NewSSHTarget(name string) *SSHTarget {
	return &SSHTarget{name: name}
}

// Name identifica o alvo remoto.
func (t *SSHTarget) Name() string { return t.name }

// Start ainda não é suportado (Fase 3/v1: abrir/observar via `tailscale ssh`).
func (t *SSHTarget) Start(ctx context.Context) (*Handle, error) {
	return nil, errors.New("claudecode: SSHTarget ainda não implementado (Fase 3/v1)")
}
