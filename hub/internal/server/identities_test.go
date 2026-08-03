package server

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/machine"
)

// Estes testes cobrem as rotas /identities descritas em identities.go: o que
// mais importa aqui é o invariante nº 4 do redesenho — nenhuma rota devolve
// senha — e o rollback de POST quando o keygen falha, que é fácil de quebrar
// num refactor futuro.
//
// Reaproveita fakeKeys/newFakeKeys/testDeps/erroDe/jsonStr de
// machines_admin_test.go e health_test.go (mesmo pacote, mesmo padrão de
// montagem do Router que os outros testes de cadastro já usam).

// chaveIdentTeste devolve uma chave de cifra válida (32 bytes) em base64,
// determinística e só para teste — não protege nada de verdade.
func chaveIdentTeste(b byte) string {
	return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{b}, 32))
}

// doIdentities monta o Router com máquinas + cofre de chaves + identidades
// ligados — as três dependências que identities.go exige para registrar rota
// (ver server.go: o bloco de /identities só nasce dentro de rc.machines != nil
// E rc.machineKeys != nil && rc.identities != nil).
func doIdentities(t *testing.T, mreg *machine.Registry, keys MachineKeys, idents Identities, method, path, body string, auth bool) *httptest.ResponseRecorder {
	t.Helper()
	cfg, reg := testDeps()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if auth {
		req.Header.Set("Authorization", "Bearer secret")
	}
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil, WithMachines(mreg), WithMachineKeys(keys), WithIdentities(idents)).ServeHTTP(rec, req)
	return rec
}

// MARK: GET /identities

func TestGetIdentitiesListaEDizSeGuardaSenha(t *testing.T) {
	idents, err := machine.NewIdentityStoreAt("", chaveIdentTeste(0x30))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt: %v", err)
	}
	if _, err := idents.Add(machine.Identity{Name: "vanessa", Username: "vx"}, "senha-de-vanessa"); err != nil {
		t.Fatalf("Add: %v", err)
	}
	if _, err := idents.Add(machine.Identity{Name: "ci", Username: "deploy"}, ""); err != nil {
		t.Fatalf("Add: %v", err)
	}

	rec := doIdentities(t, machine.NewRegistry(nil), newFakeKeys(), idents, http.MethodGet, "/identities", "", true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	var got identityListResp
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v — %s", err, rec.Body.String())
	}
	if !got.CanStorePassword {
		t.Error("can_store_password = false, mas o store tem cifra")
	}
	if len(got.Identities) != 2 {
		t.Fatalf("esperava 2 identidades, veio %d", len(got.Identities))
	}
	if got.Identities[0].Name != "vanessa" || !got.Identities[0].HasPassword {
		t.Errorf("primeira identidade errada: %+v", got.Identities[0])
	}
	if got.Identities[1].Name != "ci" || got.Identities[1].HasPassword {
		t.Errorf("segunda identidade errada: %+v", got.Identities[1])
	}
}

func TestGetIdentitiesCanStorePasswordFalseSemCifra(t *testing.T) {
	idents := machine.NewIdentityStore() // sem cifra
	rec := doIdentities(t, machine.NewRegistry(nil), newFakeKeys(), idents, http.MethodGet, "/identities", "", true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200", rec.Code)
	}
	var got identityListResp
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v", err)
	}
	if got.CanStorePassword {
		t.Error("can_store_password = true sem cifra configurada")
	}
}

// Lista vazia sai como "[]", nunca "null" — o app decodifica array direto.
func TestGetIdentitiesVazioDevolveListaVaziaNaoNull(t *testing.T) {
	idents := machine.NewIdentityStore()
	rec := doIdentities(t, machine.NewRegistry(nil), newFakeKeys(), idents, http.MethodGet, "/identities", "", true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200", rec.Code)
	}
	if strings.Contains(rec.Body.String(), `"identities":null`) {
		t.Errorf("identities veio null: %s", rec.Body.String())
	}
	var got identityListResp
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v", err)
	}
	if got.Identities == nil {
		t.Error("identities veio nil depois do unmarshal; deveria ser slice vazia")
	}
}

