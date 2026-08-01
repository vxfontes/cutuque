# Aba Máquinas — F0 (registro + lista) e F1 (arquivos read-only) — plano

> **Para workers agênticos:** SUB-SKILL OBRIGATÓRIA: use superpowers:subagent-driven-development (recomendado) ou superpowers:executing-plans para implementar task a task. Os passos usam checkbox (`- [ ]`).

**Goal:** Entregar a aba Máquinas no app listando os hosts SSH que o hub conhece e permitindo navegar as pastas e arquivos deles, ver conteúdo de texto e baixar.

**Architecture:** O hub ganha `internal/machine` (registro em memória, alimentado pelo `CUTUQUE_SSH_TARGETS`) e três rotas REST novas — `GET /machines`, `GET /machines/{m}/fs`, `GET /machines/{m}/fs/read`. A leitura remota reusa o padrão já provado do `dirs.go`: script python3 pelo stdin do `ssh`, caminho como `argv[1]`, JSON de volta. O app ganha uma aba com lista de hosts, navegador de arquivos e visualizador de texto.

**Tech Stack:** Go 1.25 (stdlib + `net/http` mux com padrões de método), SwiftUI/iOS 17, XCTest.

## Global Constraints

- **Nenhuma dependência nova** neste plano — nem no `go.mod`, nem SPM no app. (SwiftTerm só entra na F4.)
- **Nenhum segredo trafega para o app.** Estas fases só leem; não há chave nem senha envolvida.
- **Caminho nunca interpolado em shell.** Sempre `agent.SingleQuote` + `argv[1]`, como em `dirs.go:70`.
- **Teto de leitura: 1 MB (1048576 bytes).** Arquivo maior não volta como texto.
- **pt-BR** em comentários, nomes de UI e mensagens de erro — é a convenção do repo.
- **Rotas novas atrás de `requireAuth(cfg.Token, …)`**, exceto `/health`.
- **`TerminalMirrorView` e o fluxo de sessões não são tocados** por nenhuma task deste plano.
- Branch: `aba-maquinas` (já criada, spec commitado em `0d3ee84`).

## Decisão de escopo que difere do spec

O spec descreve `internal/machine` com CRUD e persistência (Postgres + fallback JSON). **Este plano constrói só o registro em memória alimentado pelo env.** Persistência e CRUD nascem na F3, que é quando existe máquina cadastrada pelo app para persistir. Construir a tabela antes disso seria escrever código sem consumidor.

## Estrutura de arquivos

**Hub (Go)**

| Arquivo | Responsabilidade |
|---|---|
| `hub/internal/machine/machine.go` (novo) | Tipo `Machine`, `Registry` em memória, parse do `CUTUQUE_SSH_TARGETS` |
| `hub/internal/machine/machine_test.go` (novo) | Testes do parse e do registro |
| `hub/internal/server/machines.go` (novo) | `MachinesHandler`, `FilesHandler`, `FileReadHandler` |
| `hub/internal/server/machines_test.go` (novo) | Contrato REST das três rotas |
| `hub/internal/adapter/claudecode/files.go` (novo) | `filesScript`, `readScript`, `ListFiles`, `ReadFile` em Local/SSHTarget |
| `hub/internal/adapter/claudecode/files_test.go` (novo) | Parse do JSON e montagem dos args |
| `hub/internal/session/session.go` (modificar) | Tipos `FileEntry`, `FileListing`, `FileContent` |
| `hub/internal/launcher/launcher.go` (modificar) | `ListFiles`, `ReadFile` delegando ao target |
| `hub/internal/server/launch.go` (modificar) | Dois métodos novos na interface `Launcher` |
| `hub/internal/server/server.go` (modificar) | Registro das três rotas |
| `hub/cmd/hub/main.go` (modificar) | Passa a usar `machine.ParseSSHTargets`; injeta o registro no router |

**App (SwiftUI)**

| Arquivo | Responsabilidade |
|---|---|
| `app/CutuqueApp/MachineListView.swift` (novo) | Aba: lista de hosts |
| `app/CutuqueApp/FileBrowserView.swift` (novo) | Navegação de pastas + arquivos |
| `app/CutuqueApp/FileViewerView.swift` (novo) | Visualizar texto, baixar |
| `app/CutuqueApp/Models.swift` (modificar) | `Machine`, `FileEntry`, `FileListing`, `FileContent` |
| `app/CutuqueApp/APIClient.swift` (modificar) | `listMachines`, `listFiles`, `readFile` |
| `app/CutuqueApp/CutuqueApp.swift` (modificar) | Aba nova no `RootTabView` |
| `app/CutuqueAppTests/MachineFileTests.swift` (novo) | Decode dos modelos, formatação, detecção de binário |

---

## Task 1: Registro de máquinas no hub

**Files:**
- Create: `hub/internal/machine/machine.go`
- Create: `hub/internal/machine/machine_test.go`
- Modify: `hub/cmd/hub/main.go:346-380` (remove `parseSSHTargets`, passa a chamar o pacote)

**Interfaces:**
- Consumes: nada.
- Produces: `machine.Machine{Name, Dest, RemoteCmd, Source string; Port int}`, `machine.ParseSSHTargets(raw string) ([]Machine, []string)` (segundo retorno = avisos de entrada malformada), `machine.NewRegistry(ms []Machine) *Registry`, `(*Registry).List() []Machine`, `(*Registry).Get(name string) (Machine, bool)`.

- [ ] **Step 1: Escrever o teste que falha**

Criar `hub/internal/machine/machine_test.go`:

```go
package machine

import "testing"

func TestParseSSHTargetsLeNomeEDestino(t *testing.T) {
	ms, warns := ParseSSHTargets("macbook=vx@192.0.2.20,macmini=remote-host")
	if len(warns) != 0 {
		t.Fatalf("avisos inesperados: %v", warns)
	}
	if len(ms) != 2 {
		t.Fatalf("esperava 2 máquinas, veio %d", len(ms))
	}
	if ms[0].Name != "macbook" || ms[0].Dest != "vx@192.0.2.20" {
		t.Errorf("primeira máquina errada: %+v", ms[0])
	}
	if ms[0].Source != SourceEnv {
		t.Errorf("máquina do env deve ter Source=env, veio %q", ms[0].Source)
	}
	if ms[0].Port != 22 {
		t.Errorf("porta default deve ser 22, veio %d", ms[0].Port)
	}
}

func TestParseSSHTargetsAceitaTerceiroCampoComoRemoteCmd(t *testing.T) {
	ms, _ := ParseSSHTargets("macbook=vx@192.0.2.20=/Users/vx/.local/bin/claude")
	if len(ms) != 1 {
		t.Fatalf("esperava 1 máquina, veio %d", len(ms))
	}
	if ms[0].RemoteCmd != "/Users/vx/.local/bin/claude" {
		t.Errorf("remoteCmd errado: %q", ms[0].RemoteCmd)
	}
}

// Uma entrada ruim não pode derrubar as boas — o hub precisa subir mesmo com
// CUTUQUE_SSH_TARGETS meio torto.
func TestParseSSHTargetsIgnoraEntradaMalformadaSemPerderAsBoas(t *testing.T) {
	ms, warns := ParseSSHTargets("bom=vx@host, ,semigual,=sem-nome,vazio=")
	if len(ms) != 1 || ms[0].Name != "bom" {
		t.Fatalf("esperava só a entrada boa, veio %+v", ms)
	}
	if len(warns) != 3 {
		t.Errorf("esperava 3 avisos (semigual, =sem-nome, vazio=), veio %d: %v", len(warns), warns)
	}
}

func TestParseSSHTargetsVazioNaoEhErro(t *testing.T) {
	ms, warns := ParseSSHTargets("   ")
	if len(ms) != 0 || len(warns) != 0 {
		t.Errorf("entrada vazia deve dar nada e nenhum aviso: %+v / %v", ms, warns)
	}
}

func TestRegistryGetEListPreservamAOrdemDoEnv(t *testing.T) {
	r := NewRegistry([]Machine{
		{Name: "zulu", Dest: "a@b", Source: SourceEnv, Port: 22},
		{Name: "alfa", Dest: "c@d", Source: SourceEnv, Port: 22},
	})
	list := r.List()
	if len(list) != 2 || list[0].Name != "zulu" || list[1].Name != "alfa" {
		t.Errorf("List deve preservar a ordem do env, veio %+v", list)
	}
	m, ok := r.Get("alfa")
	if !ok || m.Dest != "c@d" {
		t.Errorf("Get(alfa) errado: %+v ok=%v", m, ok)
	}
	if _, ok := r.Get("naoexiste"); ok {
		t.Error("Get de máquina inexistente deve devolver ok=false")
	}
}
```

