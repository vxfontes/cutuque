package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/machine"
)

// fakeTargets grava o que o cadastro pediu ao Launcher, na ordem. É o único
// jeito de ver a diferença entre "a máquina está na lista" e "dá para lançar
// sessão nela" sem subir um Launcher de verdade.
type fakeTargets struct {
	registradas    []machine.Machine
	desregistradas []string
}

func (f *fakeTargets) RegisterMachine(m machine.Machine) {
	f.registradas = append(f.registradas, m)
}

func (f *fakeTargets) UnregisterMachine(name string) {
	f.desregistradas = append(f.desregistradas, name)
}

// doAlvos, como doAdmin, liga idents ao registro antes de servir a
// requisição — a mesma relação que main.go monta em produção entre
// machine.NewRegistryAt e WithIdentities.
func doAlvos(t *testing.T, mreg *machine.Registry, keys MachineKeys, idents *machine.IdentityStore, tg MachineTargets, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	if idents != nil {
		mreg.UseIdentities(idents)
	}
	cfg, reg := testDeps()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil, WithMachines(mreg), WithMachineKeys(keys), WithIdentities(idents), WithMachineTargets(tg)).ServeHTTP(rec, req)
	return rec
}

// O cadastro nasce sem impressão confirmada. Virar alvo aí seria prometer uma
// conexão que o hub vai recusar — a máquina precisa passar pelo /trust antes.
func TestPostMachinesNaoCriaAlvoAntesDoTrust(t *testing.T) {
	mreg := machine.NewRegistry(nil)
	idents := identidadeComChave(t, "vx", "vx")
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}
	tg := &fakeTargets{}

	rec := doAlvos(t, mreg, keys, idents, tg, http.MethodPost, "/machines",
		`{"name":"vps","host":"192.0.2.50","port":2222,"identity":"vx"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if len(tg.registradas) != 0 {
		t.Errorf("a máquina virou alvo antes de a impressão ser confirmada: %v", tg.registradas)
	}
}

// Confirmar a impressão é o que torna a máquina utilizável: sem este registro o
// cadastro inteiro só produziria um nome numa lista.
func TestPostTrustFazAMaquinaVirarAlvo(t *testing.T) {
	mreg, idents := registroComVPS(t)
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}
	tg := &fakeTargets{}

	rec := doAlvos(t, mreg, keys, idents, tg, http.MethodPost, "/machines/vps/trust",
		`{"fingerprint":"SHA256:doHost"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if len(tg.registradas) != 1 || tg.registradas[0].Name != "vps" {
		t.Fatalf("alvos registrados = %v, esperava só a vps", tg.registradas)
	}
	// O alvo precisa nascer com a chave e a porta do cadastro: é com elas que o
	// ssh vai conectar.
	got := tg.registradas[0]
	if got.HostFingerprint != "SHA256:doHost" || got.Port != 2222 {
		t.Errorf("alvo registrado com dados errados: %+v", got)
	}
}

// Impressão que não bate não confia em nada — e não pode criar alvo nenhum.
func TestTrustRecusadoNaoCriaAlvo(t *testing.T) {
	mreg, idents := registroComVPS(t)
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:outroHost"}
	tg := &fakeTargets{}

	rec := doAlvos(t, mreg, keys, idents, tg, http.MethodPost, "/machines/vps/trust",
		`{"fingerprint":"SHA256:doHost"}`)
	if rec.Code != http.StatusConflict {
		t.Fatalf("status %d, esperava 409: %s", rec.Code, rec.Body.String())
	}
	if len(tg.registradas) != 0 {
		t.Errorf("host divergente virou alvo mesmo assim: %v", tg.registradas)
	}
}

// Apontar a máquina para outro endereço derruba a confirmação. O alvo tem que
// cair junto: continuar conectando no lugar antigo seria pior que falhar.
func TestPatchQueMudaOHostTiraOAlvo(t *testing.T) {
	mreg, idents := registroComVPS(t)
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}
	tg := &fakeTargets{}
	doAlvos(t, mreg, keys, idents, tg, http.MethodPost, "/machines/vps/trust", `{"fingerprint":"SHA256:doHost"}`)

	rec := doAlvos(t, mreg, keys, idents, tg, http.MethodPatch, "/machines/vps",
		`{"host":"198.51.100.9","port":2222}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if len(tg.desregistradas) != 1 || tg.desregistradas[0] != "vps" {
		t.Errorf("o alvo do endereço antigo continuou de pé: %v", tg.desregistradas)
	}
}

// Editar só a porta mantendo o host preserva a confirmação — e o alvo tem
// que ser refeito com a porta nova, senão o ssh iria para a antiga.
func TestPatchQueMantemOHostRefazOAlvo(t *testing.T) {
	mreg, idents := registroComVPS(t)
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}
	tg := &fakeTargets{}
	doAlvos(t, mreg, keys, idents, tg, http.MethodPost, "/machines/vps/trust", `{"fingerprint":"SHA256:doHost"}`)

	rec := doAlvos(t, mreg, keys, idents, tg, http.MethodPatch, "/machines/vps",
		`{"host":"192.0.2.50","port":2222}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if len(tg.registradas) != 2 {
		t.Fatalf("o alvo não foi refeito depois do patch: %v", tg.registradas)
	}
	if len(tg.desregistradas) != 0 {
		t.Errorf("patch sem mudar o host não devia derrubar o alvo: %v", tg.desregistradas)
	}
}

// Trocar só a identidade (host e porta iguais) preserva a confirmação, exatamente
// como preservá-la é o que se espera de um patch que não muda o host: nenhum
// alvo deveria cair.
func TestPatchQueTrocaSoAIdentidadeNaoTiraOAlvo(t *testing.T) {
	mreg, idents := registroComVPS(t)
	if _, err := idents.Add(machine.Identity{Name: "outra", Username: "deploy"}, ""); err != nil {
		t.Fatalf("Add: %v", err)
	}
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}
	tg := &fakeTargets{}
	doAlvos(t, mreg, keys, idents, tg, http.MethodPost, "/machines/vps/trust", `{"fingerprint":"SHA256:doHost"}`)

	rec := doAlvos(t, mreg, keys, idents, tg, http.MethodPatch, "/machines/vps", `{"identity":"outra"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if len(tg.desregistradas) != 0 {
		t.Errorf("trocar de identidade não devia derrubar o alvo: %v", tg.desregistradas)
	}
}

func TestDeleteTiraOAlvo(t *testing.T) {
	mreg, idents := registroComVPS(t)
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}
	tg := &fakeTargets{}
	doAlvos(t, mreg, keys, idents, tg, http.MethodPost, "/machines/vps/trust", `{"fingerprint":"SHA256:doHost"}`)

	rec := doAlvos(t, mreg, keys, idents, tg, http.MethodDelete, "/machines/vps", "")
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if len(tg.desregistradas) != 1 || tg.desregistradas[0] != "vps" {
		t.Errorf("a máquina apagada continuou como alvo: %v", tg.desregistradas)
	}
}

// Sem CUTUQUE_MACHINES_DIR o Launcher não é ligado ao cadastro. As rotas não
// podem cair por isso: o hub tem que seguir servindo as máquinas do hub.env.
func TestCadastroSemLauncherNaoQuebra(t *testing.T) {
	mreg, idents := registroComVPS(t)
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}

	for _, c := range []struct {
		method, path, body string
		quero              int
	}{
		{http.MethodPost, "/machines/vps/trust", `{"fingerprint":"SHA256:doHost"}`, http.StatusOK},
		{http.MethodPatch, "/machines/vps", `{"host":"192.0.2.50","port":22}`, http.StatusOK},
		{http.MethodDelete, "/machines/vps", "", http.StatusNoContent},
	} {
		rec := doAlvos(t, mreg, keys, idents, nil, c.method, c.path, c.body)
		if rec.Code != c.quero {
			t.Errorf("%s %s: status %d, esperava %d — %s", c.method, c.path, rec.Code, c.quero, rec.Body.String())
		}
	}
}

// --- GET /machines/{n}/scan ---

// Fechar o app no meio do cadastro não pode deixar a máquina encalhada: o scan
// relê a impressão para a usuária poder confirmar depois.
func TestGetScanReleAImpressaoDoHost(t *testing.T) {
	mreg, idents := registroComVPS(t)
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}

	rec := doAdmin(t, mreg, keys, idents, http.MethodGet, "/machines/vps/scan", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	var body struct {
		Fingerprint string `json:"fingerprint"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("corpo não é json: %v — %s", err, rec.Body.String())
	}
	if body.Fingerprint != "SHA256:doHost" {
		t.Errorf("fingerprint = %q, quero SHA256:doHost", body.Fingerprint)
	}
}

