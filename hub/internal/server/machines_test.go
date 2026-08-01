package server

import (
	"bytes"
	"encoding/json"
	"errors"
	"mime"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/launcher"
	"github.com/vxfontes/cutuque/hub/internal/machine"
	"github.com/vxfontes/cutuque/hub/internal/session"
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

func TestGetFsListaPastasEArquivos(t *testing.T) {
	f := &fakeLauncher{fileListing: session.FileListing{
		Path:   "/Users/vx",
		Parent: "/Users",
		Entries: []session.FileEntry{
			{Name: "docs", Path: "/Users/vx/docs", IsDir: true, ModTime: 1700000000},
			{Name: "notas.md", Path: "/Users/vx/notas.md", Size: 42, ModTime: 1700000100},
		},
	}}

	rec := do(t, f, http.MethodGet, "/machines/macbook/fs?path=/Users/vx", "")

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	if f.gotFsMachine != "macbook" || f.gotFsPath != "/Users/vx" {
		t.Errorf("machine/path repassados errados: %q %q", f.gotFsMachine, f.gotFsPath)
	}
	var got session.FileListing
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v — corpo: %s", err, rec.Body.String())
	}
	if got.Parent != "/Users" || len(got.Entries) != 2 {
		t.Fatalf("listagem errada: %+v", got)
	}
	if !got.Entries[0].IsDir || got.Entries[1].Size != 42 {
		t.Errorf("entradas erradas: %+v", got.Entries)
	}
}

func TestGetFsMaquinaDesconhecidaDa404(t *testing.T) {
	f := &fakeLauncher{fsErr: launcher.ErrUnknownMachine}
	rec := do(t, f, http.MethodGet, "/machines/naoexiste/fs", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404", rec.Code)
	}
	// O 404 tem que vir do handler, não do mux: sem esta checagem o teste
	// passa mesmo com a rota inexistente.
	if !strings.Contains(rec.Body.String(), "unknown_machine") {
		t.Errorf("esperava erro unknown_machine, veio: %s", rec.Body.String())
	}
}

// Falha na máquina (ssh caiu, python3 ausente) é problema do outro lado: 502,
// não 500 — o hub está bem, o gateway é que falhou.
func TestGetFsFalhaRemotaDa502(t *testing.T) {
	f := &fakeLauncher{fsErr: errors.New("ssh: connect timeout")}
	rec := do(t, f, http.MethodGet, "/machines/macbook/fs", "")
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status %d, esperava 502", rec.Code)
	}
}

func TestGetFsReadDevolveConteudo(t *testing.T) {
	f := &fakeLauncher{fileContent: session.FileContent{
		Path: "/Users/vx/notas.md", Size: 12, Content: "# olá\nmundo\n",
	}}

	rec := do(t, f, http.MethodGet, "/machines/macbook/fs/read?path=/Users/vx/notas.md", "")

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	if f.gotReadMachine != "macbook" || f.gotReadPath != "/Users/vx/notas.md" {
		t.Errorf("machine/path repassados errados: %q %q", f.gotReadMachine, f.gotReadPath)
	}
	var got session.FileContent
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v", err)
	}
	if got.Content != "# olá\nmundo\n" {
		t.Errorf("conteúdo errado: %q", got.Content)
	}
}

// Ler exige caminho: sem ele não há default sensato (o "home" da listagem não
// se traduz em arquivo). 400 antes de tocar a máquina.
func TestGetFsReadSemCaminhoDa400(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodGet, "/machines/macbook/fs/read", "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400", rec.Code)
	}
	if f.gotReadPath != "" || f.gotReadMachine != "" {
		t.Errorf("não devia ter chamado o launcher: %q %q", f.gotReadMachine, f.gotReadPath)
	}
}

func TestGetFsReadMaquinaDesconhecidaDa404(t *testing.T) {
	f := &fakeLauncher{readErr: launcher.ErrUnknownMachine}
	rec := do(t, f, http.MethodGet, "/machines/naoexiste/fs/read?path=/a.txt", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "unknown_machine") {
		t.Errorf("esperava erro unknown_machine, veio: %s", rec.Body.String())
	}
}

// MARK: escrita

func TestPutFsWriteSalvaEDevolveOTamanhoNovo(t *testing.T) {
	f := &fakeLauncher{fileWrite: session.FileWrite{Path: "/Users/vx/notas.md", Size: 12}}

	rec := do(t, f, http.MethodPut, "/machines/macbook/fs/write",
		`{"path":"/Users/vx/notas.md","content":"# olá\nmundo\n"}`)

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	if f.gotWriteMachine != "macbook" || f.gotWritePath != "/Users/vx/notas.md" {
		t.Errorf("machine/path repassados errados: %q %q", f.gotWriteMachine, f.gotWritePath)
	}
	if string(f.gotWriteContent) != "# olá\nmundo\n" {
		t.Errorf("conteúdo repassado errado: %q", f.gotWriteContent)
	}
	var got session.FileWrite
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v", err)
	}
	if got.Size != 12 {
		t.Errorf("tamanho novo errado: %+v", got)
	}
}