- [ ] **Step 2: Rodar o teste e ver falhar**

Run: `cd hub && go test ./internal/machine/...`
Expected: FAIL — o pacote `machine` não existe (`no Go files` / `undefined: ParseSSHTargets`).

- [ ] **Step 3: Implementar**

Criar `hub/internal/machine/machine.go`:

```go
// Package machine mantém o registro das máquinas SSH que o hub conhece: as que
// vêm do CUTUQUE_SSH_TARGETS (Source=env, imutáveis pelo app) e, a partir da
// F3, as cadastradas pelo app (Source=app). Nesta fase o registro é só de
// leitura e vive em memória — persistência nasce quando houver o que persistir.
package machine

import (
	"fmt"
	"strings"
	"sync"
)

// Source diz de onde a máquina veio. Máquina de env não é editável pelo app:
// quem manda nela é o hub.env.
type Source string

const (
	SourceEnv Source = "env"
	SourceApp Source = "app"
)

// defaultSSHPort é a porta usada quando a entrada não especifica outra.
const defaultSSHPort = 22

// Machine é uma máquina alcançável por ssh.
type Machine struct {
	Name string `json:"name"`
	Dest string `json:"dest"` // alias do ~/.ssh/config ou user@host
	Port int    `json:"port"`
	// RemoteCmd é o caminho do agente remoto (3º campo do CUTUQUE_SSH_TARGETS).
	// Vazio = default. Não é exposto ao app; existe para o buildTargets.
	RemoteCmd string `json:"-"`
	Source    Source `json:"source"`
}

// ParseSSHTargets interpreta o CUTUQUE_SSH_TARGETS. Formato de cada entrada:
// "nome=destino" ou "nome=destino=comando-remoto", separadas por vírgula.
//
// Parse defensivo: entrada malformada vira aviso e é ignorada — uma entrada
// ruim não pode impedir as demais nem derrubar o boot do hub. Devolve as
// máquinas na ordem em que aparecem e a lista de avisos.
func ParseSSHTargets(raw string) ([]Machine, []string) {
	var out []Machine
	var warns []string
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	for _, entry := range strings.Split(raw, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		parts := strings.SplitN(entry, "=", 3)
		if len(parts) < 2 {
			warns = append(warns, fmt.Sprintf("entrada sem '=' ignorada: %q", entry))
			continue
		}
		name := strings.TrimSpace(parts[0])
		dest := strings.TrimSpace(parts[1])
		if name == "" || dest == "" {
			warns = append(warns, fmt.Sprintf("entrada com nome ou destino vazio ignorada: %q", entry))
			continue
		}
		m := Machine{Name: name, Dest: dest, Port: defaultSSHPort, Source: SourceEnv}
		if len(parts) == 3 {
			m.RemoteCmd = strings.TrimSpace(parts[2])
		}
		out = append(out, m)
	}
	return out, warns
}

// Registry guarda as máquinas conhecidas. Thread-safe: o hub lê daqui em
// handlers concorrentes.
type Registry struct {
	mu    sync.RWMutex
	order []string
	by    map[string]Machine
}

// NewRegistry cria o registro a partir da lista dada, preservando a ordem.
// Nome repetido: a primeira ocorrência vence.
func NewRegistry(ms []Machine) *Registry {
	r := &Registry{by: make(map[string]Machine, len(ms))}
	for _, m := range ms {
		if _, dup := r.by[m.Name]; dup {
			continue
		}
		r.by[m.Name] = m
		r.order = append(r.order, m.Name)
	}
	return r
}

// List devolve as máquinas na ordem de cadastro.
func (r *Registry) List() []Machine {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Machine, 0, len(r.order))
	for _, n := range r.order {
		out = append(out, r.by[n])
	}
	return out
}

// Get busca uma máquina pelo nome.
func (r *Registry) Get(name string) (Machine, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	m, ok := r.by[name]
	return m, ok
}
```

- [ ] **Step 4: Rodar o teste e ver passar**

Run: `cd hub && go test ./internal/machine/...`
Expected: PASS (5 testes).

- [ ] **Step 5: Fazer o `main.go` usar o pacote (DRY)**

Em `hub/cmd/hub/main.go`, apagar a função `parseSSHTargets` e o tipo `sshDest`, e trocar o corpo de `buildTargets` para consumir `machine.ParseSSHTargets`. O comportamento fica idêntico — inclusive o fallback do `macbook` local quando a lista é vazia:

```go
func buildTargets(rawSSHTargets string, logger *slog.Logger) map[string]map[string]claudecode.Target {
	machines, warns := machine.ParseSSHTargets(rawSSHTargets)
	for _, w := range warns {
		logger.Warn("CUTUQUE_SSH_TARGETS", "aviso", w)
	}
	if len(machines) == 0 {
		return map[string]map[string]claudecode.Target{
			"macbook": agentMap(
				claudecode.NewLocalTarget("macbook"),
				codex.NewLocalTarget("macbook"),
				opencode.NewLocalTarget("macbook"),
			),
		}
	}
	targets := make(map[string]map[string]claudecode.Target, len(machines))
	for _, m := range machines {
		ct := claudecode.NewSSHTarget(m.Name, m.Dest)
		ct.SetRemoteClaudeCmd(m.RemoteCmd)
		targets[m.Name] = agentMap(ct, codex.NewSSHTarget(m.Name, m.Dest), opencode.NewSSHTarget(m.Name, m.Dest))
	}
	return targets
}
```

Adicionar o import `"github.com/vxfontes/cutuque/hub/internal/machine"`.

- [ ] **Step 6: Rodar a suíte inteira do hub**

Run: `cd hub && go build ./... && go test ./...`
Expected: PASS. Se algum teste de `main` referenciava `parseSSHTargets`, ele foi coberto pelos testes novos do pacote — apagar o teste antigo em vez de manter os dois.

- [ ] **Step 7: Commit**

```bash
git add hub/internal/machine hub/cmd/hub/main.go
git commit -m "hub: pacote machine com registro e parse do CUTUQUE_SSH_TARGETS

O parse morava no main.go e não tinha teste próprio. Vira pacote porque a
aba Máquinas precisa listar as máquinas como recurso, não só usar os nomes
para lançar sessão. Registro em memória: persistência nasce na F3, quando
houver máquina cadastrada pelo app para persistir."
```

---

## Task 2: Rota `GET /machines`

**Files:**
- Create: `hub/internal/server/machines.go`
- Create: `hub/internal/server/machines_test.go`
- Modify: `hub/internal/server/server.go` (option + rota), `hub/cmd/hub/main.go` (injetar o registro)

**Interfaces:**
- Consumes: `machine.Registry` da Task 1.
- Produces: `server.WithMachines(*machine.Registry) RouterOption`, rota `GET /machines` → `200 {"machines":[{name,dest,port,source}]}`.

- [ ] **Step 1: Escrever o teste que falha**

Criar `hub/internal/server/machines_test.go`:

```go
package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/machine"
)

// doMachines monta um router só com o registro de máquinas e faz a chamada.
func doMachines(t *testing.T, reg *machine.Registry, method, path string) *httptest.ResponseRecorder {
	t.Helper()
	h := NewRouter(Config{}, nil, WithMachines(reg))
	req := httptest.NewRequest(method, path, nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
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
```

Adicionar `"strings"` aos imports do arquivo de teste.

- [ ] **Step 2: Rodar o teste e ver falhar**

Run: `cd hub && go test ./internal/server/ -run TestGetMachines -v`
Expected: FAIL — `undefined: WithMachines`.

