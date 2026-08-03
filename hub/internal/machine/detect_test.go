package machine

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

// Só os helpers puros de detect.go são testáveis sem rede: primeiraLinha (que
// limpa a saída do shell remoto) e keyAuth (que lê a chave da identidade em
// disco). DetectOS em si abre socket de verdade e fica fora daqui.

// MARK: primeiraLinha

func TestPrimeiraLinhaIgnoraBrancoNoComeco(t *testing.T) {
	out := "\n   \n\nDarwin 24.5.0\noutra linha depois"
	got := primeiraLinha(out)
	if got != "Darwin 24.5.0" {
		t.Errorf("got = %q, esperava %q", got, "Darwin 24.5.0")
	}
}

func TestPrimeiraLinhaPegaAPrimeiraNaoVazia(t *testing.T) {
	got := primeiraLinha("Ubuntu 24.04\nsegunda linha")
	if got != "Ubuntu 24.04" {
		t.Errorf("got = %q", got)
	}
}

// Teto de 120 caracteres: isto vai para o registro e para a tela, não é lugar
// de despejar saída de shell (motd gigante, por exemplo).
func TestPrimeiraLinhaCortaEm120Caracteres(t *testing.T) {
	longa := strings.Repeat("x", 200)
	got := primeiraLinha(longa)
	if len(got) != 120 {
		t.Fatalf("len(got) = %d, esperava 120", len(got))
	}
	if got != strings.Repeat("x", 120) {
		t.Error("o corte não preservou o prefixo")
	}
}

func TestPrimeiraLinhaStringVaziaDevolveVazia(t *testing.T) {
	if got := primeiraLinha(""); got != "" {
		t.Errorf("got = %q, esperava vazio", got)
	}
	// Só espaço/quebra de linha também é "vazio" no sentido de primeiraLinha.
	if got := primeiraLinha("\n\n   \n"); got != "" {
		t.Errorf("got = %q, esperava vazio", got)
	}
}

// MARK: keyAuth

func TestKeyAuthCaminhoVazioDaErroDizendoQueFaltaChave(t *testing.T) {
	_, err := keyAuth("")
	if err == nil {
		t.Fatal("aceitou caminho vazio")
	}
	if !strings.Contains(err.Error(), "não tem chave") {
		t.Errorf("erro = %v, esperava mencionar que a identidade não tem chave", err)
	}
}

// keyAuth("   ") — só espaço — cai no mesmo caso de "sem chave", pelo mesmo
// TrimSpace que newSecretBox usa para a env var.
func TestKeyAuthCaminhoSoEspacoDaErro(t *testing.T) {
	_, err := keyAuth("   ")
	if err == nil {
		t.Fatal("aceitou caminho só de espaço")
	}
}

func TestKeyAuthCaminhoInexistenteDaErro(t *testing.T) {
	_, err := keyAuth(filepath.Join(t.TempDir(), "nao-existe"))
	if err == nil {
		t.Fatal("aceitou caminho que não existe")
	}
}

func TestKeyAuthConteudoQueNaoEChaveDaErro(t *testing.T) {
	caminho := filepath.Join(t.TempDir(), "nao-e-chave")
	if err := os.WriteFile(caminho, []byte("isto não é uma chave privada ssh"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	_, err := keyAuth(caminho)
	if err == nil {
		t.Fatal("aceitou arquivo que não é chave")
	}
}

// Caso de sucesso: gera um par ed25519 de verdade e serializa com
// ssh.MarshalPrivateKey (golang.org/x/crypto/ssh) — sem chamar o binário
// ssh-keygen, que não existe em todo runner de CI.
func TestKeyAuthComChaveEd25519ValidaFunciona(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	bloco, err := ssh.MarshalPrivateKey(priv, "cutuque-teste")
	if err != nil {
		t.Fatalf("MarshalPrivateKey: %v", err)
	}
	caminho := filepath.Join(t.TempDir(), "id_ed25519")
	if err := os.WriteFile(caminho, pem.EncodeToMemory(bloco), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	auth, err := keyAuth(caminho)
	if err != nil {
		t.Fatalf("keyAuth com chave válida falhou: %v", err)
	}
	if auth == nil {
		t.Error("keyAuth devolveu AuthMethod nil sem erro")
	}
}