// Salvar arquivo vazio é legítimo (a usuária apagou tudo). Não pode virar 400.
func TestPutFsWriteAceitaConteudoVazio(t *testing.T) {
	f := &fakeLauncher{fileWrite: session.FileWrite{Path: "/a.txt", Size: 0}}
	rec := do(t, f, http.MethodPut, "/machines/macbook/fs/write", `{"path":"/a.txt","content":""}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	if f.gotWritePath != "/a.txt" {
		t.Errorf("não chamou o launcher: %q", f.gotWritePath)
	}
}

func TestPutFsWriteSemCaminhoDa400(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodPut, "/machines/macbook/fs/write", `{"path":"","content":"x"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400", rec.Code)
	}
	if f.gotWritePath != "" {
		t.Errorf("não devia ter chamado o launcher: %q", f.gotWritePath)
	}
}

// Caminho que não é arquivo existente é 404, não 502: a escrita SÓ sobrescreve
// o que a usuária abriu (regra de segurança do spec), e o app precisa
// distinguir "sumiu" de "a máquina caiu".
func TestPutFsWriteCaminhoInexistenteDa404(t *testing.T) {
	f := &fakeLauncher{writeErr: claudecode.ErrNotAFile}
	rec := do(t, f, http.MethodPut, "/machines/macbook/fs/write", `{"path":"/sumiu.txt","content":"x"}`)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404: %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "not_a_file") {
		t.Errorf("esperava erro not_a_file, veio: %s", rec.Body.String())
	}
}

func TestPutFsWriteMaquinaDesconhecidaDa404(t *testing.T) {
	f := &fakeLauncher{writeErr: launcher.ErrUnknownMachine}
	rec := do(t, f, http.MethodPut, "/machines/naoexiste/fs/write", `{"path":"/a.txt","content":"x"}`)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "unknown_machine") {
		t.Errorf("esperava erro unknown_machine, veio: %s", rec.Body.String())
	}
}

func TestPutFsWriteFalhaRemotaDa502(t *testing.T) {
	f := &fakeLauncher{writeErr: errors.New("ssh: connect timeout")}
	rec := do(t, f, http.MethodPut, "/machines/macbook/fs/write", `{"path":"/a.txt","content":"x"}`)
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status %d, esperava 502", rec.Code)
	}
}

// MARK: download

func TestGetFsDownloadDevolveOsBytesCrus(t *testing.T) {
	f := &fakeLauncher{fileBytes: []byte{0x89, 'P', 'N', 'G', 0x00, 0x01}}

	rec := do(t, f, http.MethodGet, "/machines/macbook/fs/download?path=/Users/vx/foto.png", "")

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	if f.gotDownloadMachine != "macbook" || f.gotDownloadPath != "/Users/vx/foto.png" {
		t.Errorf("machine/path repassados errados: %q %q", f.gotDownloadMachine, f.gotDownloadPath)
	}
	if !bytes.Equal(rec.Body.Bytes(), f.fileBytes) {
		t.Errorf("bytes errados: %v", rec.Body.Bytes())
	}
	// Sem o attachment o iOS tenta renderizar em vez de salvar, e o nome do
	// arquivo vira o último segmento da rota ("download"). As aspas em volta do
	// nome são opcionais (o mime só as põe quando precisa), então checamos o
	// header parseado, não o texto cru.
	cd := rec.Header().Get("Content-Disposition")
	kind, params, err := mime.ParseMediaType(cd)
	if err != nil {
		t.Fatalf("Content-Disposition inválido %q: %v", cd, err)
	}
	if kind != "attachment" || params["filename"] != "foto.png" {
		t.Errorf("Content-Disposition errado: %q", cd)
	}
}

// O nome do arquivo vai num header; aspas e newline nele quebrariam o header
// (ou permitiriam injetar outro). Tem que ser escapado/sanitizado.
func TestGetFsDownloadNaoDeixaInjetarHeader(t *testing.T) {
	f := &fakeLauncher{fileBytes: []byte("x")}
	rec := do(t, f, http.MethodGet, `/machines/macbook/fs/download?path=/tmp/a%22%0d%0aX-Evil:%201.txt`, "")
	cd := rec.Header().Get("Content-Disposition")
	if strings.Contains(cd, "\n") || strings.Contains(cd, "\r") {
		t.Errorf("newline sobreviveu no header: %q", cd)
	}
	if rec.Header().Get("X-Evil") != "" {
		t.Error("deu para injetar um header pelo nome do arquivo")
	}
}

func TestGetFsDownloadSemCaminhoDa400(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodGet, "/machines/macbook/fs/download", "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400", rec.Code)
	}
	if f.gotDownloadPath != "" {
		t.Errorf("não devia ter chamado o launcher: %q", f.gotDownloadPath)
	}
}

func TestGetFsDownloadMaquinaDesconhecidaDa404(t *testing.T) {
	f := &fakeLauncher{downloadErr: launcher.ErrUnknownMachine}
	rec := do(t, f, http.MethodGet, "/machines/naoexiste/fs/download?path=/a.txt", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "unknown_machine") {
		t.Errorf("esperava erro unknown_machine, veio: %s", rec.Body.String())
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
