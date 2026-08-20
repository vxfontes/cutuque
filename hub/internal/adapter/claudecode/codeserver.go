package claudecode

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os/exec"
	"strings"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/adapter/agent"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

var (
	_ agent.CodeServerStarter = (*LocalTarget)(nil)
	_ agent.CodeServerStarter = (*SSHTarget)(nil)
)

const (
	defaultCodeServerCmd = "code-server"
	defaultTailscaleCmd  = "tailscale"
	codeServerBindAddr   = "127.0.0.1:8443"

	// Ação de abrir o editor pode precisar acordar a máquina/VPN, mas não deve
	// manter um request do hub preso indefinidamente.
	codeServerStartTimeout = 30 * time.Second
)

const (
	CodeServerStateRunning     = "running"
	CodeServerStateUnavailable = "unavailable"
	CodeServerStateError       = "error"
)

var (
	// Erros separados permitem ao chamador explicar a causa sem transformar a
	// ausência de Tailscale numa URL HTTP insegura ou numa falha genérica.
	ErrCodeServerUnavailable = errors.New("code-server indisponível")
	ErrTailscaleUnavailable  = errors.New("tailscale serve indisponível")
	ErrCodeServerStart       = errors.New("falha ao iniciar code-server")
)

// StartCodeServer inicia o editor local sob demanda e o publica por HTTPS no
// tailnet. Não instala launchd/systemd nem configura um daemon permanente.
func (t *LocalTarget) StartCodeServer(ctx context.Context, cwd string) (session.CodeServer, error) {
	return startCodeServer(ctx, exec.CommandContext, "sh", cwd, nil)
}

// StartCodeServer inicia o editor na máquina SSH. cwd é sempre single-quoted
// dentro do comando remoto; os demais tokens são constantes do adapter.
func (t *SSHTarget) StartCodeServer(ctx context.Context, cwd string) (session.CodeServer, error) {
	args := append(t.sshOpts(), "--", t.dest, remoteCodeServerCommand(cwd))
	return startCodeServer(ctx, exec.CommandContext, t.prog, cwd, args)
}

// commandContextFn existe para manter a montagem/execução testável sem abrir
// uma conexão real. O comando real continua sendo exec.CommandContext.
type commandContextFn func(context.Context, string, ...string) *exec.Cmd

func startCodeServer(
	parent context.Context,
	command commandContextFn,
	prog, cwd string,
	args []string,
) (session.CodeServer, error) {
	ctx, cancel := context.WithTimeout(parent, codeServerStartTimeout)
	defer cancel()

	if len(args) == 0 {
		args = []string{"-c", codeServerShellScript(cwd)}
	}
	// O alvo local usa `sh -c`; o alvo SSH recebe a mesma linha como comando
	// remoto, portanto o quoting de cwd é exercitado nos dois caminhos.
	cmd := command(ctx, prog, args...)
	cmd.Env = childEnv()
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		if ctx.Err() != nil {
			return session.CodeServer{State: CodeServerStateError}, fmt.Errorf("code-server: %w", ctx.Err())
		}
		return codeServerFailure(err, stderr.String())
	}

	base, err := parseTailscaleStatus(out)
	if err != nil {
		return session.CodeServer{State: CodeServerStateError}, fmt.Errorf("%w: %v", ErrCodeServerStart, err)
	}
	return session.CodeServer{URL: base, State: CodeServerStateRunning}, nil
}