- [ ] **Step 3: Implementar o handler**

Criar `hub/internal/server/machines.go`:

```go
package server

import (
	"net/http"

	"github.com/vxfontes/cutuque/hub/internal/machine"
)

// (nas Tasks 6 e 7 este bloco ganha "errors" e o import do pacote launcher,
// quando os handlers de arquivos entrarem aqui.)

// MachinesHandler lista as máquinas que o hub conhece, como recurso rico (nome,
// destino, porta, origem) — diferente de GET /targets, que devolve só os nomes
// e continua servindo o fluxo de criar sessão.
//
//	GET /machines → 200 {"machines":[{name,dest,port,source}]}
func MachinesHandler(reg *machine.Registry) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		list := reg.List()
		if list == nil {
			list = []machine.Machine{}
		}
		writeJSONResp(w, http.StatusOK, map[string][]machine.Machine{"machines": list})
	}
}
```

`writeJSONResp` (`settings.go:114`) é o helper de sucesso do pacote; `writeJSONError` (`launch.go:439`) é o de erro. Usar os dois em vez de montar o encoder à mão.

- [ ] **Step 4: Ligar a option e a rota**

Em `hub/internal/server/server.go`, seguindo o padrão de `WithDevices` / `WithBoard`:

```go
// WithMachines habilita GET /machines, apoiada no registro dado. Sem esta
// opção a rota não existe (mesmo padrão de WithDevices/WithBoard).
func WithMachines(reg *machine.Registry) RouterOption {
	return func(rc *routerConfig) { rc.machines = reg }
}
```

Adicionar `machines *machine.Registry` ao `routerConfig`, o import do pacote, e registrar a rota junto das outras (perto da linha 110, onde `GET /targets` é registrada):

```go
	// Máquinas como recurso (aba Máquinas). Só quando há registro.
	if rc.machines != nil {
		mux.Handle("GET /machines", requireAuth(cfg.Token, MachinesHandler(rc.machines)))
	}
```

- [ ] **Step 5: Rodar os testes**

Run: `cd hub && go test ./internal/server/ -run TestGetMachines -v`
Expected: PASS (3 testes).

- [ ] **Step 6: Injetar o registro no main**

Em `hub/cmd/hub/main.go`, onde o router é construído, criar o registro a partir do mesmo parse que o `buildTargets` usa e passar `server.WithMachines(reg)` junto das outras options. Para não parsear duas vezes, extrair o resultado do parse para uma variável antes de chamar `buildTargets` e passar a lista adiante.

- [ ] **Step 7: Verificar ponta a ponta**

Run: `cd hub && go build ./... && go test ./...`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add hub/internal/server/machines.go hub/internal/server/machines_test.go hub/internal/server/server.go hub/cmd/hub/main.go
git commit -m "hub: GET /machines devolve as máquinas como recurso

/targets continua devolvendo só os nomes e servindo o fluxo de criar
sessão. /machines é o recurso rico da aba nova. RemoteCmd fica de fora do
JSON: é detalhe interno do hub, não interessa ao app."
```

---

## Task 3: Modelo e cliente de máquinas no app

**Files:**
- Modify: `app/CutuqueApp/Models.swift` (adicionar `Machine` perto do `DirListing`, ~linha 264)
- Modify: `app/CutuqueApp/APIClient.swift` (adicionar `listMachines` perto do `listDirs`, ~linha 412)
- Create: `app/CutuqueAppTests/MachineFileTests.swift`

**Interfaces:**
- Consumes: rota `GET /machines` da Task 2.
- Produces: `struct Machine: Decodable, Identifiable, Hashable { let name, dest, source: String; let port: Int }` com `var id: String { name }`; `APIClient.listMachines() async throws -> [Machine]`.

- [ ] **Step 1: Escrever o teste que falha**

Criar `app/CutuqueAppTests/MachineFileTests.swift`:

```swift
import XCTest
@testable import CutuqueApp

final class MachineFileTests: XCTestCase {

    func testDecodeDeMachine() throws {
        let json = Data("""
        {"name":"macbook","dest":"vx@192.0.2.20","port":22,"source":"env"}
        """.utf8)
        let m = try JSONDecoder.cutuque.decode(Machine.self, from: json)
        XCTAssertEqual(m.name, "macbook")
        XCTAssertEqual(m.dest, "vx@192.0.2.20")
        XCTAssertEqual(m.port, 22)
        XCTAssertEqual(m.source, "env")
        XCTAssertEqual(m.id, "macbook")
    }

    /// Máquina vinda do hub.env não pode ser editada nem removida pelo app —
    /// quem manda nela é o arquivo de configuração.
    func testMaquinaDeEnvNaoEhEditavel() throws {
        let env = Machine(name: "a", dest: "x@y", port: 22, source: "env")
        let app = Machine(name: "b", dest: "x@y", port: 22, source: "app")
        XCTAssertFalse(env.isEditable)
        XCTAssertTrue(app.isEditable)
    }
}
```

- [ ] **Step 2: Rodar o teste e ver falhar**

Run:
```bash
cd app && xcodebuild test -scheme CutuqueApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:CutuqueAppTests/MachineFileTests 2>&1 | tail -20
```
Expected: FAIL de compilação — `cannot find 'Machine' in scope`.

- [ ] **Step 3: Adicionar o modelo**

Em `app/CutuqueApp/Models.swift`, logo antes de `struct DirEntry`:

```swift
/// Uma máquina SSH que o hub conhece. `source` diz de onde ela veio: "env"
/// (CUTUQUE_SSH_TARGETS, mandada pelo hub.env) ou "app" (cadastrada pelo
/// iPhone). Máquina de env é só leitura aqui.
struct Machine: Decodable, Identifiable, Hashable {
    let name: String
    let dest: String
    let port: Int
    let source: String