// O guarda do invariante nº 4: NENHUMA rota devolve senha. Aqui é a mais óbvia
// candidata a vazar — a lista de identidades — e a senha usada no teste não
// pode aparecer em lugar nenhum do corpo cru da resposta.
func TestGetIdentitiesNaoVazaASenha(t *testing.T) {
	const senha = "senha-que-jamais-pode-aparecer-na-resposta-9f8e"
	idents, err := machine.NewIdentityStoreAt("", chaveIdentTeste(0x31))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt: %v", err)
	}
	if _, err := idents.Add(machine.Identity{Name: "vanessa", Username: "vx"}, senha); err != nil {
		t.Fatalf("Add: %v", err)
	}

	rec := doIdentities(t, machine.NewRegistry(nil), newFakeKeys(), idents, http.MethodGet, "/identities", "", true)
	corpo := rec.Body.String()
	if strings.Contains(corpo, senha) {
		t.Fatalf("a senha apareceu na resposta de GET /identities: %s", corpo)
	}
	// Nem o ciphertext (base64) nem qualquer chave "secret"/"password" no JSON.
	for _, proibido := range []string{"secret", `"password"`} {
		if strings.Contains(corpo, proibido) {
			t.Errorf("a resposta contém %q, que não deveria estar em identityListResp: %s", proibido, corpo)
		}
	}
}

// MARK: POST /identities

func TestPostIdentitiesCriaEGeraChaveComONomeDaIdentidade(t *testing.T) {
	idents := machine.NewIdentityStore()
	keys := newFakeKeys()

	rec := doIdentities(t, machine.NewRegistry(nil), keys, idents, http.MethodPost, "/identities",
		`{"name":"vanessa","username":"vx"}`, true)
	if rec.Code != http.StatusCreated {
		t.Fatalf("status %d, esperava 201: %s", rec.Code, rec.Body.String())
	}
	var got identityResp
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v — %s", err, rec.Body.String())
	}
	if got.Identity.Name != "vanessa" || got.Identity.Username != "vx" {
		t.Errorf("identidade errada: %+v", got.Identity)
	}
	if got.PublicKey != keys.pub {
		t.Errorf("public_key = %q, esperava %q", got.PublicKey, keys.pub)
	}
	if len(keys.generated) != 1 || keys.generated[0] != "vanessa" {
		t.Errorf("a chave não foi gerada com o nome da identidade: %v", keys.generated)
	}
}

func TestPostIdentitiesDuplicadoE409(t *testing.T) {
	idents := machine.NewIdentityStore()
	keys := newFakeKeys()
	if _, err := idents.Add(machine.Identity{Name: "vanessa", Username: "vx"}, ""); err != nil {
		t.Fatalf("Add: %v", err)
	}
	rec := doIdentities(t, machine.NewRegistry(nil), keys, idents, http.MethodPost, "/identities",
		`{"name":"vanessa","username":"outro"}`, true)
	if rec.Code != http.StatusConflict {
		t.Fatalf("status %d, esperava 409: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "duplicate_identity" {
		t.Errorf("erro = %q", got)
	}
	if len(keys.generated) != 0 {
		t.Errorf("gerou chave para um nome recusado: %v", keys.generated)
	}
}

func TestPostIdentitiesNomeOuUsuarioInvalidoE400(t *testing.T) {
	casos := []struct{ nome, usuario string }{
		{"../fuga", "vx"},
		{"vanessa", "usuario com espaço"},
		{"vanessa", "-comeca-com-traco"},
		{"", "vx"},
	}
	for _, c := range casos {
		idents := machine.NewIdentityStore()
		keys := newFakeKeys()
		body := `{"name":` + jsonStr(c.nome) + `,"username":` + jsonStr(c.usuario) + `}`
		rec := doIdentities(t, machine.NewRegistry(nil), keys, idents, http.MethodPost, "/identities", body, true)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("nome=%q usuario=%q: status %d, esperava 400: %s", c.nome, c.usuario, rec.Code, rec.Body.String())
			continue
		}
		if got := erroDe(t, rec); got != "invalid_identity" {
			t.Errorf("nome=%q usuario=%q: erro = %q", c.nome, c.usuario, got)
		}
		if len(keys.generated) != 0 {
			t.Errorf("nome=%q usuario=%q: gerou chave mesmo assim", c.nome, c.usuario)
		}
	}
}

