package machine

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// KeyStore cuida das chaves e do known_hosts das máquinas cadastradas pelo app.
// Tudo mora em /data (o ./config/ssh do container é read-only de propósito, e o
// ~/.ssh de lá pertence às máquinas do hub.env):
//
//	<dir>/keys/<nome>      chave privada, 0600 — NUNCA sai do macmini
//	<dir>/keys/<nome>.pub  pública, é o que a usuária instala no destino
//	<dir>/known_hosts      TOFU próprio do Cutuque
type KeyStore struct{ dir string }

func NewKeyStore(dir string) *KeyStore { return &KeyStore{dir: dir} }

// KnownHostsPath é o arquivo de hosts confiados, passado ao ssh em toda conexão
// com máquina cadastrada (junto de StrictHostKeyChecking=yes).
func (k *KeyStore) KnownHostsPath() string { return filepath.Join(k.dir, "known_hosts") }

// privatePath monta o caminho da chave e recusa nome que escape da pasta. O Add
// já valida o nome; isto é defesa em profundidade, porque aqui o nome vira
// caminho de arquivo de verdade.
func (k *KeyStore) privatePath(name string) (string, error) {
	if !validName.MatchString(name) || name == "." || name == ".." {
		return "", fmt.Errorf("%w: %q", ErrInvalidName, name)
	}
	return filepath.Join(k.dir, "keys", name), nil
}

// KeyPath é o caminho da chave privada da máquina — o que vai no `ssh -i` e o
// que o registro guarda depois do Generate.
func (k *KeyStore) KeyPath(name string) (string, error) { return k.privatePath(name) }

// PublicKey lê a pública já gerada. É o que a usuária instala no destino (na
// mão ou pelo install-key); a privada não tem leitor fora do ssh.
func (k *KeyStore) PublicKey(name string) (string, error) {
	priv, err := k.privatePath(name)
	if err != nil {
		return "", err
	}
	b, err := os.ReadFile(priv + ".pub")
	if err != nil {
		return "", fmt.Errorf("a máquina %s não tem chave gerada: %w", name, err)
	}
	return strings.TrimSpace(string(b)), nil
}

// keygenTimeout / scanTimeout: gerar chave é instantâneo, mas o keyscan fala com
// a rede e pode pendurar num host que não responde.
const (
	keygenTimeout = 15 * time.Second
	scanTimeout   = 20 * time.Second
)

// Generate cria (ou recria) o par ed25519 da máquina e devolve a chave PÚBLICA
// — a privada não sai daqui. Sem passphrase: o hub precisa conectar sozinho.
func (k *KeyStore) Generate(name string) (string, error) {
	priv, err := k.privatePath(name)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(priv), 0o700); err != nil {
		return "", err
	}
	// O ssh-keygen recusa sobrescrever (só pergunta em modo interativo, e aqui
	// não há tty): tira os antigos antes. Recadastrar com o mesmo nome tem que
	// funcionar.
	_ = os.Remove(priv)
	_ = os.Remove(priv + ".pub")

	ctx, cancel := context.WithTimeout(context.Background(), keygenTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ssh-keygen",
		"-t", "ed25519",
		"-N", "", // sem passphrase
		"-C", "cutuque-"+name, // identifica a chave na authorized_keys remota
		"-f", priv,
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("ssh-keygen falhou: %v — %s", err, strings.TrimSpace(string(out)))
	}
	// O ssh-keygen já cria a privada 0600; garantimos por via das dúvidas.
	_ = os.Chmod(priv, 0o600)

	pub, err := os.ReadFile(priv + ".pub")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(pub)), nil
}

