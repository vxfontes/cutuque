package machine

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Estes testes travam os invariantes do IdentityStore descritos em identity.go:
// ordem de cadastro estável, validação de nome/usuário, o PATCH que nunca apaga
// senha por omissão, a recusa a guardar senha sem cifra, o bloqueio de remoção
// em uso, e — o mais importante — que a senha NUNCA escapa por json.Marshal.

// MARK: cadastro básico / ordem / duplicidade / validação

func TestAddGetListMantemOrdemDeCadastro(t *testing.T) {
	s := NewIdentityStore()
	for _, nome := range []string{"vanessa", "ci", "backup"} {
		if _, err := s.Add(Identity{Name: nome, Username: "vx"}, ""); err != nil {
			t.Fatalf("Add(%q): %v", nome, err)
		}
	}
	lista := s.List()
	if len(lista) != 3 {
		t.Fatalf("len(List()) = %d, esperava 3", len(lista))
	}
	ordem := []string{lista[0].Name, lista[1].Name, lista[2].Name}
	esperado := []string{"vanessa", "ci", "backup"}
	for i := range esperado {
		if ordem[i] != esperado[i] {
			t.Errorf("ordem = %v, esperava %v", ordem, esperado)
			break
		}
	}
	got, ok := s.Get("ci")
	if !ok || got.Name != "ci" {
		t.Errorf("Get(ci) = %+v, %v", got, ok)
	}
}

func TestAddNomeDuplicadoRecusa(t *testing.T) {
	s := NewIdentityStore()
	if _, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, ""); err != nil {
		t.Fatalf("primeiro Add: %v", err)
	}
	_, err := s.Add(Identity{Name: "vanessa", Username: "outro"}, "")
	if !errors.Is(err, ErrDuplicateIdentity) {
		t.Fatalf("erro = %v, esperava ErrDuplicateIdentity", err)
	}
}

func TestAddNomeInvalido(t *testing.T) {
	nomes := []string{".", "..", "../x", "", "com/barra"}
	for _, nome := range nomes {
		s := NewIdentityStore()
		_, err := s.Add(Identity{Name: nome, Username: "vx"}, "")
		if !errors.Is(err, ErrInvalidName) {
			t.Errorf("nome %q: erro = %v, esperava ErrInvalidName", nome, err)
		}
	}
}

func TestAddUsuarioInvalido(t *testing.T) {
	usuarios := []string{"vx@host", "com espaço", "-comecacomtraco", ""}
	for _, u := range usuarios {
		s := NewIdentityStore()
		_, err := s.Add(Identity{Name: "id1", Username: u}, "")
		if !errors.Is(err, ErrInvalidUsername) {
			t.Errorf("usuário %q: erro = %v, esperava ErrInvalidUsername", u, err)
		}
	}
}

// MARK: senha sem cifra / com cifra

// Store sem cifra recusa Add com senha, e a identidade NÃO fica criada pela
// metade — não é "cria sem a senha", é "não cria".
func TestAddComSenhaSemCifraRecusaENaoCria(t *testing.T) {
	s := NewIdentityStore() // sem chave: box == nil
	_, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, "senha-qualquer")
	if !errors.Is(err, ErrNoSecretKey) {
		t.Fatalf("erro = %v, esperava ErrNoSecretKey", err)
	}
	if _, ok := s.Get("vanessa"); ok {
		t.Error("a identidade foi criada mesmo com o Add tendo recusado a senha")
	}
}

func TestAddComSenhaComCifraFuncionaERoundTrip(t *testing.T) {
	s, err := NewIdentityStoreAt("", chave32(0x10))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt: %v", err)
	}
	id, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, "senha-secreta")
	if err != nil {
		t.Fatalf("Add: %v", err)
	}
	if !id.HasPassword {
		t.Error("HasPassword = false, esperava true")
	}
	senha, err := s.Password("vanessa")
	if err != nil {
		t.Fatalf("Password: %v", err)
	}
	if senha != "senha-secreta" {
		t.Errorf("Password = %q, esperava %q", senha, "senha-secreta")
	}
}

