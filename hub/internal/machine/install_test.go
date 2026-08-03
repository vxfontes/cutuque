package machine

import (
	"crypto/sha256"
	"encoding/base64"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

// fakeKey é uma ssh.PublicKey cujo fingerprint é escolhido pelo teste. O
// FingerprintSHA256 é derivado do Marshal(), então basta um blob cujo hash dê o
// valor desejado — inverte-se a conta: o teste diz o fingerprint, o fake produz
// bytes e o cálculo confere.
type fakeKey struct{ fp string }

func (k fakeKey) Type() string { return "ssh-ed25519" }
func (k fakeKey) Marshal() []byte {
	// Bytes arbitrários; o que importa é o fingerprint calculado abaixo bater.
	return []byte(k.fp)
}
func (k fakeKey) Verify([]byte, *ssh.Signature) error { return nil }

// fingerprintDe replica o cálculo do x/crypto para o teste montar a expectativa.
func fingerprintDe(k ssh.PublicKey) string {
	sum := sha256.Sum256(k.Marshal())
	return "SHA256:" + strings.TrimRight(base64.StdEncoding.EncodeToString(sum[:]), "=")
}

// MARK: já instalada?

func TestJaTemAChaveReconheceALinhaExata(t *testing.T) {
	pub := "ssh-ed25519 AAAAC3NzaC1 cutuque-vps"
	authorized := "ssh-rsa AAAAB3 outra@maquina\nssh-ed25519 AAAAC3NzaC1 cutuque-vps\n"
	if !jaTemAChave(authorized, pub) {
		t.Error("não reconheceu a chave que já está instalada")
	}
}

// Espaço em volta e \r do Windows não podem fazer o hub reinstalar a mesma
// chave a cada cadastro.
func TestJaTemAChaveIgnoraEspacoEmVolta(t *testing.T) {
	pub := "ssh-ed25519 AAAAC3NzaC1 cutuque-vps"
	if !jaTemAChave("  ssh-ed25519 AAAAC3NzaC1 cutuque-vps  \r\n", pub) {
		t.Error("espaço/CR em volta atrapalhou o reconhecimento")
	}
}

// Prefixo em comum não é a mesma chave: instalar por engano seria dar acesso a
// quem não deveria.
func TestJaTemAChaveNaoConfundePrefixo(t *testing.T) {
	pub := "ssh-ed25519 AAAAC3NzaC1 cutuque-vps"
	if jaTemAChave("ssh-ed25519 AAAAC3NzaC1XYZ cutuque-outra\n", pub) {
		t.Error("confundiu chave diferente com prefixo em comum")
	}
}

func TestJaTemAChaveEmArquivoVazio(t *testing.T) {
	if jaTemAChave("", "ssh-ed25519 AAAA x") {
		t.Error("arquivo vazio não contém chave nenhuma")
	}
}

// MARK: verificação do host

// A senha só é enviada DEPOIS de o host provar ser quem a usuária confirmou.
// Fingerprint diferente tem que abortar antes de qualquer autenticação.
func TestCallbackDeHostRecusaFingerprintDiferente(t *testing.T) {
	confirmado := fakeKey{fp: "o-host-certo"}
	intruso := fakeKey{fp: "o-host-do-atacante"}

	cb := hostKeyCallback(fingerprintDe(confirmado))
	err := cb("host:22", nil, intruso)
	if err == nil {
		t.Fatal("fingerprint diferente tem que recusar a conexão")
	}
	// O erro precisa dizer qual chave apareceu: é como a usuária descobre que
	// não foi um engano dela.
	if !strings.Contains(err.Error(), fingerprintDe(intruso)) {
		t.Errorf("o erro não diz qual chave apareceu: %v", err)
	}
}

func TestCallbackDeHostAceitaOFingerprintConfirmado(t *testing.T) {
	k := fakeKey{fp: "o-host-certo"}
	if err := hostKeyCallback(fingerprintDe(k))("host:22", nil, k); err != nil {
		t.Errorf("o fingerprint confirmado devia passar: %v", err)
	}
}

// Sem fingerprint confirmado não há TOFU: conectar seria MITM aberto, e é
// exatamente aí que a senha viajaria.
func TestCallbackDeHostSemFingerprintRecusa(t *testing.T) {
	if err := hostKeyCallback("")("host:22", nil, fakeKey{fp: "qualquer"}); err == nil {
		t.Error("sem fingerprint confirmado a conexão tem que ser recusada")
	}
}

// O cálculo do teste tem que ser o MESMO do x/crypto — se divergirem, os testes
// acima passariam comparando dois valores errados entre si.
func TestOFingerprintDoTesteBateComODoXCrypto(t *testing.T) {
	k := fakeKey{fp: "qualquer-coisa"}
	if fingerprintDe(k) != ssh.FingerprintSHA256(k) {
		t.Fatalf("cálculo divergente: teste=%s x/crypto=%s", fingerprintDe(k), ssh.FingerprintSHA256(k))
	}
}

// MARK: endereço

func TestEnderecoJuntaHostEPorta(t *testing.T) {
	casos := map[string]string{
		"vx@192.0.2.20": "192.0.2.20:2222",
		"apelido":       "apelido:2222",
	}
	for dest, quero := range casos {
		if got := addrOf(dest, 2222); got != quero {
			t.Errorf("addrOf(%q) = %q, quero %q", dest, got, quero)
		}
	}
	if got := addrOf("vx@host", 0); got != "host:22" {
		t.Errorf("porta 0 devia virar 22, veio %q", got)
	}
}

func TestUsuarioDoDest(t *testing.T) {
	if got := userOf("vx@host"); got != "vx" {
		t.Errorf("userOf = %q, quero vx", got)
	}
	// Sem usuário no destino não dá para autenticar com senha: o hub não tem
	// como adivinhar a conta.
	if got := userOf("apelido"); got != "" {
		t.Errorf("destino sem @ não tem usuário, veio %q", got)
	}
}