    var id: String { name }
    /// Só máquina cadastrada pelo app pode ser editada ou removida por ele.
    var isEditable: Bool { source == "app" }
}
```

- [ ] **Step 4: Adicionar o cliente**

Em `app/CutuqueApp/APIClient.swift`, seguindo exatamente o formato de `listDirs`:

```swift
    private struct MachinesEnvelope: Decodable {
        let machines: [Machine]
    }

    /// Lista as máquinas que o hub conhece (aba Máquinas). `GET /machines`.
    func listMachines() async throws -> [Machine] {
        var request = URLRequest(url: baseURL.appendingPathComponent("machines"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200:
            return try JSONDecoder.cutuque.decode(MachinesEnvelope.self, from: data).machines
        case 502, 503:
            throw CutuqueError.server(status: http.statusCode, message: "o hub não respondeu (tente de novo)")
        default:
            throw CutuqueError.unexpected(status: http.statusCode)
        }
    }
```

- [ ] **Step 5: Rodar o teste e ver passar**

Run:
```bash
cd app && xcodebuild test -scheme CutuqueApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:CutuqueAppTests/MachineFileTests 2>&1 | tail -20
```
Expected: PASS (2 testes).

- [ ] **Step 6: Commit**

```bash
git add app/CutuqueApp/Models.swift app/CutuqueApp/APIClient.swift app/CutuqueAppTests/MachineFileTests.swift
git commit -m "app: modelo Machine e listMachines no APIClient"
```

---

## Task 4: Aba Máquinas com a lista de hosts

**Files:**
- Create: `app/CutuqueApp/MachineListView.swift`
- Modify: `app/CutuqueApp/CutuqueApp.swift:61-78` (`RootTabView`)

**Interfaces:**
- Consumes: `Machine` e `APIClient.listMachines()` da Task 3.
- Produces: `struct MachineListView: View` — a raiz da aba, com `NavigationStack` próprio.

- [ ] **Step 1: Criar a view**

Criar `app/CutuqueApp/MachineListView.swift`:

```swift
import SwiftUI

/// Aba Máquinas: lista os hosts SSH que o hub conhece. Tocar num host abre o
/// navegador de arquivos dele (o painel de terminal entra na F4).
///
/// A lista NÃO testa conexão de todas as máquinas ao abrir — seriam N
/// handshakes SSH por refresh. O alcance é descoberto quando se entra no host.
struct MachineListView: View {
    @State private var machines: [Machine] = []
    @State private var loading = false
    @State private var error: String?
    private let api = APIClient()

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    ContentUnavailableView {
                        Label("Não deu para listar", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Tentar de novo") { Task { await load() } }
                    }
                } else if machines.isEmpty && !loading {
                    ContentUnavailableView(
                        "Nenhuma máquina",
                        systemImage: "server.rack",
                        description: Text("Configure CUTUQUE_SSH_TARGETS no hub.env.")
                    )
                } else {
                    List(machines) { machine in
                        NavigationLink(value: machine) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(machine.name)
                                    .font(.body)
                                Text(machine.dest)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationDestination(for: Machine.self) { machine in
                        FileBrowserView(machine: machine.name, path: "")
                    }
                }
            }
            .navigationTitle("Máquinas")
            .refreshable { await load() }
            .overlay { if loading && machines.isEmpty { ProgressView() } }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            machines = try await api.listMachines()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Adicionar a aba**

Em `app/CutuqueApp/CutuqueApp.swift`, dentro do `TabView` do `RootTabView`, depois do `BoardView`:

```swift
            MachineListView()
                .tabItem { Label("Máquinas", systemImage: "server.rack") }
                .tag(2)
```

- [ ] **Step 3: Compilar**

Run:
```bash
cd app && xcodegen generate && xcodebuild build -scheme CutuqueApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -15
```
Expected: BUILD SUCCEEDED. Vai falhar enquanto a Task 8 não existir (`FileBrowserView` não definida) — **por isso a Task 4 é commitada depois da Task 9**. Se estiver executando em ordem, criar um stub temporário não: reordenar e fazer esta task depois da 9.

> **Nota de ordem de execução:** as Tasks 4 e 9 têm dependência circular de compilação (a lista navega para o browser). Executar na ordem **1 → 2 → 3 → 5 → 6 → 7 → 8 → 9 → 10 → 4**. A Task 4 fecha a fase ligando a aba.

- [ ] **Step 4: Verificar no simulador**

Abrir o app, ver a aba "Máquinas" na bottom bar, confirmar que lista as máquinas do `hub.env`. Puxar para atualizar.

- [ ] **Step 5: Commit**

```bash
git add app/CutuqueApp/MachineListView.swift app/CutuqueApp/CutuqueApp.swift
git commit -m "app: aba Máquinas com a lista de hosts do hub"
```

---

## Task 5: Listagem de arquivos no target (hub)

**Files:**
- Create: `hub/internal/adapter/claudecode/files.go`
- Create: `hub/internal/adapter/claudecode/files_test.go`
- Modify: `hub/internal/session/session.go:139-143` (tipos novos ao lado de `DirListing`), `hub/internal/adapter/agent/target.go:58` (interface opcional), `hub/internal/adapter/claudecode/target.go:24` (alias)

**Interfaces:**
- Consumes: `sshBaseOpts()`, `singleQuote()`, `childEnv()` de `target.go`.
- Produces: `session.FileEntry{Name, Path string; Size int64; ModTime int64; IsDir bool}`, `session.FileListing{Path, Parent string; Entries []FileEntry}`, a interface opcional `agent.FileLister{ListFiles(ctx, path) (session.FileListing, error)}` (alias `claudecode.FileLister`), e os métodos `(*LocalTarget).ListFiles` / `(*SSHTarget).ListFiles`.

> **Padrão obrigatório aqui:** `ListFiles` é **interface opcional**, igual ao `DirLister` (`agent/target.go:58`) — **não** entra na interface `Target`. O launcher resolve por `anyTarget` + type assertion, e `anyTarget` (`launcher.go:169`) prefere o alvo claude-code de forma determinística. Consequência: **codex e opencode não precisam implementar nada.** Pôr o método na `Target` obrigaria os três adapters a carregar código de arquivos sem nenhum ganho.

- [ ] **Step 1: Escrever o teste que falha**

Criar `hub/internal/adapter/claudecode/files_test.go`:

```go
package claudecode

import "testing"

func TestParseFileListingLeEntradasEOrdena(t *testing.T) {
	out := []byte(`{"path":"/home/vx","parent":"/home","entries":[
		{"name":"docs","path":"/home/vx/docs","size":0,"mtime":1700000000,"is_dir":true},
		{"name":".env","path":"/home/vx/.env","size":128,"mtime":1700000100,"is_dir":false}
	]}`)
	fl, err := parseFileListing(out)
	if err != nil {
		t.Fatalf("parse falhou: %v", err)
	}
	if fl.Path != "/home/vx" || fl.Parent != "/home" {
		t.Errorf("path/parent errados: %+v", fl)
	}
	if len(fl.Entries) != 2 {
		t.Fatalf("esperava 2 entradas, veio %d", len(fl.Entries))
	}
	if !fl.Entries[0].IsDir || fl.Entries[0].Name != "docs" {
		t.Errorf("primeira entrada deve ser a pasta: %+v", fl.Entries[0])
	}
	if fl.Entries[1].Size != 128 {
		t.Errorf("tamanho do arquivo errado: %d", fl.Entries[1].Size)
	}
}

func TestParseFileListingVazioNaoEhErro(t *testing.T) {
	fl, err := parseFileListing([]byte("   "))
	if err != nil {
		t.Fatalf("saída vazia não deve ser erro: %v", err)
	}
	if len(fl.Entries) != 0 {
		t.Errorf("esperava listagem vazia, veio %+v", fl)
	}
}

// O caminho vai como argv single-quoted, nunca interpolado no shell. Um
// caminho com aspas ou ponto-e-vírgula não pode virar comando.
func TestSSHListFilesArgsMandamCaminhoComoArgumentoQuotado(t *testing.T) {
	tgt := NewSSHTarget("macbook", "vx@host")
	args := tgt.listFilesArgs("/tmp/a b'; rm -rf /")
	last := args[len(args)-1]
	if !strings.HasPrefix(last, "python3 - ") {
		t.Fatalf("último arg deve rodar o python3 com o caminho: %q", last)
	}
	if strings.Contains(last, "; rm -rf /'") == false && strings.Contains(last, `'\''`) == false {
		t.Errorf("caminho não parece single-quoted: %q", last)
	}
}
```

Adicionar `"strings"` aos imports do teste.

- [ ] **Step 2: Rodar o teste e ver falhar**

Run: `cd hub && go test ./internal/adapter/claudecode/ -run "FileListing|ListFilesArgs" -v`
Expected: FAIL — `undefined: parseFileListing`.

- [ ] **Step 3: Adicionar os tipos**

Em `hub/internal/session/session.go`, logo depois de `DirListing`:

```go
// FileEntry é uma entrada de diretório (pasta ou arquivo) na máquina remota,
// para o painel Arquivos da aba Máquinas.
type FileEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	// Size em bytes. Zero para pasta.
	Size int64 `json:"size"`
	// ModTime é o mtime em segundos desde a epoch (o app formata).
	ModTime int64 `json:"mtime"`
	IsDir   bool  `json:"is_dir"`
}

// FileListing é o conteúdo navegável de um diretório: pastas E arquivos.
// Difere de DirListing, que lista só as subpastas e serve o seletor de cwd.
type FileListing struct {
	Path    string      `json:"path"`
	Parent  string      `json:"parent"`
	Entries []FileEntry `json:"entries"`
}
```

- [ ] **Step 4: Implementar o script e os métodos**

Criar `hub/internal/adapter/claudecode/files.go`:

```go
package claudecode

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

// filesScript lista pastas E arquivos de um caminho na máquina, para o painel
// Arquivos da aba Máquinas. Recebe o caminho como argv[1] (vazio → home).
// Emite JSON:
//
//	{"path","parent","entries":[{"name","path","size","mtime","is_dir"}]}
//
// Pastas primeiro, depois arquivos, cada grupo em ordem case-insensitive — é a
// ordem que um navegador de arquivos deve ter. Inclui ocultos: o app decide
// esconder com um toggle, igual ao seletor de pastas.
//
// Entrada ilegível (permissão, link quebrado) é pulada em silêncio: uma pasta
// com um arquivo problemático precisa continuar navegável.
const filesScript = `import os,json,sys
base=sys.argv[1] if len(sys.argv)>1 and sys.argv[1] else os.path.expanduser('~')
base=os.path.abspath(base)
dirs=[];files=[]
try:
    for name in sorted(os.listdir(base),key=str.lower):
        p=os.path.join(base,name)
        try:
            st=os.stat(p)
            if os.path.isdir(p): dirs.append({'name':name,'path':p,'size':0,'mtime':int(st.st_mtime),'is_dir':True})
            else: files.append({'name':name,'path':p,'size':int(st.st_size),'mtime':int(st.st_mtime),'is_dir':False})
        except Exception: pass
except Exception: pass
print(json.dumps({'path':base,'parent':os.path.dirname(base),'entries':dirs+files}))
`

// runFiles executa o comando (python3 lendo o filesScript pelo stdin) e faz
// parse do JSON. Mesmo molde do runDirs.
func runFiles(cmd *exec.Cmd) (session.FileListing, error) {
	cmd.Env = childEnv()
	cmd.Stdin = strings.NewReader(filesScript)
	out, err := cmd.Output()
	if err != nil {
		return session.FileListing{}, err
	}
	return parseFileListing(out)
}

// parseFileListing converte o JSON emitido pelo script em session.FileListing.
func parseFileListing(out []byte) (session.FileListing, error) {
	s := strings.TrimSpace(string(out))
	if s == "" {
		return session.FileListing{}, nil
	}
	var fl session.FileListing
	if err := json.Unmarshal([]byte(s), &fl); err != nil {
		return session.FileListing{}, err
	}
	return fl, nil
}

// ListFiles lista pastas e arquivos de path na máquina LOCAL.
func (t *LocalTarget) ListFiles(ctx context.Context, path string) (session.FileListing, error) {
	return runFiles(exec.CommandContext(ctx, "python3", "-", path))
}

// listFilesArgs monta os args do ssh. Isolado do ListFiles para ser testável
// sem tocar a rede.
func (t *SSHTarget) listFilesArgs(path string) []string {
	return append(sshBaseOpts(), "--", t.dest, "python3 - "+singleQuote(path))
}

// ListFiles lista pastas e arquivos de path na máquina remota via ssh. path vai
// single-quoted como argumento — nunca interpolado no shell.
func (t *SSHTarget) ListFiles(ctx context.Context, path string) (session.FileListing, error) {
	return runFiles(exec.CommandContext(ctx, t.prog, t.listFilesArgs(path)...))
}
```

- [ ] **Step 5: Declarar a interface opcional**

Em `hub/internal/adapter/agent/target.go`, logo depois de `DirLister` (linha 61):

```go
// FileLister lista pastas E arquivos de um caminho na máquina (painel Arquivos
// da aba Máquinas). Opcional como o DirLister: só o adapter claude-code
// implementa, e o launcher resolve por type assertion.
type FileLister interface {
	ListFiles(ctx context.Context, path string) (session.FileListing, error)
}
```

Em `hub/internal/adapter/claudecode/target.go`, no bloco de aliases (linha 24), junto do `DirLister`:

```go
	FileLister       = agent.FileLister
```

- [ ] **Step 6: Rodar os testes e ver passar**

Run: `cd hub && go test ./internal/adapter/claudecode/ -run "FileListing|ListFilesArgs" -v`
Expected: PASS (3 testes).

- [ ] **Step 7: Commit**

```bash
git add hub/internal/adapter hub/internal/session/session.go
git commit -m "hub: ListFiles no target, listando pastas e arquivos

Mesmo padrão do dirs.go (python3 pelo stdin do ssh, caminho como argv
single-quoted). DirListing continua existindo e servindo o seletor de cwd:
ele lista só pastas, e mudar seu contrato mexeria no fluxo de criar sessão."
```

---

## Task 6: Rota `GET /machines/{m}/fs`

**Files:**
- Modify: `hub/internal/launcher/launcher.go` (método `ListFiles`, ao lado do `ListDirs`)
- Modify: `hub/internal/server/launch.go:19-42` (interface `Launcher`) e `hub/internal/server/machines.go` (handler)
- Modify: `hub/internal/server/server.go` (rota), `hub/internal/server/launch_test.go` (fake)

**Interfaces:**
- Consumes: `(*SSHTarget).ListFiles` da Task 5.
- Produces: `launcher.ListFiles(machine, path string) (session.FileListing, error)`; rota `GET /machines/{m}/fs?path=` → `200 FileListing | 404 unknown_machine | 502 fs_failed`.

- [ ] **Step 1: Escrever o teste que falha**

Adicionar em `hub/internal/server/machines_test.go`:

```go
func TestGetFsListaPastasEArquivos(t *testing.T) {
	f := &fakeLauncher{fileListing: session.FileListing{
		Path:   "/home/vx",
		Parent: "/home",
		Entries: []session.FileEntry{
			{Name: "docs", Path: "/home/vx/docs", IsDir: true},
			{Name: "a.txt", Path: "/home/vx/a.txt", Size: 12, IsDir: false},
		},
	}}
	rec := do(t, f, http.MethodGet, "/machines/macbook/fs?path=%2Fhome%2Fvx", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if f.gotFsMachine != "macbook" || f.gotFsPath != "/home/vx" {
		t.Errorf("handler não repassou machine/path: %q %q", f.gotFsMachine, f.gotFsPath)
	}
	var got session.FileListing
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v", err)
	}
	if len(got.Entries) != 2 || !got.Entries[0].IsDir {
		t.Errorf("entradas erradas: %+v", got.Entries)
	}
}

func TestGetFsMaquinaDesconhecidaDa404(t *testing.T) {
	f := &fakeLauncher{fsErr: launcher.ErrUnknownMachine}
	rec := do(t, f, http.MethodGet, "/machines/naoexiste/fs", "")
	if rec.Code != http.StatusNotFound {
		t.Errorf("status %d, esperava 404", rec.Code)
	}
}

// python3 ausente no alvo, ssh caído: 502 com motivo próprio, para o app
// distinguir "máquina não existe" de "não consegui falar com ela".
func TestGetFsFalhaRemotaDa502(t *testing.T) {
	f := &fakeLauncher{fsErr: errors.New("ssh: exit 255")}
	rec := do(t, f, http.MethodGet, "/machines/macbook/fs", "")
	if rec.Code != http.StatusBadGateway {
		t.Errorf("status %d, esperava 502", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "fs_failed") {
		t.Errorf("corpo deve trazer fs_failed: %s", rec.Body.String())
	}
}
```

Adicionar aos imports do teste: `"errors"`, `"github.com/vxfontes/cutuque/hub/internal/launcher"`, `"github.com/vxfontes/cutuque/hub/internal/session"`.

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd hub && go test ./internal/server/ -run TestGetFs -v`
Expected: FAIL — `fakeLauncher` não tem `fileListing`/`fsErr`, rota inexistente.

- [ ] **Step 3: Estender o fake**

Em `hub/internal/server/launch_test.go`, adicionar aos campos do `fakeLauncher`:

```go
	fileListing session.FileListing
	fsErr       error
	gotFsMachine, gotFsPath string
```

e o método:

```go
func (f *fakeLauncher) ListFiles(machine, path string) (session.FileListing, error) {
	f.gotFsMachine, f.gotFsPath = machine, path
	return f.fileListing, f.fsErr
}
```

- [ ] **Step 4: Implementar no launcher**

Em `hub/internal/launcher/launcher.go`, ao lado de `ListDirs`, com o mesmo formato (buscar o target da máquina, devolver `ErrUnknownMachine` se não existe):

Em `hub/internal/launcher/launcher.go`, imediatamente depois de `ListDirs` (linha 609). Molde idêntico — `anyTarget` + type assertion na interface opcional, e o mesmo `l.baseCtx` com `discoverTimeout`:

```go
// ListFiles lista pastas e arquivos de path na máquina (painel Arquivos da aba
// Máquinas). path vazio → home. ErrUnknownMachine se a máquina não existe ou o
// alvo não sabe listar arquivos.
func (l *Launcher) ListFiles(machine, path string) (session.FileListing, error) {
	tgt, ok := l.anyTarget(machine)
	if !ok {
		return session.FileListing{}, ErrUnknownMachine
	}
	lister, ok := tgt.(claudecode.FileLister)
	if !ok {
		return session.FileListing{}, ErrUnknownMachine
	}
	ctx, cancel := context.WithTimeout(l.baseCtx, discoverTimeout)
	defer cancel()
	return lister.ListFiles(ctx, path)
}
```

Nada a fazer nos adapters codex e opencode: `anyTarget` prefere o alvo claude-code, que é o único que implementa `FileLister`.

- [ ] **Step 5: Adicionar à interface do server e ao handler**

Em `hub/internal/server/launch.go`, adicionar à interface `Launcher`:

```go
	ListFiles(machine, path string) (session.FileListing, error)
```

Em `hub/internal/server/machines.go`:

```go
// FilesHandler lista pastas e arquivos de um caminho na máquina.
//
//	GET /machines/{machine}/fs?path=/home/vx → 200 FileListing
//	(path vazio → home) | 404 unknown_machine | 502 fs_failed
func FilesHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		listing, err := lch.ListFiles(r.PathValue("machine"), r.URL.Query().Get("path"))
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "fs_failed")
		default:
			writeJSONResp(w, http.StatusOK, listing)
		}
	}
}
```

Em `server.go`, junto das rotas de `/machines/{machine}/...`:

```go
		mux.Handle("GET /machines/{machine}/fs", requireAuth(cfg.Token, FilesHandler(lch)))