func TestPostIdentitiesComSenhaSemCifraE400(t *testing.T) {
	idents := machine.NewIdentityStore() // sem cifra
	keys := newFakeKeys()
	rec := doIdentities(t, machine.NewRegistry(nil), keys, idents, http.MethodPost, "/identities",
		`{"name":"vanessa","username":"vx","password":"qualquer"}`, true)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "cannot_store_password" {
		t.Errorf("erro = %q", got)
	}
	if len(keys.generated) != 0 {
		t.Errorf("gerou chave mesmo recusando a senha: %v", keys.generated)
	}
}

// Se o keygen falhar, a identidade tem que ser desfeita — melhor não existir
// do que existir pela metade (sem chave, inutilizável). Este rollback é fácil
// de quebrar num refactor que reordene os passos do handler.
func TestPostIdentitiesKeygenFalhaDesfazOCadastro(t *testing.T) {
	idents := machine.NewIdentityStore()
	keys := newFakeKeys()
	keys.genErr = errors.New("ssh-keygen sumiu")

	rec := doIdentities(t, machine.NewRegistry(nil), keys, idents, http.MethodPost, "/identities",
		`{"name":"vanessa","username":"vx"}`, true)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status %d, esperava 500: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "keygen_failed" {
		t.Errorf("erro = %q", got)
	}
	if _, ok := idents.Get("vanessa"); ok {
		t.Error("a identidade ficou criada pela metade depois do keygen falhar")
	}

	// E o GET subsequente não pode listar a identidade órfã.
	getRec := doIdentities(t, machine.NewRegistry(nil), keys, idents, http.MethodGet, "/identities", "", true)
	var got identityListResp
	if err := json.Unmarshal(getRec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v", err)
	}
	for _, id := range got.Identities {
		if id.Name == "vanessa" {
			t.Errorf("GET /identities listou a identidade que deveria ter sido desfeita: %+v", got.Identities)
		}
	}
}

// MARK: PATCH /identities/{identity}

func TestPatchIdentitySemCampoPasswordMantemASenha(t *testing.T) {
	idents, err := machine.NewIdentityStoreAt("", chaveIdentTeste(0x32))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt: %v", err)
	}
	if _, err := idents.Add(machine.Identity{Name: "vanessa", Username: "vx"}, "senha-original"); err != nil {
		t.Fatalf("Add: %v", err)
	}

	rec := doIdentities(t, machine.NewRegistry(nil), newFakeKeys(), idents, http.MethodPatch, "/identities/vanessa",
		`{"username":"outro-usuario"}`, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	senha, err := idents.Password("vanessa")
	if err != nil || senha != "senha-original" {
		t.Errorf("Password depois do PATCH sem campo password = %q, %v — esperava manter senha-original", senha, err)
	}
}

func TestPatchIdentityPasswordVazioApagaASenha(t *testing.T) {
	idents, err := machine.NewIdentityStoreAt("", chaveIdentTeste(0x33))
	if err != nil {
		t.Fatalf("NewIdentityStoreAt: %v", err)
	}
	if _, err := idents.Add(machine.Identity{Name: "vanessa", Username: "vx"}, "senha-original"); err != nil {
		t.Fatalf("Add: %v", err)
	}

	rec := doIdentities(t, machine.NewRegistry(nil), newFakeKeys(), idents, http.MethodPatch, "/identities/vanessa",
		`{"password":""}`, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	if _, err := idents.Password("vanessa"); !errors.Is(err, machine.ErrNoPassword) {
		t.Errorf("Password depois do PATCH {password:\"\"} = %v, esperava ErrNoPassword", err)
	}
}

func TestPatchIdentityInexistenteE404(t *testing.T) {
	idents := machine.NewIdentityStore()
	rec := doIdentities(t, machine.NewRegistry(nil), newFakeKeys(), idents, http.MethodPatch, "/identities/fantasma",
		`{"username":"x"}`, true)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "unknown_identity" {
		t.Errorf("erro = %q", got)
	}
}

// MARK: DELETE /identities/{identity}

func TestDeleteIdentityApagaEArquivaAChave(t *testing.T) {
	idents := machine.NewIdentityStore()
	keys := newFakeKeys()
	if _, err := idents.Add(machine.Identity{Name: "vanessa", Username: "vx"}, ""); err != nil {
		t.Fatalf("Add: %v", err)
	}

	rec := doIdentities(t, machine.NewRegistry(nil), keys, idents, http.MethodDelete, "/identities/vanessa", "", true)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status %d, esperava 204: %s", rec.Code, rec.Body.String())
	}
	if _, ok := idents.Get("vanessa"); ok {
		t.Error("a identidade continua no store depois do DELETE")
	}
	if len(keys.removed) != 1 || keys.removed[0] != "vanessa" {
		t.Errorf("a chave não foi removida: %v", keys.removed)
	}
}