// RemoveKey apaga o par da máquina. Ausente não é erro: remover uma máquina que
// nunca teve chave instalada é legítimo.
func (k *KeyStore) RemoveKey(name string) error {
	priv, err := k.privatePath(name)
	if err != nil {
		return err
	}
	for _, p := range []string{priv, priv + ".pub"} {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

// hostOf tira o host do destino ("user@host" → "host"). Sem @, o destino todo é
// o host (pode ser um alias do ~/.ssh/config). Corta só no PRIMEIRO @: o resto
// é parte do host.
func hostOf(dest string) string {
	if _, host, found := strings.Cut(dest, "@"); found {
		return host
	}
	return dest
}

// Scan busca as chaves públicas do host (ssh-keyscan) e devolve as linhas no
// formato do known_hosts junto da impressão digital para a usuária conferir.
//
// Isto é o passo TOFU: nada é gravado aqui. Só o Trust, depois da confirmação,
// escreve no known_hosts.
func (k *KeyStore) Scan(ctx context.Context, dest string, port int) (lines, fingerprint string, err error) {
	host := hostOf(dest)
	if host == "" || strings.HasPrefix(host, "-") {
		return "", "", fmt.Errorf("%w: %q", ErrInvalidDest, dest)
	}
	if port <= 0 {
		port = defaultSSHPort
	}
	ctx, cancel := context.WithTimeout(ctx, scanTimeout)
	defer cancel()

	// "--" para o host nunca ser reinterpretado como opção.
	out, err := exec.CommandContext(ctx, "ssh-keyscan", "-p", fmt.Sprint(port), "--", host).Output()
	if err != nil {
		return "", "", fmt.Errorf("não deu para ler a chave de %s: %w", host, err)
	}
	if strings.TrimSpace(stripComments(string(out))) == "" {
		return "", "", fmt.Errorf("%s não respondeu com nenhuma chave ssh", host)
	}

	// O fingerprint sai do próprio ssh-keygen -l, lendo as linhas pelo stdin.
	fpCmd := exec.CommandContext(ctx, "ssh-keygen", "-l", "-f", "-")
	fpCmd.Stdin = strings.NewReader(string(out))
	fpOut, err := fpCmd.Output()
	if err != nil {
		return "", "", fmt.Errorf("não deu para calcular a impressão digital: %w", err)
	}
	fp := parseFingerprint(fpOut)
	if fp == "" {
		return "", "", fmt.Errorf("impressão digital de %s veio ilegível", host)
	}
	return string(out), fp, nil
}

// parseFingerprint tira o "SHA256:..." da saída do `ssh-keygen -l`, cujo
// formato é "<bits> <fingerprint> <comentário> (<tipo>)". Havendo várias
// chaves, a primeira serve: é a que a usuária confere.
func parseFingerprint(out []byte) string {
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && strings.HasPrefix(fields[1], "SHA256:") {
			return fields[1]
		}
	}
	return ""
}

// stripComments tira as linhas de comentário do ssh-keyscan (ele emite a versão
// do servidor com "#"), que não têm o que fazer no known_hosts.
func stripComments(s string) string {
	var keep []string
	for _, line := range strings.Split(s, "\n") {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		keep = append(keep, t)
	}
	if len(keep) == 0 {
		return ""
	}
	return strings.Join(keep, "\n") + "\n"
}

// Trust grava no known_hosts as linhas que a usuária confirmou. Linha repetida
// é ignorada: recadastrar a mesma máquina não pode transformar o arquivo num
// lixão (o ssh reclama de entradas duplicadas).
func (k *KeyStore) Trust(lines string) error {
	novas := stripComments(lines)
	if novas == "" {
		return fmt.Errorf("nada para confiar: nenhuma chave válida")
	}
	if err := os.MkdirAll(k.dir, 0o700); err != nil {
		return err
	}
	path := k.KnownHostsPath()

	atual, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	existentes := make(map[string]bool)
	for _, l := range strings.Split(string(atual), "\n") {
		if t := strings.TrimSpace(l); t != "" {
			existentes[t] = true
		}
	}
	var add []string
	for _, l := range strings.Split(strings.TrimSpace(novas), "\n") {
		if !existentes[l] {
			add = append(add, l)
		}
	}
	if len(add) == 0 {
		return nil
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(strings.Join(add, "\n") + "\n")
	return err
}