// O teste mais importante do arquivo: serializar uma Identity com senha não
// pode, de jeito nenhum, colocar a senha (nem o ciphertext, nem o KeyPath) no
// JSON que vai para o app. secret é minúsculo de propósito e KeyPath tem
// `json:"-"`; isto trava os dois contra um refactor futuro que os exponha.
func TestJSONMarshalDeIdentityComSenhaNaoVazaNada(t *testing.T) {
	s, err := NewIdentityStoreAt("", chave32(0x11))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt: %v", err)
	}
	id, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, "senha-ultra-secreta-nao-pode-vazar")
	if err != nil {
		t.Fatalf("Add: %v", err)
	}
	if err := s.SetKeyPath("vanessa", "/data/machines/keys/vanessa"); err != nil {
		t.Fatalf("SetKeyPath: %v", err)
	}
	id, _ = s.Get("vanessa")

	b, err := json.Marshal(id)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	corpo := string(b)
	for _, proibido := range []string{"senha-ultra-secreta-nao-pode-vazar", "/data/machines/keys", "secret", "key_path", "KeyPath"} {
		if strings.Contains(corpo, proibido) {
			t.Errorf("json.Marshal vazou %q: %s", proibido, corpo)
		}
	}
	// E o que TEM que estar lá: has_password, sem dizer qual.
	if !strings.Contains(corpo, `"has_password":true`) {
		t.Errorf("has_password não apareceu como true: %s", corpo)
	}
}

// MARK: Update

func TestUpdatePasswordNilMantemASenhaAtual(t *testing.T) {
	s, err := NewIdentityStoreAt("", chave32(0x12))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt: %v", err)
	}
	if _, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, "senha-original"); err != nil {
		t.Fatalf("Add: %v", err)
	}
	// PATCH só troca o username; password nil não pode mexer na senha.
	if _, err := s.Update("vanessa", "outro-usuario", nil); err != nil {
		t.Fatalf("Update: %v", err)
	}
	senha, err := s.Password("vanessa")
	if err != nil || senha != "senha-original" {
		t.Errorf("Password após Update(password=nil) = %q, %v — esperava manter senha-original", senha, err)
	}
}

func TestUpdatePasswordVazioApagaASenha(t *testing.T) {
	s, err := NewIdentityStoreAt("", chave32(0x13))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt: %v", err)
	}
	if _, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, "senha-original"); err != nil {
		t.Fatalf("Add: %v", err)
	}
	vazio := ""
	id, err := s.Update("vanessa", "", &vazio)
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if id.HasPassword {
		t.Error("HasPassword continua true depois do PATCH que apaga a senha")
	}
	if _, err := s.Password("vanessa"); !errors.Is(err, ErrNoPassword) {
		t.Errorf("Password após apagar = %v, esperava ErrNoPassword", err)
	}
}

func TestUpdatePasswordTextoTrocaASenha(t *testing.T) {
	s, err := NewIdentityStoreAt("", chave32(0x14))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt: %v", err)
	}
	if _, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, "senha-velha"); err != nil {
		t.Fatalf("Add: %v", err)
	}
	nova := "senha-nova"
	if _, err := s.Update("vanessa", "", &nova); err != nil {
		t.Fatalf("Update: %v", err)
	}
	senha, err := s.Password("vanessa")
	if err != nil || senha != "senha-nova" {
		t.Errorf("Password após troca = %q, %v", senha, err)
	}
}

func TestUpdateUsernameVazioMantemOAtual(t *testing.T) {
	s := NewIdentityStore()
	if _, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, ""); err != nil {
		t.Fatalf("Add: %v", err)
	}
	id, err := s.Update("vanessa", "", nil)
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if id.Username != "vx" {
		t.Errorf("Username = %q, esperava manter vx", id.Username)
	}
}

// Username inválido no PATCH tem que recusar SEM mudar nada — nem o username
// (óbvio) nem, por acidente de ordem de código, a senha.
func TestUpdateUsernameInvalidoRecusaENadaMuda(t *testing.T) {
	s, err := NewIdentityStoreAt("", chave32(0x15))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt: %v", err)
	}
	if _, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, "senha-original"); err != nil {
		t.Fatalf("Add: %v", err)
	}
	nova := "nao-deveria-entrar"
	_, err = s.Update("vanessa", "usuario com espaço", &nova)
	if !errors.Is(err, ErrInvalidUsername) {
		t.Fatalf("erro = %v, esperava ErrInvalidUsername", err)
	}
	id, _ := s.Get("vanessa")
	if id.Username != "vx" {
		t.Errorf("username mudou mesmo com o Update recusado: %q", id.Username)
	}
	senha, err := s.Password("vanessa")
	if err != nil || senha != "senha-original" {
		t.Errorf("a senha mudou mesmo com o Update recusado: %q, %v", senha, err)
	}
}

