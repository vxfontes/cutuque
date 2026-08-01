package machine

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// MARK: caminho da chave

// O nome vira nome de arquivo. Como o Add já recusa nome com barra ou "..", o
// KeyStore não deve conseguir escrever fora da pasta de chaves nem se chamado
// direto — defesa em profundidade.
func TestKeyPathNaoEscapaDaPasta(t *testing.T) {
	ks := NewKeyStore("/data/machines")
	for _, nome := range []string{"../fuga", "a/b", "..", "/etc/passwd"} {
		if _, err := ks.privatePath(nome); err == nil {
			t.Errorf("nome %q devia ser recusado", nome)
		}
	}
	p, err := ks.privatePath("vps")
	if err != nil {
		t.Fatalf("nome válido recusado: %v", err)
	}
	if p != "/data/machines/keys/vps" {
		t.Errorf("caminho errado: %q", p)
	}
}

// MARK: geração

func TestGenerateCriaOParEDevolveAPublica(t *testing.T) {
	ks := NewKeyStore(t.TempDir())
	pub, err := ks.Generate("vps")
	if err != nil {
		t.Fatalf("Generate falhou: %v", err)
	}
	if !strings.HasPrefix(pub, "ssh-ed25519 ") {
		t.Errorf("a pública não parece ed25519: %q", pub)
	}
	// Comentário com o nome ajuda a identificar a chave na authorized_keys da
	// máquina remota meses depois.
	if !strings.Contains(pub, "cutuque-vps") {
		t.Errorf("a pública não tem o comentário do cutuque: %q", pub)
	}
	priv, _ := ks.privatePath("vps")
	info, err := os.Stat(priv)
	if err != nil {
		t.Fatalf("a privada não foi criada: %v", err)
	}
	// Chave privada legível por outros é chave vazada.
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("permissão da privada = %o, esperava 600", perm)
	}
}

// Cadastrar de novo com o mesmo nome (depois de remover) não pode falhar por
// causa do arquivo antigo — o ssh-keygen recusa sobrescrever sem -y.
func TestGenerateSobrescreveChaveAntiga(t *testing.T) {
	ks := NewKeyStore(t.TempDir())
	primeira, err := ks.Generate("vps")
	if err != nil {
		t.Fatalf("Generate falhou: %v", err)
	}
	segunda, err := ks.Generate("vps")
	if err != nil {
		t.Fatalf("segundo Generate falhou: %v", err)
	}
	if primeira == segunda {
		t.Error("a segunda geração devolveu a mesma chave — não regerou")
	}
}

func TestRemoveKeyApagaOsDoisArquivos(t *testing.T) {
	ks := NewKeyStore(t.TempDir())
	if _, err := ks.Generate("vps"); err != nil {
		t.Fatalf("Generate falhou: %v", err)
	}
	if err := ks.RemoveKey("vps"); err != nil {
		t.Fatalf("RemoveKey falhou: %v", err)
	}
	priv, _ := ks.privatePath("vps")
	for _, p := range []string{priv, priv + ".pub"} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s ainda existe", p)
		}
	}
	// Apagar de novo (ou máquina que nunca teve chave) não é erro.
	if err := ks.RemoveKey("vps"); err != nil {
		t.Errorf("RemoveKey de chave ausente não devia falhar: %v", err)
	}
}

// MARK: fingerprint

func TestFingerprintDaSaidaDoSshKeygen(t *testing.T) {
	out := "256 SHA256:abcDEF123 host.exemplo (ED25519)\n"
	if got := parseFingerprint([]byte(out)); got != "SHA256:abcDEF123" {
		t.Errorf("fingerprint = %q", got)
	}
}

// Várias chaves (rsa, ecdsa, ed25519) vêm em linhas separadas; a primeira serve.
func TestFingerprintPegaAPrimeiraDeVarias(t *testing.T) {
	out := "3072 SHA256:umRSA host (RSA)\n256 SHA256:umED host (ED25519)\n"
	if got := parseFingerprint([]byte(out)); got != "SHA256:umRSA" {
		t.Errorf("fingerprint = %q", got)
	}
}

func TestFingerprintDeSaidaVaziaOuEstranha(t *testing.T) {
	for _, out := range []string{"", "   \n", "lixo"} {
		if got := parseFingerprint([]byte(out)); got != "" {
			t.Errorf("saída %q devia dar fingerprint vazio, veio %q", out, got)
		}
	}
}

// MARK: host do destino

func TestHostDoDest(t *testing.T) {
	casos := map[string]string{
		"vx@192.0.2.20": "192.0.2.20",
		"vx@host.local": "host.local",
		"apelido":       "apelido", // alias do ~/.ssh/config
		"a@b@c":         "b@c",     // só o primeiro @ separa o usuário
	}
	for dest, quero := range casos {
		if got := hostOf(dest); got != quero {
			t.Errorf("hostOf(%q) = %q, quero %q", dest, got, quero)
		}
	}
}

// MARK: known_hosts

func TestTrustGravaAsChavesDoHost(t *testing.T) {
	dir := t.TempDir()
	ks := NewKeyStore(dir)
	linhas := "host.exemplo ssh-ed25519 AAAAC3Nz...\n"
	if err := ks.Trust(linhas); err != nil {
		t.Fatalf("Trust falhou: %v", err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "known_hosts"))
	if err != nil {
		t.Fatalf("known_hosts não foi criado: %v", err)
	}
	if !strings.Contains(string(b), "ssh-ed25519 AAAAC3Nz") {
		t.Errorf("known_hosts sem a chave: %q", b)
	}
}

// Confiar duas vezes na mesma máquina (recadastro) não pode duplicar a linha:
// o known_hosts viraria um lixão e o ssh reclamaria.
func TestTrustNaoDuplicaLinha(t *testing.T) {
	dir := t.TempDir()
	ks := NewKeyStore(dir)
	linha := "host.exemplo ssh-ed25519 AAAAC3Nz...\n"
	_ = ks.Trust(linha)
	_ = ks.Trust(linha)
	b, _ := os.ReadFile(filepath.Join(dir, "known_hosts"))
	if n := strings.Count(string(b), "AAAAC3Nz"); n != 1 {
		t.Errorf("a linha aparece %d vezes, esperava 1: %q", n, b)
	}
}

// Comentários do ssh-keyscan (linhas com #) não devem ir para o known_hosts.
func TestTrustIgnoraComentariosDoKeyscan(t *testing.T) {
	dir := t.TempDir()
	ks := NewKeyStore(dir)
	_ = ks.Trust("# host.exemplo:22 SSH-2.0-OpenSSH_9.6\nhost.exemplo ssh-ed25519 AAAAC3Nz...\n")
	b, _ := os.ReadFile(filepath.Join(dir, "known_hosts"))
	if strings.Contains(string(b), "#") {
		t.Errorf("comentário foi parar no known_hosts: %q", b)
	}
}

func TestKnownHostsPathFicaEmData(t *testing.T) {
	ks := NewKeyStore("/data/machines")
	if got := ks.KnownHostsPath(); got != "/data/machines/known_hosts" {
		t.Errorf("known_hosts em %q — tem que ser dentro de /data", got)
	}
}
