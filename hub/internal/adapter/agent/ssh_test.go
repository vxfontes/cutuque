package agent

import (
	"slices"
	"testing"
)

func TestIdentityOptsAmarraChaveEKnownHosts(t *testing.T) {
	got := IdentityOpts("/data/machines/keys/vps", "/data/machines/known_hosts", 22)
	for _, quero := range [][2]string{
		{"-i", "/data/machines/keys/vps"},
		{"-o", "IdentitiesOnly=yes"},
		{"-o", "UserKnownHostsFile=/data/machines/known_hosts"},
		{"-o", "StrictHostKeyChecking=yes"},
	} {
		if !temPar(got, quero[0], quero[1]) {
			t.Errorf("faltou %s %s em %v", quero[0], quero[1], got)
		}
	}
}

// A porta entra na linha só quando não é a padrão — e precisa entrar, porque o
// known_hosts do keyscan grava "[host]:2222" e o ssh só casa essa linha
// conectando na mesma porta.
func TestIdentityOptsLevaAPortaQuandoNaoEAPadrao(t *testing.T) {
	got := IdentityOpts("/k", "/kh", 2222)
	if !temPar(got, "-p", "2222") {
		t.Errorf("faltou -p 2222 em %v", got)
	}
	if got[0] != "-p" {
		t.Errorf("a porta tem que abrir a lista (antes das opções base), veio %v", got)
	}
}

func TestIdentityOptsOmiteAPortaPadrao(t *testing.T) {
	for _, porta := range []int{0, 22} {
		if got := IdentityOpts("/k", "/kh", porta); temPar(got, "-p", "22") || temPar(got, "-p", "0") {
			t.Errorf("porta %d não devia virar -p: %v", porta, got)
		}
	}
}

// Meia identidade é pior que nenhuma: chave nova com o known_hosts do container
// (ou o contrário) conectaria com a checagem errada.
func TestIdentityOptsExigeOsDois(t *testing.T) {
	if got := IdentityOpts("/data/keys/vps", "", 22); got != nil {
		t.Errorf("sem known_hosts devia ser nil, veio %v", got)
	}
	if got := IdentityOpts("", "/data/known_hosts", 22); got != nil {
		t.Errorf("sem chave devia ser nil, veio %v", got)
	}
}

// O teste que protege a garantia toda: o ssh honra a PRIMEIRA ocorrência de
// cada opção. Se o accept-new do base viesse antes, o StrictHostKeyChecking=yes
// seria ignorado sem barulho nenhum.
func TestIdentidadeVemAntesDaBaseParaOStrictValer(t *testing.T) {
	base := []string{"-o", "StrictHostKeyChecking=accept-new", "-T"}
	got := WithIdentity(IdentityOpts("/k", "/kh", 22), base)

	primeiroStrict := -1
	for i := 0; i+1 < len(got); i++ {
		if got[i] == "-o" && (got[i+1] == "StrictHostKeyChecking=yes" || got[i+1] == "StrictHostKeyChecking=accept-new") {
			primeiroStrict = i + 1
			break
		}
	}
	if primeiroStrict == -1 {
		t.Fatalf("nenhum StrictHostKeyChecking em %v", got)
	}
	if got[primeiroStrict] != "StrictHostKeyChecking=yes" {
		t.Errorf("a primeira ocorrência é %q — o accept-new venceu e a checagem estrita virou letra morta: %v",
			got[primeiroStrict], got)
	}
}

// Sem identidade a linha tem que sair idêntica à de antes: máquina do hub.env
// não pode mudar de comportamento por causa da aba Máquinas.
func TestSemIdentidadeALinhaEAMesma(t *testing.T) {
	base := []string{"-o", "BatchMode=yes", "-T"}
	if got := WithIdentity(nil, base); !slices.Equal(got, base) {
		t.Errorf("WithIdentity(nil, base) = %v, quero %v", got, base)
	}
}

// WithIdentity não pode escrever no slice de base (ele vem de um sshBaseOpts
// compartilhado por chamada).
func TestWithIdentityNaoMexeNosSlicesDeEntrada(t *testing.T) {
	ident := []string{"-i", "/k"}
	base := []string{"-T"}
	_ = WithIdentity(ident, base)
	if !slices.Equal(ident, []string{"-i", "/k"}) || !slices.Equal(base, []string{"-T"}) {
		t.Errorf("entradas foram alteradas: ident=%v base=%v", ident, base)
	}
}

func temPar(args []string, flag, valor string) bool {
	for i := 0; i+1 < len(args); i++ {
		if args[i] == flag && args[i+1] == valor {
			return true
		}
	}
	return false
}