// Update com senha num store sem cifra: recusa e nada muda (nem o username,
// que vinha junto no mesmo PATCH).
func TestUpdateComSenhaSemCifraRecusaENadaMuda(t *testing.T) {
	s := NewIdentityStore()
	if _, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, ""); err != nil {
		t.Fatalf("Add: %v", err)
	}
	nova := "nao-pode-entrar"
	_, err := s.Update("vanessa", "outro-usuario", &nova)
	if !errors.Is(err, ErrNoSecretKey) {
		t.Fatalf("erro = %v, esperava ErrNoSecretKey", err)
	}
	id, _ := s.Get("vanessa")
	if id.Username != "vx" {
		t.Errorf("username mudou mesmo com o Update recusado: %q", id.Username)
	}
	if id.HasPassword {
		t.Error("HasPassword virou true num store sem cifra")
	}
}

// MARK: Remove

func TestRemoveEmUsoRecusaEContinuaLa(t *testing.T) {
	s := NewIdentityStore()
	if _, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, ""); err != nil {
		t.Fatalf("Add: %v", err)
	}
	emUso := func(nome string) bool { return nome == "vanessa" }
	err := s.Remove("vanessa", emUso)
	if !errors.Is(err, ErrIdentityInUse) {
		t.Fatalf("erro = %v, esperava ErrIdentityInUse", err)
	}
	if _, ok := s.Get("vanessa"); !ok {
		t.Error("a identidade sumiu mesmo com Remove recusado por estar em uso")
	}
}

func TestRemoveSemUsoSai(t *testing.T) {
	s := NewIdentityStore()
	if _, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, ""); err != nil {
		t.Fatalf("Add: %v", err)
	}
	semUso := func(string) bool { return false }
	if err := s.Remove("vanessa", semUso); err != nil {
		t.Fatalf("Remove: %v", err)
	}
	if _, ok := s.Get("vanessa"); ok {
		t.Error("a identidade continua depois do Remove")
	}
}

func TestRemoveInexistenteE404Logico(t *testing.T) {
	s := NewIdentityStore()
	err := s.Remove("fantasma", nil)
	if !errors.Is(err, ErrIdentityNotFound) {
		t.Fatalf("erro = %v, esperava ErrIdentityNotFound", err)
	}
}

// MARK: SetKeyPath

func TestSetKeyPathGravaEApareceNoGet(t *testing.T) {
	s := NewIdentityStore()
	if _, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, ""); err != nil {
		t.Fatalf("Add: %v", err)
	}
	if err := s.SetKeyPath("vanessa", "/data/machines/keys/vanessa"); err != nil {
		t.Fatalf("SetKeyPath: %v", err)
	}
	id, _ := s.Get("vanessa")
	if id.KeyPath != "/data/machines/keys/vanessa" {
		t.Errorf("KeyPath = %q", id.KeyPath)
	}
}

// MARK: persistência

func TestPersistenciaReabreComAMesmaChaveLeAASenha(t *testing.T) {
	path := filepath.Join(t.TempDir(), "identities.json")
	keyB64 := chave32(0x20)

	s1, err := NewIdentityStoreAt(path, keyB64)
	if err != nil {
		t.Fatalf("NewIdentityStoreAt (1): %v", err)
	}
	if _, err := s1.Add(Identity{Name: "vanessa", Username: "vx"}, "senha-persistida"); err != nil {
		t.Fatalf("Add: %v", err)
	}

	s2, err := NewIdentityStoreAt(path, keyB64)
	if err != nil {
		t.Fatalf("NewIdentityStoreAt (2): %v", err)
	}
	id, ok := s2.Get("vanessa")
	if !ok {
		t.Fatal("a identidade não sobreviveu ao restart")
	}
	if !id.HasPassword {
		t.Error("HasPassword = false depois do restart")
	}
	senha, err := s2.Password("vanessa")
	if err != nil || senha != "senha-persistida" {
		t.Errorf("Password depois do restart = %q, %v", senha, err)
	}
}