// Identidade em uso por uma máquina não pode ser apagada: a máquina viraria um
// host sem conta nem chave. O "em uso" é decidido pelo Registry de máquinas
// (reg.UsesIdentity), passado como callback — exatamente o ponto que o
// callback existe para testar.
func TestDeleteIdentityEmUsoE409EContinuaLa(t *testing.T) {
	idents := machine.NewIdentityStore()
	keys := newFakeKeys()
	if _, err := idents.Add(machine.Identity{Name: "vanessa", Username: "vx"}, ""); err != nil {
		t.Fatalf("Add: %v", err)
	}
	mreg := machine.NewRegistry(nil)
	if _, err := mreg.Add(machine.Machine{Name: "vps", Host: "192.0.2.10", Identity: "vanessa"}); err != nil {
		t.Fatalf("mreg.Add: %v", err)
	}

	rec := doIdentities(t, mreg, keys, idents, http.MethodDelete, "/identities/vanessa", "", true)
	if rec.Code != http.StatusConflict {
		t.Fatalf("status %d, esperava 409: %s", rec.Code, rec.Body.String())
	}
	if got := erroDe(t, rec); got != "identity_in_use" {
		t.Errorf("erro = %q", got)
	}
	if _, ok := idents.Get("vanessa"); !ok {
		t.Error("a identidade sumiu mesmo com o DELETE recusado por estar em uso")
	}
	if len(keys.removed) != 0 {
		t.Errorf("a chave foi removida mesmo com o DELETE recusado: %v", keys.removed)
	}
}

func TestDeleteIdentityInexistenteE404(t *testing.T) {
	idents := machine.NewIdentityStore()
	rec := doIdentities(t, machine.NewRegistry(nil), newFakeKeys(), idents, http.MethodDelete, "/identities/fantasma", "", true)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404: %s", rec.Code, rec.Body.String())
	}
}

// MARK: token

// Cadastrar/alterar/apagar identidade não pode ficar acessível sem token — o
// mesmo cuidado das rotas de máquinas, porque a identidade nasce com uma chave
// instalável em host remoto.
func TestRotasDeIdentidadesExigemToken(t *testing.T) {
	casos := []struct{ method, path, body string }{
		{http.MethodGet, "/identities", ""},
		{http.MethodPost, "/identities", `{"name":"vanessa","username":"vx"}`},
		{http.MethodPatch, "/identities/vanessa", `{"username":"outro"}`},
		{http.MethodDelete, "/identities/vanessa", ""},
	}
	for _, c := range casos {
		idents := machine.NewIdentityStore()
		if _, err := idents.Add(machine.Identity{Name: "vanessa", Username: "vx"}, ""); err != nil {
			t.Fatalf("Add: %v", err)
		}
		keys := newFakeKeys()
		rec := doIdentities(t, machine.NewRegistry(nil), keys, idents, c.method, c.path, c.body, false)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s %s: status %d, esperava 401", c.method, c.path, rec.Code)
		}
		if len(keys.generated) != 0 || len(keys.removed) != 0 {
			t.Errorf("%s %s: agiu sem token", c.method, c.path)
		}
	}
}