```

- [ ] **Step 6: Rodar tudo**

Run: `cd hub && go build ./... && go test ./...`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add hub/internal/launcher hub/internal/server hub/internal/adapter
git commit -m "hub: GET /machines/{m}/fs lista pastas e arquivos"
```

---

## Task 7: Leitura de arquivo com teto e detecção de binário

**Files:**
- Modify: `hub/internal/adapter/claudecode/files.go` (`readScript`, `ReadFile`)
- Modify: `hub/internal/adapter/claudecode/files_test.go`
- Modify: `hub/internal/session/session.go`, `hub/internal/launcher/launcher.go`, `hub/internal/server/{launch.go,machines.go,server.go,launch_test.go}`

**Interfaces:**
- Consumes: `runFiles`/`parseFileListing` da Task 5.
- Produces: `session.FileContent{Path string; Size int64; Binary, Truncated bool; Content string}`; `(*SSHTarget).ReadFile(ctx, path)`; rota `GET /machines/{m}/fs/read?path=` → `200 FileContent | 400 bad_request | 404 unknown_machine | 502 fs_failed`.

- [ ] **Step 1: Escrever o teste que falha**

Adicionar em `hub/internal/adapter/claudecode/files_test.go`:

```go
func TestParseFileContentTexto(t *testing.T) {
	fc, err := parseFileContent([]byte(`{"path":"/a.txt","size":5,"binary":false,"truncated":false,"content":"olá\n"}`))
	if err != nil {
		t.Fatalf("parse falhou: %v", err)
	}
	if fc.Binary || fc.Truncated || fc.Content != "olá\n" {
		t.Errorf("conteúdo errado: %+v", fc)
	}
}

// Arquivo binário volta com binary=true e content vazio: o app oferece só
// download em vez de tentar renderizar bytes crus.
func TestParseFileContentBinarioNaoTrazConteudo(t *testing.T) {
	fc, err := parseFileContent([]byte(`{"path":"/a.png","size":9999,"binary":true,"truncated":false,"content":""}`))
	if err != nil {
		t.Fatalf("parse falhou: %v", err)
	}
	if !fc.Binary || fc.Content != "" {
		t.Errorf("binário deve vir sem conteúdo: %+v", fc)
	}
}

// Acima do teto de 1 MB o script não devolve o conteúdo — evita puxar um log
// de 2 GB para a memória do iPhone.
func TestParseFileContentAcimaDoTetoVemTruncado(t *testing.T) {
	fc, err := parseFileContent([]byte(`{"path":"/big.log","size":2097152,"binary":false,"truncated":true,"content":""}`))
	if err != nil {
		t.Fatalf("parse falhou: %v", err)
	}
	if !fc.Truncated || fc.Content != "" {
		t.Errorf("acima do teto deve vir truncated sem conteúdo: %+v", fc)
	}
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd hub && go test ./internal/adapter/claudecode/ -run TestParseFileContent -v`
Expected: FAIL — `undefined: parseFileContent`.

