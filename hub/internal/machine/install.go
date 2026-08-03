package machine

import (
	"context"
	"fmt"
	"net"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

// A instalação da chave é feita em Go, com golang.org/x/crypto/ssh, e não com
// ssh-copy-id. Motivo: o ssh-copy-id pede a senha em modo interativo; alimentá-lo
// sem tty exigiria sshpass (pacote que a imagem não tem) com a senha no argv,
// visível para qualquer `ps` na máquina. Aqui a senha é um parâmetro em memória
// do processo — nunca vai para linha de comando, arquivo, env nem log.

const installTimeout = 30 * time.Second

// InstallKey instala a chave pública do Cutuque na authorized_keys do destino,
// autenticando UMA vez com a senha que a usuária digitou.
//
// A senha só viaja depois de o host provar ser o mesmo que ela confirmou no
// TOFU (expectedFingerprint) — é o ponto mais sensível do cadastro: uma conexão
// não verificada aqui entregaria a senha dela a quem estivesse no meio.
func InstallKey(ctx context.Context, dest string, port int, password, pub, expectedFingerprint string) error {
	user := userOf(dest)
	if user == "" {
		return fmt.Errorf("o destino precisa ser usuario@host para instalar a chave (veio %q)", dest)
	}
	if strings.TrimSpace(pub) == "" {
		return fmt.Errorf("chave pública vazia")
	}

	cfg := &ssh.ClientConfig{
		User:            user,
		Auth:            []ssh.AuthMethod{ssh.Password(password)},
		HostKeyCallback: hostKeyCallback(expectedFingerprint),
		Timeout:         installTimeout,
	}

	d := net.Dialer{Timeout: installTimeout}
	conn, err := d.DialContext(ctx, "tcp", addrOf(dest, port))
	if err != nil {
		return fmt.Errorf("não deu para conectar em %s: %w", addrOf(dest, port), err)
	}
	sshConn, chans, reqs, err := ssh.NewClientConn(conn, addrOf(dest, port), cfg)
	if err != nil {
		conn.Close()
		// Não embrulhar com a senha por perto: a mensagem do x/crypto diz só
		// "unable to authenticate", que é o que a usuária precisa ver.
		return fmt.Errorf("não deu para autenticar em %s: %w", dest, err)
	}
	client := ssh.NewClient(sshConn, chans, reqs)
	defer client.Close()

	// 1) Lê a authorized_keys atual. Ausente não é erro: pode ser o primeiro
	//    acesso por chave dessa conta.
	atual, err := run(client, "cat ~/.ssh/authorized_keys 2>/dev/null || true", "")
	if err != nil {
		return fmt.Errorf("não deu para ler a authorized_keys: %w", err)
	}
	if jaTemAChave(atual, pub) {
		return nil // recadastro da mesma máquina: nada a fazer
	}

	// 2) Anexa a chave pelo STDIN. Nada de interpolar a chave no comando: sem
	//    interpolação não há o que escapar.
	_, err = run(client,
		"mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys",
		strings.TrimSpace(pub)+"\n")
	if err != nil {
		return fmt.Errorf("não deu para instalar a chave: %w", err)
	}
	return nil
}

// InstallKey no KeyStore só delega para a função do pacote. Existe para o
// servidor depender de uma interface única com tudo que o cadastro precisa, em
// vez de misturar um método com uma função solta.
func (k *KeyStore) InstallKey(ctx context.Context, dest string, port int, password, pub, expectedFingerprint string) error {
	return InstallKey(ctx, dest, port, password, pub, expectedFingerprint)
}

// run abre uma sessão, roda o comando com stdin opcional e devolve o stdout.
func run(c *ssh.Client, cmd, stdin string) (string, error) {
	s, err := c.NewSession()
	if err != nil {
		return "", err
	}
	defer s.Close()
	if stdin != "" {
		s.Stdin = strings.NewReader(stdin)
	}
	out, err := s.Output(cmd)
	return string(out), err
}

// hostKeyCallback só aceita o host cuja impressão digital a usuária confirmou.
// Sem fingerprint confirmado, recusa: conectar seria MITM aberto — e é
// justamente nessa conexão que a senha dela viaja.
func hostKeyCallback(expected string) ssh.HostKeyCallback {
	return func(_ string, _ net.Addr, key ssh.PublicKey) error {
		if expected == "" {
			return fmt.Errorf("a máquina ainda não foi confirmada (TOFU pendente)")
		}
		got := ssh.FingerprintSHA256(key)
		if got != expected {
			return fmt.Errorf("a impressão digital do host mudou: esperava %s, veio %s", expected, got)
		}
		return nil
	}
}

// userOf tira o usuário do destino ("vx@host" → "vx"). Sem @, não há usuário: o
// hub não adivinha a conta (o alias do ~/.ssh/config é resolvido pelo ssh do
// sistema, que não está no caminho desta conexão).
func userOf(dest string) string {
	if user, _, found := strings.Cut(dest, "@"); found {
		return user
	}
	return ""
}

// addrOf monta "host:porta" para o dial.
func addrOf(dest string, port int) string {
	if port <= 0 {
		port = defaultSSHPort
	}
	return net.JoinHostPort(hostOf(dest), fmt.Sprint(port))
}

// jaTemAChave diz se a pública já está na authorized_keys. Compara linha
// inteira (não prefixo): duas chaves podem começar igual, e instalar a errada
// daria acesso a quem não deveria.
func jaTemAChave(authorized, pub string) bool {
	alvo := strings.TrimSpace(pub)
	if alvo == "" {
		return false
	}
	for _, l := range strings.Split(authorized, "\n") {
		if strings.TrimSpace(l) == alvo {
			return true
		}
	}
	return false
}