// codeServerShellScript é POSIX para funcionar no shell de login de macOS,
// Linux e WSL. O processo fica desacoplado apenas para sobreviver ao fim do
// comando SSH que devolve a URL; ele não é registrado como serviço permanente.
func codeServerShellScript(cwd string) string {
	path := `"$HOME"`
	if cwd != "" {
		path = singleQuote(cwd)
	}

	return strings.Join([]string{
		"set -eu",
		"if ! command -v " + singleQuote(defaultTailscaleCmd) + " >/dev/null 2>&1; then echo 'cutuque: tailscale unavailable' >&2; exit 125; fi",
		"pid=",
		// O processo pode ser de uma execução anterior; keep começa em 1 para
		// que uma falha posterior nunca mate um serviço que não criamos aqui.
		"keep=1",
		`cleanup() { if [ "$keep" -eq 0 ] && [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi; }`,
		"trap cleanup EXIT",
		"reuse=0",
		// curl é preferido quando existe; Python cobre macOS/WSL enxutos e
		// verifica a conexão TCP sem depender de uma resposta HTTP específica.
		"if command -v curl >/dev/null 2>&1 && curl --silent --show-error --connect-timeout 1 --max-time 2 --output /dev/null " + singleQuote("http://"+codeServerBindAddr+"/") + "; then reuse=1; elif command -v python3 >/dev/null 2>&1 && python3 -c " + singleQuote("import socket; s=socket.create_connection(('127.0.0.1', 8443), 1); s.close()") + " >/dev/null 2>&1; then reuse=1; fi",
		"if [ \"$reuse\" -eq 0 ]; then",
		"  if ! command -v " + singleQuote(defaultCodeServerCmd) + " >/dev/null 2>&1; then echo 'cutuque: code-server unavailable' >&2; exit 126; fi",
		"  keep=0",
		`  log=$(mktemp "${TMPDIR:-/tmp}/cutuque-code-server.XXXXXX")`,
		"  nohup " + singleQuote(defaultCodeServerCmd) + " --bind-addr " + singleQuote(codeServerBindAddr) + " --auth none --disable-telemetry -- " + path + ` >"$log" 2>&1 < /dev/null &`,
		"  pid=$!",
		// Dá ao processo uma janela curta para falhar por binário inválido,
		// porta ocupada ou configuração quebrada antes de publicar a rota.
		"  sleep 1",
		`  if ! kill -0 "$pid" 2>/dev/null; then echo 'cutuque: code-server start failed' >&2; exit 127; fi`,
		"fi",
		"if ! " + singleQuote(defaultTailscaleCmd) + " serve --bg --https=443 " + singleQuote("http://"+codeServerBindAddr) + " >/dev/null; then echo 'cutuque: tailscale serve failed' >&2; exit 128; fi",
		"status=$(" + singleQuote(defaultTailscaleCmd) + " status --json)",
		`printf '%s\n' "$status"`,
		"keep=1",
	}, "\n")
}

// remoteCodeServerCommand usa login shell para carregar o PATH do Homebrew ou
// da instalação do WSL, mas envolve a linha completa num único argumento
// protegido. Assim cwd e qualquer outro texto recebido do app continuam sendo
// dados literais no shell remoto.
func remoteCodeServerCommand(cwd string) string {
	return "bash -lc " + singleQuote(codeServerShellScript(cwd))
}

// parseTailscaleStatus extrai o nome DNS HTTPS anunciado pela própria máquina
// no tailnet. Não aceita transformar uma saída ausente/malformada em URL HTTP.
func parseTailscaleStatus(out []byte) (string, error) {
	var status struct {
		Self struct {
			DNSName string `json:"DNSName"`
		} `json:"Self"`
	}
	if err := json.Unmarshal(out, &status); err != nil {
		return "", fmt.Errorf("status do tailscale inválido: %w", err)
	}
	dnsName := strings.TrimSuffix(strings.TrimSpace(status.Self.DNSName), ".")
	if dnsName == "" {
		return "", errors.New("tailscale não informou DNSName da máquina")
	}
	u, err := url.Parse("https://" + dnsName + "/")
	if err != nil || u.Scheme != "https" || u.Host == "" || u.Path != "/" {
		return "", fmt.Errorf("DNSName inválido %q", dnsName)
	}
	return u.String(), nil
}

func codeServerFailure(runErr error, stderr string) (session.CodeServer, error) {
	detail := strings.TrimSpace(stderr)
	switch {
	case strings.Contains(detail, "tailscale unavailable"):
		return session.CodeServer{State: CodeServerStateUnavailable}, fmt.Errorf("%w: %s", ErrTailscaleUnavailable, detail)
	case strings.Contains(detail, "code-server unavailable"):
		return session.CodeServer{State: CodeServerStateUnavailable}, fmt.Errorf("%w: %s", ErrCodeServerUnavailable, detail)
	default:
		if detail == "" {
			return session.CodeServer{State: CodeServerStateError}, fmt.Errorf("%w: %v", ErrCodeServerStart, runErr)
		}
		return session.CodeServer{State: CodeServerStateError}, fmt.Errorf("%w: %v: %s", ErrCodeServerStart, runErr, detail)
	}
}