- [ ] **Step 3: Implementar**

Em `hub/internal/session/session.go`, depois de `FileListing`:

```go
// FileContent é o conteúdo de um arquivo lido na máquina remota.
// Binary e Truncated são exclusivos entre si na prática, e ambos implicam
// Content vazio — o app oferece download nos dois casos.
type FileContent struct {
	Path      string `json:"path"`
	Size      int64  `json:"size"`
	Binary    bool   `json:"binary"`
	Truncated bool   `json:"truncated"`
	Content   string `json:"content"`
}
```

Em `hub/internal/adapter/claudecode/files.go`:

```go
// maxReadBytes é o teto de leitura como texto (1 MiB). Acima disso o script
// devolve truncated=true sem conteúdo: puxar um log de 2 GB para a memória do
// iPhone não é uma opção.
const maxReadBytes = 1048576

// readScriptFmt lê um arquivo de texto da máquina. Recebe o caminho como
// argv[1] e o teto de bytes por Sprintf (%d). Emite JSON:
// {"path","size","binary","truncated","content"}.
//
// Binário é detectado por byte nulo nos primeiros 8 KiB — o mesmo heurístico
// que o git usa. Binário e arquivo acima do teto voltam com content vazio.
// Arquivo ilegível não é erro: volta zerado, e o app mostra vazio em vez de
// derrubar a navegação.
const readScriptFmt = `import os,json,sys
p=os.path.abspath(sys.argv[1])
try: size=os.path.getsize(p)
except Exception: print(json.dumps({'path':p,'size':0,'binary':False,'truncated':False,'content':''})); sys.exit(0)
binary=False;truncated=False;content=''
try:
    with open(p,'rb') as f:
        if b'\x00' in f.read(8192): binary=True
    if not binary:
        if size > %d: truncated=True
        else:
            with open(p,'rb') as f: content=f.read().decode('utf-8','replace')
except Exception: pass
print(json.dumps({'path':p,'size':size,'binary':binary,'truncated':truncated,'content':content}))
`

// runRead executa o comando e faz parse do JSON.
func runRead(cmd *exec.Cmd) (session.FileContent, error) {
	cmd.Env = childEnv()
	cmd.Stdin = strings.NewReader(fmt.Sprintf(readScriptFmt, maxReadBytes))
	out, err := cmd.Output()
	if err != nil {
		return session.FileContent{}, err
	}
	return parseFileContent(out)
}

// parseFileContent converte o JSON do readScript em session.FileContent.
func parseFileContent(out []byte) (session.FileContent, error) {
	s := strings.TrimSpace(string(out))
	if s == "" {
		return session.FileContent{}, nil
	}
	var fc session.FileContent
	if err := json.Unmarshal([]byte(s), &fc); err != nil {
		return session.FileContent{}, err
	}
	return fc, nil
}

// ReadFile lê um arquivo na máquina LOCAL.
func (t *LocalTarget) ReadFile(ctx context.Context, path string) (session.FileContent, error) {
	return runRead(exec.CommandContext(ctx, "python3", "-", path))
}

// ReadFile lê um arquivo na máquina remota via ssh.
func (t *SSHTarget) ReadFile(ctx context.Context, path string) (session.FileContent, error) {
	args := append(sshBaseOpts(), "--", t.dest, "python3 - "+singleQuote(path))
	return runRead(exec.CommandContext(ctx, t.prog, args...))
}
```

Adicionar `"fmt"` aos imports de `files.go`.

- [ ] **Step 4: Rodar e ver passar**

