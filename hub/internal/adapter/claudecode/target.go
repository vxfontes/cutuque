package claudecode

import (
	"context"
	"errors"
	"io"
	"os/exec"
)

// Target é uma máquina/canal onde uma sessão do Claude Code é lançada e
// observada. Start dispara a sessão e devolve o stream stream-json para leitura.
type Target interface {
	Name() string
	Start(ctx context.Context, prompt string) (io.ReadCloser, error)
}

// LocalTarget roda o Claude Code como um processo local e expõe seu stdout.
// Em produção executa:
//
//	claude -p <prompt> --output-format stream-json --verbose
type LocalTarget struct {
	name      string
	prog      string
	buildArgs func(prompt string) []string
}

// NewLocalTarget cria um LocalTarget que roda o `claude` real localmente.
func NewLocalTarget(name string) *LocalTarget {
	return newLocalCommand(name, "claude", func(prompt string) []string {
		return []string{"-p", prompt, "--output-format", "stream-json", "--verbose"}
	})
}

// newLocalCommand cria um LocalTarget parametrizável (usado em teste para trocar
// `claude` por um comando como `cat` de uma fixture).
func newLocalCommand(name, prog string, buildArgs func(prompt string) []string) *LocalTarget {
	return &LocalTarget{name: name, prog: prog, buildArgs: buildArgs}
}

// Name identifica o alvo (vira o campo Machine da sessão).
func (t *LocalTarget) Name() string { return t.name }

// Start executa o comando e devolve seu stdout. Fechar o ReadCloser encerra o
// processo (via cancelamento do ctx) e libera os recursos.
func (t *LocalTarget) Start(ctx context.Context, prompt string) (io.ReadCloser, error) {
	cmd := exec.CommandContext(ctx, t.prog, t.buildArgs(prompt)...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &cmdReader{cmd: cmd, stdout: stdout}, nil
}

// cmdReader liga o stdout do processo ao seu ciclo de vida: Close espera o
// processo terminar para não deixar zumbis.
type cmdReader struct {
	cmd    *exec.Cmd
	stdout io.ReadCloser
}

func (c *cmdReader) Read(p []byte) (int, error) { return c.stdout.Read(p) }

func (c *cmdReader) Close() error {
	_ = c.stdout.Close()
	return c.cmd.Wait()
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
func (t *SSHTarget) Start(ctx context.Context, prompt string) (io.ReadCloser, error) {
	return nil, errors.New("claudecode: SSHTarget ainda não implementado (Fase 3/v1)")
}
