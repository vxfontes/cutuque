package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/machine"
)

// doMachines monta um router com o registro de máquinas ligado e faz a chamada
// autenticada. Espelha o do() do launch_test.go, que não aceita RouterOption.
func doMachines(t *testing.T, mreg *machine.Registry, method, path string) *httptest.ResponseRecorder {
	t.Helper()
	cfg, reg := testDeps()
	req := httptest.NewRequest(method, path, nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil, WithMachines(mreg)).ServeHTTP(rec, req)
	return rec
}

func TestGetMachinesListaOQueOEnvDeu(t *testing.T) {
	reg := machine.NewRegistry([]machine.Machine{
		{Name: "macbook", Dest: "vx@192.0.2.20", Port: 22, Source: machine.SourceEnv},
		{Name: "windows", Dest: "vx@192.0.2.30", Port: 22, Source: machine.SourceEnv},
	})
	rec := doMachines(t, reg, http.MethodGet, "/machines")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Machines []machine.Machine `json:"machines"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v — corpo: %s", err, rec.Body.String())
	}
	if len(got.Machines) != 2 {
		t.Fatalf("esperava 2 máquinas, veio %d", len(got.Machines))
	}
	if got.Machines[0].Name != "macbook" || got.Machines[0].Source != machine.SourceEnv {
		t.Errorf("primeira máquina errada: %+v", got.Machines[0])
	}
}

// Registro vazio devolve lista vazia, não null — o app decodifica [Machine] e
// null quebraria o decode.
func TestGetMachinesVazioDevolveListaVaziaNaoNull(t *testing.T) {
	rec := doMachines(t, machine.NewRegistry(nil), http.MethodGet, "/machines")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200", rec.Code)
	}
	var got struct {
		Machines []machine.Machine `json:"machines"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v", err)
	}
	if got.Machines == nil {
		t.Error("machines veio null; deve ser []")
	}
}

// O RemoteCmd é detalhe interno do hub (caminho do binário do agente na
// máquina). Não pode vazar para o app.
func TestGetMachinesNaoVazaRemoteCmd(t *testing.T) {
	reg := machine.NewRegistry([]machine.Machine{
		{Name: "macbook", Dest: "vx@host", Port: 22, Source: machine.SourceEnv, RemoteCmd: "/Users/vx/.local/bin/claude"},
	})
	rec := doMachines(t, reg, http.MethodGet, "/machines")
	if body := rec.Body.String(); strings.Contains(body, ".local/bin/claude") {
		t.Errorf("RemoteCmd vazou na resposta: %s", body)
	}
}