Run: `cd hub && go test ./internal/adapter/claudecode/ -run TestParseFileContent -v`
Expected: PASS (3 testes).

- [ ] **Step 5: Ligar launcher, interface, handler e rota**

Repetir o caminho da Task 6 para `ReadFile`: método no `Launcher` (`ReadFile(machine, path string) (session.FileContent, error)`), entrada na interface do server, método no `fakeLauncher`, e handler:

```go
// FileReadHandler devolve o conteúdo de um arquivo de texto.
//
//	GET /machines/{machine}/fs/read?path=/home/vx/a.txt → 200 FileContent |
//	400 bad_request (path vazio) | 404 unknown_machine | 502 fs_failed
func FileReadHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Query().Get("path")
		if path == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		fc, err := lch.ReadFile(r.PathValue("machine"), path)
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "fs_failed")
		default:
			writeJSONResp(w, http.StatusOK, fc)
		}
	}
}
```

Rota: `mux.Handle("GET /machines/{machine}/fs/read", requireAuth(cfg.Token, FileReadHandler(lch)))`.

Teste de contrato em `machines_test.go`: path vazio → 400; máquina desconhecida → 404; sucesso → 200 com o corpo do fake.

- [ ] **Step 6: Rodar tudo**

Run: `cd hub && go build ./... && go test ./...`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add hub/
git commit -m "hub: GET /machines/{m}/fs/read com teto de 1 MiB e detecção de binário

Binário por byte nulo nos primeiros 8 KiB (o heurístico do git). Binário e
arquivo acima do teto voltam com content vazio e a flag ligada — o app
oferece download em vez de renderizar."
```

---

## Task 8: Modelos e cliente de arquivos no app

**Files:**
- Modify: `app/CutuqueApp/Models.swift`
- Modify: `app/CutuqueApp/APIClient.swift`
- Modify: `app/CutuqueAppTests/MachineFileTests.swift`

**Interfaces:**
- Consumes: rotas `/fs` e `/fs/read` das Tasks 6 e 7.
- Produces: `FileEntry`, `FileListing`, `FileContent` (Decodable); `APIClient.listFiles(machine:path:) async throws -> FileListing`; `APIClient.readFile(machine:path:) async throws -> FileContent`; `FileEntry.sizeLabel: String`.

- [ ] **Step 1: Escrever o teste que falha**

Adicionar em `app/CutuqueAppTests/MachineFileTests.swift`:

```swift
    func testDecodeDeFileListingComPastaEArquivo() throws {
        let json = Data("""
        {"path":"/home/vx","parent":"/home","entries":[
          {"name":"docs","path":"/home/vx/docs","size":0,"mtime":1700000000,"is_dir":true},
          {"name":"a.txt","path":"/home/vx/a.txt","size":2048,"mtime":1700000100,"is_dir":false}
        ]}
        """.utf8)
        let fl = try JSONDecoder.cutuque.decode(FileListing.self, from: json)
        XCTAssertEqual(fl.path, "/home/vx")
        XCTAssertEqual(fl.entries.count, 2)
        XCTAssertTrue(fl.entries[0].isDir)
        XCTAssertEqual(fl.entries[1].size, 2048)
    }

    func testEntradaOcultaEhDetectadaPeloPonto() throws {
        let e = FileEntry(name: ".env", path: "/a/.env", size: 10, mtime: 0, isDir: false)
        XCTAssertTrue(e.isHidden)
        let v = FileEntry(name: "env", path: "/a/env", size: 10, mtime: 0, isDir: false)
        XCTAssertFalse(v.isHidden)
    }

    /// Pasta não mostra tamanho; arquivo mostra em unidade legível.
    func testRotuloDeTamanho() {
        let pasta = FileEntry(name: "d", path: "/d", size: 0, mtime: 0, isDir: true)
        XCTAssertEqual(pasta.sizeLabel, "")
        let arq = FileEntry(name: "a", path: "/a", size: 2048, mtime: 0, isDir: false)
        XCTAssertTrue(arq.sizeLabel.contains("KB"), "veio \(arq.sizeLabel)")
    }

    /// Binário e acima do teto são os dois casos em que só cabe download.
    func testSoDownloadQuandoBinarioOuTruncado() {
        let texto = FileContent(path: "/a", size: 10, binary: false, truncated: false, content: "oi")
        XCTAssertFalse(texto.precisaBaixar)
        let bin = FileContent(path: "/a", size: 10, binary: true, truncated: false, content: "")
        XCTAssertTrue(bin.precisaBaixar)
        let grande = FileContent(path: "/a", size: 99, binary: false, truncated: true, content: "")
        XCTAssertTrue(grande.precisaBaixar)
    }
```

- [ ] **Step 2: Rodar e ver falhar**

Run:
```bash
cd app && xcodebuild test -scheme CutuqueApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:CutuqueAppTests/MachineFileTests 2>&1 | tail -20
```
Expected: FAIL de compilação — `cannot find 'FileListing' in scope`.

- [ ] **Step 3: Adicionar os modelos**

Em `app/CutuqueApp/Models.swift`, depois de `DirListing`:

```swift
/// Uma entrada de diretório na máquina remota: pasta ou arquivo.
struct FileEntry: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let size: Int64
    let mtime: Int64
    let isDir: Bool

    var id: String { path }
    /// Oculta = começa com "." — escondida por padrão, com toggle.
    var isHidden: Bool { name.hasPrefix(".") }

    /// Tamanho legível. Pasta não mostra nada.
    var sizeLabel: String {
        guard !isDir else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Conteúdo navegável de um diretório: pastas E arquivos. Difere do DirListing,
/// que lista só pastas e serve o seletor de cwd ao criar sessão.
struct FileListing: Decodable {
    let path: String
    let parent: String
    let entries: [FileEntry]
}

/// Conteúdo de um arquivo lido na máquina.
struct FileContent: Decodable {
    let path: String
    let size: Int64
    let binary: Bool
    let truncated: Bool
    let content: String

    /// Binário ou acima do teto de leitura: só cabe baixar.
    var precisaBaixar: Bool { binary || truncated }
}
```

O `JSONDecoder.cutuque` já usa `convertFromSnakeCase` (é como `DirEntry` decodifica hoje), então `is_dir` cai em `isDir` sozinho — confirmar em `APIClient.swift` na definição de `JSONDecoder.cutuque`. Se não usar, adicionar `CodingKeys` explícitas.

- [ ] **Step 4: Adicionar os clientes**

Em `app/CutuqueApp/APIClient.swift`, no mesmo formato de `listDirs`:

```swift
    /// Lista pastas e arquivos de um caminho na máquina (painel Arquivos).
    /// path vazio = home. `GET /machines/{machine}/fs?path=`.
    func listFiles(machine: String, path: String) async throws -> FileListing {
        try await getJSON(machine: machine, sub: "fs", path: path, as: FileListing.self)
    }

    /// Lê um arquivo de texto na máquina. `GET /machines/{machine}/fs/read?path=`.
    func readFile(machine: String, path: String) async throws -> FileContent {
        try await getJSON(machine: machine, sub: "fs/read", path: path, as: FileContent.self)
    }

    /// Molde comum das duas chamadas de arquivo: monta a URL com `path` na
    /// query, autentica e mapeia os status. Existe para não repetir o bloco.
    private func getJSON<T: Decodable>(machine: String, sub: String, path: String, as: T.Type) async throws -> T {
        var url = baseURL.appendingPathComponent("machines").appendingPathComponent(machine)
        for part in sub.split(separator: "/") { url.appendPathComponent(String(part)) }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !path.isEmpty { comps.queryItems = [URLQueryItem(name: "path", value: path)] }
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200:
            return try JSONDecoder.cutuque.decode(T.self, from: data)
        case 404:
            throw CutuqueError.server(status: 404, message: "máquina desconhecida")
        case 502, 503:
            throw CutuqueError.server(status: http.statusCode, message: "a máquina não respondeu (python3 instalado lá?)")
        default:
            throw CutuqueError.unexpected(status: http.statusCode)
        }
    }