// Reabrir com uma chave DIFERENTE da que gravou: HasPassword continua true (o
// hub não finge que a senha sumiu — ela está lá, só ilegível), mas Password dá
// ErrSecretUnreadable. Isto é o caso real de CUTUQUE_IDENTITY_KEY rotacionada
// sem migrar as senhas antigas.
func TestPersistenciaReabreComChaveDiferenteMantemHasPasswordMasNaoLe(t *testing.T) {
	path := filepath.Join(t.TempDir(), "identities.json")

	s1, err := NewIdentityStoreAt(path, chave32(0x21))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt (1): %v", err)
	}
	if _, err := s1.Add(Identity{Name: "vanessa", Username: "vx"}, "senha-original"); err != nil {
		t.Fatalf("Add: %v", err)
	}

	s2, err := NewIdentityStoreAt(path, chave32(0x22)) // chave diferente
	if err != nil {
		t.Fatalf("NewIdentityStoreAt (2): %v", err)
	}
	id, ok := s2.Get("vanessa")
	if !ok {
		t.Fatal("a identidade sumiu ao trocar a chave — deveria continuar, só ilegível")
	}
	if !id.HasPassword {
		t.Error("HasPassword virou false só porque a chave mudou — o hub não pode fingir que a senha sumiu")
	}
	_, err = s2.Password("vanessa")
	if !errors.Is(err, ErrSecretUnreadable) {
		t.Errorf("Password com chave trocada = %v, esperava ErrSecretUnreadable", err)
	}
}

// Reabrir SEM chave nenhuma: o hub ainda sobe (não é fatal), só não consegue
// ler a senha guardada.
func TestPersistenciaReabreSemChaveHubSobeMasNaoLeASenha(t *testing.T) {
	path := filepath.Join(t.TempDir(), "identities.json")

	s1, err := NewIdentityStoreAt(path, chave32(0x23))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt (1): %v", err)
	}
	if _, err := s1.Add(Identity{Name: "vanessa", Username: "vx"}, "senha-original"); err != nil {
		t.Fatalf("Add: %v", err)
	}

	s2, err := NewIdentityStoreAt(path, "") // sem chave
	if err != nil {
		t.Fatalf("NewIdentityStoreAt sem chave não pode falhar o boot: %v", err)
	}
	if _, ok := s2.Get("vanessa"); !ok {
		t.Fatal("a identidade sumiu ao subir sem chave")
	}
	if _, err := s2.Password("vanessa"); err == nil {
		t.Error("Password funcionou sem nenhuma chave configurada")
	}
}

// Arquivo corrompido em disco: o store sobe VAZIO em vez de derrubar o boot do
// hub. Um /data corrompido não pode ser motivo para o hub inteiro não subir.
func TestArquivoCorrompidoSobeVazio(t *testing.T) {
	path := filepath.Join(t.TempDir(), "identities.json")
	if err := os.WriteFile(path, []byte("nao é json"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	s, err := NewIdentityStoreAt(path, "")
	if err != nil {
		t.Fatalf("NewIdentityStoreAt não pode falhar com disco corrompido: %v", err)
	}
	if len(s.List()) != 0 {
		t.Errorf("List() = %v, esperava vazio com arquivo corrompido", s.List())
	}
}

// O arquivo persistido carrega segredo cifrado e usuários remotos: 0600, nunca
// legível por outro usuário do sistema.
func TestArquivoPersistidoTemPermissao0600(t *testing.T) {
	path := filepath.Join(t.TempDir(), "identities.json")
	s, err := NewIdentityStoreAt(path, chave32(0x24))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt: %v", err)
	}
	if _, err := s.Add(Identity{Name: "vanessa", Username: "vx"}, "senha"); err != nil {
		t.Fatalf("Add: %v", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("permissão = %o, esperava 0600", perm)
	}
}

// MARK: CanStorePassword

func TestCanStorePasswordReflecteACifra(t *testing.T) {
	semCifra := NewIdentityStore()
	if semCifra.CanStorePassword() {
		t.Error("CanStorePassword = true sem cifra configurada")
	}
	comCifra, err := NewIdentityStoreAt("", chave32(0x25))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt: %v", err)
	}
	if !comCifra.CanStorePassword() {
		t.Error("CanStorePassword = false com cifra configurada")
	}
}