// O scan não confia em nada: relê e devolve, só isso. Confiar segue sendo do
// /trust, que escaneia de novo por conta própria.
func TestGetScanNaoConfiaNemCriaAlvo(t *testing.T) {
	mreg, idents := registroComVPS(t)
	keys := newFakeKeys()
	keys.scanFPs = []string{"SHA256:doHost"}
	tg := &fakeTargets{}

	doAlvos(t, mreg, keys, idents, tg, http.MethodGet, "/machines/vps/scan", "")

	m, _ := mreg.Get("vps")
	if m.HostFingerprint != "" {
		t.Errorf("o scan gravou a impressão sozinho: %q", m.HostFingerprint)
	}
	if len(tg.registradas) != 0 {
		t.Errorf("o scan criou alvo sem confirmação: %v", tg.registradas)
	}
	if len(keys.trusted) != 0 {
		t.Errorf("o scan gravou no known_hosts: %v", keys.trusted)
	}
}

func TestGetScanDeMaquinaDoEnvE403(t *testing.T) {
	mreg := machine.NewRegistry([]machine.Machine{
		{Name: "macmini", Dest: "macmini", Port: 22, Source: machine.SourceEnv},
	})
	idents := identidadeComChave(t, "vx", "vx")
	rec := doAdmin(t, mreg, newFakeKeys(), idents, http.MethodGet, "/machines/macmini/scan", "")
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status %d, esperava 403: %s", rec.Code, rec.Body.String())
	}
}