```

- [ ] **Step 5: Rodar e ver passar**

Run:
```bash
cd app && xcodebuild test -scheme CutuqueApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:CutuqueAppTests/MachineFileTests 2>&1 | tail -20
```
Expected: PASS (6 testes).

- [ ] **Step 6: Commit**

```bash
git add app/CutuqueApp/Models.swift app/CutuqueApp/APIClient.swift app/CutuqueAppTests/MachineFileTests.swift
git commit -m "app: modelos e cliente de arquivos (listFiles, readFile)"
```

---

## Task 9: Navegador de arquivos

**Files:**
- Create: `app/CutuqueApp/FileBrowserView.swift`

**Interfaces:**
- Consumes: `FileListing`, `FileEntry`, `APIClient.listFiles` da Task 8; `FileViewerView` da Task 10 (criar a Task 10 antes de compilar esta).
- Produces: `struct FileBrowserView: View` com `init(machine: String, path: String)`.

- [ ] **Step 1: Criar a view**

Criar `app/CutuqueApp/FileBrowserView.swift`. Segue a estrutura do `FolderPickerView` (subir de nível, toggle de ocultos), com arquivos além de pastas:

```swift
import SwiftUI

/// Painel Arquivos da aba Máquinas: navega pastas e arquivos de um host.
/// Pasta abre outro nível; arquivo abre o visualizador. Ocultos escondidos por
/// padrão, com toggle — igual ao seletor de pastas.
struct FileBrowserView: View {
    let machine: String
    let path: String

    @State private var listing: FileListing?
    @State private var loading = false
    @State private var error: String?
    @AppStorage("machines.showHiddenFiles") private var showHidden = false
    private let api = APIClient()

    private var visible: [FileEntry] {
        let all = listing?.entries ?? []
        return showHidden ? all : all.filter { !$0.isHidden }
    }

    var body: some View {
        List {
            ForEach(visible) { entry in
                if entry.isDir {
                    NavigationLink {
                        FileBrowserView(machine: machine, path: entry.path)
                    } label: {
                        Label(entry.name, systemImage: "folder")
                    }
                } else {
                    NavigationLink {
                        FileViewerView(machine: machine, entry: entry)
                    } label: {
                        HStack {
                            Label(entry.name, systemImage: "doc")
                                .lineLimit(1)
                            Spacer()
                            Text(entry.sizeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if visible.isEmpty && !loading {
                Text(showHidden ? "Pasta vazia" : "Nada visível aqui (há itens ocultos?)")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(titulo)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $showHidden) {
                    Label("Ocultos", systemImage: showHidden ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
            }
        }
        .overlay { if loading && listing == nil { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
        .alert("Não deu para listar", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// Nome da pasta atual, ou o nome da máquina na raiz da navegação.
    private var titulo: String {
        guard let p = listing?.path, p != "/" else { return machine }
        return (p as NSString).lastPathComponent
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            listing = try await api.listFiles(machine: machine, path: path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

> A navegação é por `NavigationLink` empilhado: entrar numa pasta empurra outra `FileBrowserView`, e o botão nativo de voltar já faz o papel do "..". Por isso o item ".." do `FolderPickerView` não é replicado — ele existia lá porque o seletor era um `sheet` sem pilha.

- [ ] **Step 2: Compilar (junto com a Task 10)**

Run:
```bash
cd app && xcodegen generate && xcodebuild build -scheme CutuqueApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -15
```
Expected: BUILD SUCCEEDED depois que a Task 10 existir.

- [ ] **Step 3: Commit (depois da Task 10)**

---

## Task 10: Visualizador de arquivo

**Files:**
- Create: `app/CutuqueApp/FileViewerView.swift`

**Interfaces:**
- Consumes: `FileEntry`, `FileContent`, `APIClient.readFile` da Task 8.
- Produces: `struct FileViewerView: View` com `init(machine: String, entry: FileEntry)`.

- [ ] **Step 1: Criar a view**

Criar `app/CutuqueApp/FileViewerView.swift`:

```swift
import SwiftUI

/// Mostra o conteúdo de um arquivo de texto da máquina. Binário ou acima do
/// teto de 1 MB não é renderizado — só oferece compartilhar/salvar, porque
/// puxar bytes crus para a tela do iPhone não ajuda ninguém.
///
/// Nesta fase é só leitura: editar e salvar entram na F2.
struct FileViewerView: View {
    let machine: String
    let entry: FileEntry

    @State private var content: FileContent?
    @State private var loading = false
    @State private var error: String?
    private let api = APIClient()

    var body: some View {
        Group {
            if let content {
                if content.precisaBaixar {
                    ContentUnavailableView {
                        Label(content.binary ? "Arquivo binário" : "Arquivo grande demais",
                              systemImage: content.binary ? "doc.badge.gearshape" : "doc.badge.ellipsis")
                    } description: {
                        Text(content.binary
                             ? "Não dá para mostrar como texto (\(entry.sizeLabel))."
                             : "Acima do limite de leitura de 1 MB (\(entry.sizeLabel)).")
                    }
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(content.content)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            } else if let error {
                ContentUnavailableView {
                    Label("Não deu para abrir", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Tentar de novo") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let content, !content.precisaBaixar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: content.content, preview: SharePreview(entry.name)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            content = try await api.readFile(machine: machine, path: entry.path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

> **Nota sobre download:** o spec pede baixar para o app Arquivos. Nesta fase o `ShareLink` cobre texto (salvar em Arquivos é um dos destinos da folha de compartilhamento). Download de **binário** exige uma rota `/fs/download` que sirva os bytes — fica declarado como lacuna consciente e entra junto com a F2, quando houver escrita e o modelo de transferência de bytes precisar existir de qualquer jeito.

- [ ] **Step 2: Compilar**

Run:
```bash
cd app && xcodegen generate && xcodebuild build -scheme CutuqueApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -15
```
Expected: BUILD SUCCEEDED (agora `FileBrowserView` e `FileViewerView` se resolvem mutuamente).

- [ ] **Step 3: Rodar a suíte do app**

Run:
```bash
cd app && xcodebuild test -scheme CutuqueApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: PASS — inclusive os testes que já existiam (não-regressão).

- [ ] **Step 4: Commit**

```bash
git add app/CutuqueApp/FileBrowserView.swift app/CutuqueApp/FileViewerView.swift
git commit -m "app: navegador de arquivos e visualizador de texto

Navegação por pilha: entrar numa pasta empurra outra FileBrowserView e o
voltar nativo faz o papel do '..'. O FolderPickerView precisava do '..'
porque era um sheet sem pilha; aqui não."
```

---

## Verificação final da fase

Depois da Task 4 (que fecha a aba), verificar no simulador com o hub real:

- [ ] A aba "Máquinas" aparece na bottom bar do iPhone e lista as máquinas do `hub.env`.
- [ ] Tocar numa máquina abre a home dela com pastas e arquivos, pastas primeiro.
- [ ] O toggle de ocultos revela `.zshrc`, `.ssh` etc., e o estado persiste entre navegações.
- [ ] Entrar em pasta e voltar funciona pela pilha nativa.
- [ ] Tocar num `.txt` mostra o conteúdo em fonte monoespaçada, com seleção de texto.
- [ ] Tocar num `.png` mostra "Arquivo binário" em vez de lixo na tela.
- [ ] Tocar num arquivo acima de 1 MB mostra "Arquivo grande demais".
- [ ] Máquina desligada mostra erro legível, e a lista continua utilizável.
- [ ] **Não-regressão:** criar sessão nova ainda abre o seletor de pastas (`FolderPickerView`) normalmente, e o terminal das sessões segue igual.

## O que este plano NÃO entrega (e onde entra)

| Item | Fase |
|---|---|
| Editar e salvar arquivo | F2 |
| Download de binário (`/fs/download`) | F2 |
| Cadastrar máquina nova, gerar chave, TOFU | F3 |
| Terminal PTY, SwiftTerm, WebSocket | F4 |
| Painel duplo Terminal↔Arquivos no detalhe da máquina | F4 |
| Destino `.machines` na sidebar do iPad | F5 |
| Persistência do registro (Postgres/JSON) | F3 |
