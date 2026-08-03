package machine

import (
	"context"
	"fmt"
	"net"
	"os"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

// A detecção do sistema roda pela mesma via da instalação da chave (x/crypto/ssh
// direto, com o fingerprint confirmado), e não pelo Launcher. Duas razões:
//
//  1. ela acontece no CADASTRO, no instante seguinte ao install-key — antes ou
//     junto do momento em que a máquina passa a ser alvo do launcher;
//  2. é a única conexão do cadastro que já usa a chave recém-instalada, e falhar
//     aqui é a prova mais direta de que a chave entrou.
//
// O comando é fixo, sem nada da usuária dentro: não há o que injetar.
const detectTimeout = 20 * time.Second

// detectCmd: `uname -sr` dá "Darwin 24.5.0", "Linux 6.8.0-45-generic". Barato,
// existe em qualquer unix e é o suficiente para o app escolher o ícone.
//
// No Linux o kernel não diz a distro, então tentamos o /etc/os-release primeiro
// e caímos no uname. `. /etc/os-release` num shell não interativo é seguro: o
// arquivo é do sistema, não da usuária.
const detectCmd = `if [ -r /etc/os-release ]; then . /etc/os-release; echo "${PRETTY_NAME:-$NAME}"; else uname -sr; fi`

// DetectOS conecta na máquina com a chave da identidade e devolve o sistema que
// ela respondeu. Só é chamada depois do TOFU confirmado: o expectedFingerprint
// vazio faz o hostKeyCallback recusar.
//
// Erro aqui não é fatal para o cadastro — o SO é descritivo (ícone no app). Quem
// chama decide se vale reportar.
func DetectOS(ctx context.Context, dest string, port int, keyPath, expectedFingerprint string) (string, error) {
	user := userOf(dest)
	if user == "" {
		return "", fmt.Errorf("o destino precisa ser usuario@host para detectar o sistema (veio %q)", dest)
	}
	auth, err := keyAuth(keyPath)
	if err != nil {
		return "", err
	}

	cfg := &ssh.ClientConfig{
		User:            user,
		Auth:            []ssh.AuthMethod{auth},
		HostKeyCallback: hostKeyCallback(expectedFingerprint),
		Timeout:         detectTimeout,
	}
	addr := addrOf(dest, port)

	d := net.Dialer{Timeout: detectTimeout}
	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return "", fmt.Errorf("não deu para conectar em %s: %w", addr, err)
	}
	sshConn, chans, reqs, err := ssh.NewClientConn(conn, addr, cfg)
	if err != nil {
		conn.Close()
		return "", fmt.Errorf("a chave do Cutuque não autenticou em %s: %w", dest, err)
	}
	client := ssh.NewClient(sshConn, chans, reqs)
	defer client.Close()

	out, err := run(client, detectCmd, "")
	if err != nil {
		return "", fmt.Errorf("não deu para ler o sistema de %s: %w", dest, err)
	}
	return primeiraLinha(out), nil
}

// keyAuth lê a privada da identidade em /data. Sem passphrase de propósito (o
// hub conecta sozinho, sem ninguém para digitar nada).
func keyAuth(keyPath string) (ssh.AuthMethod, error) {
	if strings.TrimSpace(keyPath) == "" {
		return nil, fmt.Errorf("a identidade ainda não tem chave gerada")
	}
	pem, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("não deu para ler a chave em %s: %w", keyPath, err)
	}
	signer, err := ssh.ParsePrivateKey(pem)
	if err != nil {
		return nil, fmt.Errorf("a chave em %s não é utilizável: %w", keyPath, err)
	}
	return ssh.PublicKeys(signer), nil
}

// primeiraLinha limpa a saída: o shell remoto pode emitir motd, aviso de locale
// ou linha em branco antes do que interessa. Teto de tamanho porque isto vai
// para o registro e para a tela — não é lugar de despejar saída de shell.
func primeiraLinha(out string) string {
	for _, l := range strings.Split(out, "\n") {
		if t := strings.TrimSpace(l); t != "" {
			if len(t) > 120 {
				t = t[:120]
			}
			return t
		}
	}
	return ""
}

// DetectOS no KeyStore delega para a função do pacote, pelo mesmo motivo do
// InstallKey: o servidor depende de UMA interface com tudo que o cadastro faz.
func (k *KeyStore) DetectOS(ctx context.Context, dest string, port int, keyPath, expectedFingerprint string) (string, error) {
	return DetectOS(ctx, dest, port, keyPath, expectedFingerprint)
}
