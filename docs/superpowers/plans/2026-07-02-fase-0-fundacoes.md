# Fase 0 — Fundações e Infraestrutura — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ter o esqueleto do hub em Go rodando local com um healthcheck, e o app iOS mínimo que confirma "online" lendo esse healthcheck.

**Architecture:** Hub em Go com stdlib (`net/http` + `log/slog`), config por ambiente (dev = localhost, prod = interface Tailscale, usada só na Fase 5). App iOS em SwiftUI que faz um GET no `/health`. Sem lógica de agente ainda — só a fundação de rede ponta a ponta.

**Tech Stack:** Go 1.22+ (stdlib), SwiftUI (iOS 17+), git.

## Global Constraints

- Go 1.22 ou superior. **Sem dependências externas** na Fase 0 — apenas stdlib.
- Hub roda **local** durante o desenvolvimento (`dev` = bind `127.0.0.1`). Bind na interface
  Tailscale (`prod` = `192.0.2.10`) existe na config mas só é usado na Fase 5.
- Segredos (futuro APNs `.p8`, chaves ssh) **nunca** versionados — cobrir no `.gitignore`.
- Nome do módulo Go: `github.com/vxfontes/cutuque/hub`.
- Porta padrão do hub: `8787` (env `CUTUQUE_PORT`).
- Respostas da API em JSON.
- Commits frequentes, um por tarefa concluída.

---

## Estrutura de arquivos

```
cutuque/
  hub/
    go.mod
    Makefile
    cmd/hub/main.go              # entrypoint: carrega config, sobe o servidor
    internal/config/config.go    # Config + Load() por ambiente
    internal/config/config_test.go
    internal/server/server.go    # construção do http.Server e roteamento
    internal/server/health.go    # handler GET /health
    internal/server/health_test.go
  app/
    CutuqueApp/                  # projeto Xcode (SwiftUI)
      CutuqueApp.swift
      HealthView.swift
      HealthClient.swift
  .gitignore
```

---

### Task 1: Bootstrap do módulo Go e `.gitignore`

**Files:**
- Create: `hub/go.mod`
- Create: `.gitignore`

**Interfaces:**
- Consumes: nada.
- Produces: módulo Go `github.com/vxfontes/cutuque/hub` compilável.

- [ ] **Step 1: Inicializar o módulo Go**

Run:
```bash
cd hub && go mod init github.com/vxfontes/cutuque/hub
```
Expected: cria `hub/go.mod` com `module github.com/vxfontes/cutuque/hub` e a linha `go 1.22` (ou superior).

- [ ] **Step 2: Criar o `.gitignore` na raiz do projeto**

Create `.gitignore`:
```gitignore
# Go
/hub/bin/
*.test
*.out

# Segredos — nunca versionar
*.p8
*.pem
*.key
secrets/
.env
.env.*

# macOS / Xcode
.DS_Store
/app/**/xcuserdata/
/app/**/*.xcuserstate
DerivedData/
```

- [ ] **Step 3: Verificar que compila (vazio)**

Run:
```bash
cd hub && go build ./...
```
Expected: sem erros (nenhum pacote ainda, saída vazia, exit 0).

- [ ] **Step 4: Commit**

```bash
git add hub/go.mod .gitignore
git commit -m "chore: bootstrap do modulo Go do hub + gitignore"
```

---

### Task 2: Config por ambiente

**Files:**
- Create: `hub/internal/config/config.go`
- Test: `hub/internal/config/config_test.go`

**Interfaces:**
- Consumes: nada.
- Produces:
  - `type Config struct { Env string; BindAddr string; Port int; Token string }`
  - `func Load() Config` — lê env vars e resolve `BindAddr` por ambiente.
  - `func (c Config) Addr() string` — retorna `"BindAddr:Port"`.

- [ ] **Step 1: Escrever o teste que falha**

Create `hub/internal/config/config_test.go`:
```go
package config

import "testing"

func TestLoadDefaultsToDevLocalhost(t *testing.T) {
	t.Setenv("CUTUQUE_ENV", "")
	t.Setenv("CUTUQUE_PORT", "")
	t.Setenv("CUTUQUE_BIND", "")

	c := Load()

	if c.Env != "dev" {
		t.Errorf("Env = %q, quero \"dev\"", c.Env)
	}
	if c.BindAddr != "127.0.0.1" {
		t.Errorf("BindAddr = %q, quero \"127.0.0.1\"", c.BindAddr)
	}
	if c.Port != 8787 {
		t.Errorf("Port = %d, quero 8787", c.Port)
	}
	if got := c.Addr(); got != "127.0.0.1:8787" {
		t.Errorf("Addr() = %q, quero \"127.0.0.1:8787\"", got)
	}
}

func TestLoadProdBindsTailscale(t *testing.T) {
	t.Setenv("CUTUQUE_ENV", "prod")
	t.Setenv("CUTUQUE_PORT", "")
	t.Setenv("CUTUQUE_BIND", "")

	c := Load()

	if c.BindAddr != "192.0.2.10" {
		t.Errorf("BindAddr = %q, quero \"192.0.2.10\"", c.BindAddr)
	}
}

func TestLoadExplicitBindOverrides(t *testing.T) {
	t.Setenv("CUTUQUE_ENV", "prod")
	t.Setenv("CUTUQUE_BIND", "0.0.0.0")

	if c := Load(); c.BindAddr != "0.0.0.0" {
		t.Errorf("BindAddr = %q, quero \"0.0.0.0\"", c.BindAddr)
	}
}
```

- [ ] **Step 2: Rodar o teste para confirmar que falha**

Run:
```bash
cd hub && go test ./internal/config/ -run TestLoad -v
```
Expected: FAIL de compilação (`undefined: Load`, `undefined: Config`).

- [ ] **Step 3: Implementar a config mínima**

Create `hub/internal/config/config.go`:
```go
// Package config carrega a configuração do hub a partir de variáveis de ambiente.
package config

import (
	"os"
	"strconv"
)

const (
	defaultPort         = 8787
	devBindAddr         = "127.0.0.1"
	tailscaleBindAddr   = "192.0.2.10"
)

// Config é a configuração resolvida do hub.
type Config struct {
	Env      string // "dev" (padrão) ou "prod"
	BindAddr string // endereço IP para escutar
	Port     int
	Token    string // bearer token dos devices (vazio na Fase 0)
}

// Load lê as env vars e resolve a configuração.
// CUTUQUE_ENV: "dev" (padrão) ou "prod".
// CUTUQUE_PORT: porta (padrão 8787).
// CUTUQUE_BIND: sobrescreve o BindAddr resolvido por ambiente.
// CUTUQUE_TOKEN: bearer token dos devices.
func Load() Config {
	env := os.Getenv("CUTUQUE_ENV")
	if env == "" {
		env = "dev"
	}

	bind := devBindAddr
	if env == "prod" {
		bind = tailscaleBindAddr
	}
	if b := os.Getenv("CUTUQUE_BIND"); b != "" {
		bind = b
	}

	port := defaultPort
	if p := os.Getenv("CUTUQUE_PORT"); p != "" {
		if n, err := strconv.Atoi(p); err == nil {
			port = n
		}
	}

	return Config{
		Env:      env,
		BindAddr: bind,
		Port:     port,
		Token:    os.Getenv("CUTUQUE_TOKEN"),
	}
}

// Addr retorna o endereço "BindAddr:Port" para o http.Server.
func (c Config) Addr() string {
	return c.BindAddr + ":" + strconv.Itoa(c.Port)
}
```

- [ ] **Step 4: Rodar o teste para confirmar que passa**

Run:
```bash
cd hub && go test ./internal/config/ -v
```
Expected: PASS em todos os três testes.

- [ ] **Step 5: Commit**

```bash
git add hub/internal/config/
git commit -m "feat(config): carregar config por ambiente (dev/prod)"
```

---

### Task 3: Handler de healthcheck

**Files:**
- Create: `hub/internal/server/health.go`
- Test: `hub/internal/server/health_test.go`

**Interfaces:**
- Consumes: nada.
- Produces:
  - `func HealthHandler() http.HandlerFunc` — responde `200` com JSON
    `{"status":"ok","service":"cutuque-hub"}`.

- [ ] **Step 1: Escrever o teste que falha**

Create `hub/internal/server/health_test.go`:
```go
package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthHandlerReturnsOK(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	HealthHandler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}

	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("resposta não é JSON válido: %v", err)
	}
	if body["status"] != "ok" {
		t.Errorf("status = %q, quero \"ok\"", body["status"])
	}
	if body["service"] != "cutuque-hub" {
		t.Errorf("service = %q, quero \"cutuque-hub\"", body["service"])
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, quero \"application/json\"", ct)
	}
}
```

- [ ] **Step 2: Rodar o teste para confirmar que falha**

Run:
```bash
cd hub && go test ./internal/server/ -run TestHealth -v
```
Expected: FAIL de compilação (`undefined: HealthHandler`).

- [ ] **Step 3: Implementar o handler**

Create `hub/internal/server/health.go`:
```go
// Package server monta o servidor HTTP do hub e seus handlers.
package server

import (
	"encoding/json"
	"net/http"
)

// HealthHandler responde ao healthcheck do hub.
func HealthHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{
			"status":  "ok",
			"service": "cutuque-hub",
		})
	}
}
```

- [ ] **Step 4: Rodar o teste para confirmar que passa**

Run:
```bash
cd hub && go test ./internal/server/ -v
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add hub/internal/server/
git commit -m "feat(server): handler GET /health"
```

---

### Task 4: Montagem do servidor e roteamento

**Files:**
- Create: `hub/internal/server/server.go`
- Modify: `hub/internal/server/health_test.go` (adicionar teste de roteamento)

**Interfaces:**
- Consumes: `HealthHandler()` (Task 3), `config.Config` (Task 2).
- Produces:
  - `func New(cfg config.Config) *http.Server` — monta o `*http.Server` com o mux e o
    endereço de `cfg.Addr()`.
  - `func Router() *http.ServeMux` — registra as rotas (`GET /health`).

- [ ] **Step 1: Escrever o teste de roteamento que falha**

Append em `hub/internal/server/health_test.go`:
```go
func TestRouterServesHealth(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /health via Router = %d, quero 200", rec.Code)
	}
}
```

- [ ] **Step 2: Rodar para confirmar que falha**

Run:
```bash
cd hub && go test ./internal/server/ -run TestRouter -v
```
Expected: FAIL de compilação (`undefined: Router`).

- [ ] **Step 3: Implementar `Router` e `New`**

Create `hub/internal/server/server.go`:
```go
package server

import (
	"net/http"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/config"
)

// Router registra as rotas do hub.
func Router() *http.ServeMux {
	mux := http.NewServeMux()
	mux.Handle("GET /health", HealthHandler())
	return mux
}

// New monta o *http.Server do hub a partir da config.
func New(cfg config.Config) *http.Server {
	return &http.Server{
		Addr:              cfg.Addr(),
		Handler:           Router(),
		ReadHeaderTimeout: 5 * time.Second,
	}
}
```

- [ ] **Step 4: Rodar os testes do pacote para confirmar que passam**

Run:
```bash
cd hub && go test ./internal/server/ -v
```
Expected: PASS em `TestHealthHandlerReturnsOK` e `TestRouterServesHealth`.

- [ ] **Step 5: Commit**

```bash
git add hub/internal/server/
git commit -m "feat(server): montar http.Server e roteamento"
```

---

### Task 5: Entrypoint `cmd/hub` + Makefile + smoke test manual

**Files:**
- Create: `hub/cmd/hub/main.go`
- Create: `hub/Makefile`

**Interfaces:**
- Consumes: `config.Load()` (Task 2), `server.New()` (Task 4).
- Produces: binário executável do hub que sobe o servidor e loga o endereço.

- [ ] **Step 1: Implementar o entrypoint**

Create `hub/cmd/hub/main.go`:
```go
package main

import (
	"log/slog"
	"os"

	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/server"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
	cfg := config.Load()
	srv := server.New(cfg)

	logger.Info("cutuque hub subindo", "env", cfg.Env, "addr", cfg.Addr())
	if err := srv.ListenAndServe(); err != nil {
		logger.Error("servidor parou", "err", err)
		os.Exit(1)
	}
}
```

- [ ] **Step 2: Criar o Makefile**

Create `hub/Makefile`:
```makefile
.PHONY: run test build tidy

run:
	go run ./cmd/hub

test:
	go test ./...

build:
	go build -o bin/hub ./cmd/hub

tidy:
	go mod tidy
```

- [ ] **Step 3: Verificar build e testes**

Run:
```bash
cd hub && go build ./... && go test ./...
```
Expected: build sem erros; todos os testes PASS.

- [ ] **Step 4: Smoke test manual do servidor**

Terminal A:
```bash
cd hub && make run
```
Expected: log `cutuque hub subindo env=dev addr=127.0.0.1:8787`.

Terminal B:
```bash
curl -s http://127.0.0.1:8787/health
```
Expected: `{"status":"ok","service":"cutuque-hub"}`

Parar o servidor no Terminal A com Ctrl-C.

- [ ] **Step 5: Commit**

```bash
git add hub/cmd/ hub/Makefile
git commit -m "feat(hub): entrypoint cmd/hub + Makefile"
```

---

### Task 6: App iOS mínimo — cliente do healthcheck

**Files:**
- Create: `app/CutuqueApp/CutuqueApp.swift`
- Create: `app/CutuqueApp/HealthClient.swift`
- Create: `app/CutuqueApp/HealthView.swift`

**Interfaces:**
- Consumes: endpoint `GET /health` do hub (Task 3–5).
- Produces: app SwiftUI que mostra "online"/"offline" conforme o healthcheck.

> Nota: a criação do projeto Xcode é manual (não há CLI TDD para UI aqui). Os passos abaixo
> criam o projeto e substituem os arquivos gerados pelo conteúdo fornecido. A verificação é
> visual no simulador.

- [ ] **Step 1: Criar o projeto no Xcode**

No Xcode: File → New → Project → iOS → App.
- Product Name: `CutuqueApp`
- Interface: SwiftUI · Language: Swift
- Salvar em `app/` (resultando em `app/CutuqueApp/`).

- [ ] **Step 2: Implementar o cliente do healthcheck**

Create/replace `app/CutuqueApp/HealthClient.swift`:
```swift
import Foundation

enum HealthStatus: Equatable {
    case unknown
    case online
    case offline
}

struct HealthClient {
    // Em dev, o hub roda local. No simulador, localhost do Mac é acessível via 127.0.0.1.
    // Ajustar para o IP Tailscale do hub quando testar em device / após deploy (Fase 5).
    var baseURL = URL(string: "http://127.0.0.1:8787")!

    func check() async -> HealthStatus {
        let url = baseURL.appendingPathComponent("health")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let body = try? JSONDecoder().decode([String: String].self, from: data),
                  body["status"] == "ok" else {
                return .offline
            }
            return .online
        } catch {
            return .offline
        }
    }
}
```

- [ ] **Step 3: Implementar a view**

Create/replace `app/CutuqueApp/HealthView.swift`:
```swift
import SwiftUI

@MainActor
final class HealthViewModel: ObservableObject {
    @Published var status: HealthStatus = .unknown
    private let client = HealthClient()

    func refresh() async {
        status = await client.check()
    }
}

struct HealthView: View {
    @StateObject private var model = HealthViewModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("Cutuque").font(.largeTitle.bold())
            switch model.status {
            case .unknown: Label("verificando…", systemImage: "circle.dotted")
            case .online:  Label("hub online", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .offline: Label("hub offline", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            Button("Verificar") { Task { await model.refresh() } }
        }
        .padding()
        .task { await model.refresh() }
    }
}
```

- [ ] **Step 4: Ligar a view ao app**

Create/replace `app/CutuqueApp/CutuqueApp.swift`:
```swift
import SwiftUI

@main
struct CutuqueApp: App {
    var body: some Scene {
        WindowGroup {
            HealthView()
        }
    }
}
```

- [ ] **Step 5: Permitir HTTP local (App Transport Security)**

No target do app, em Info: adicionar `App Transport Security Settings` →
`Allow Arbitrary Loads` = `YES` (apenas dev; em prod usaremos o IP Tailscale, revisar na
Fase 5). Alternativa mais restrita: adicionar exceção só para `127.0.0.1`.

- [ ] **Step 6: Verificação manual (simulador)**

1. Rodar o hub: `cd hub && make run`.
2. No Xcode, rodar o app no simulador.
3. Esperado: aparece **"hub online"** (verde). Parar o hub e tocar "Verificar" → **"hub offline"** (vermelho).

- [ ] **Step 7: Commit**

```bash
git add app/
git commit -m "feat(app): app iOS minimo lendo /health do hub"
```

---

## Self-Review

**1. Cobertura do spec (Fase 0 do doc 07):**
- Repositório Go do hub → Task 1 ✅
- Hub roda local + healthcheck → Tasks 3–5 ✅
- Config por ambiente (dev/prod) → Task 2 ✅
- `.gitignore` de segredos → Task 1 ✅
- Projeto Xcode lendo `/health` → Task 6 ✅
- Critério de aceite (hub sobe local, app lê `/health`) → Task 5 (curl) + Task 6 (app) ✅

**2. Placeholders:** nenhum "TODO/TBD"; todo passo de código tem o código completo.

**3. Consistência de tipos:** `config.Config`/`Load()`/`Addr()`, `HealthHandler()`, `Router()`,
`New()` são usados com as mesmas assinaturas entre as tasks. `HealthStatus`/`HealthClient.check()`
consistentes entre `HealthClient.swift` e `HealthView.swift`.

## Próximo passo

Ao concluir a Fase 0, seguir para
[`2026-07-02-fase-1-registry-command-api.md`](2026-07-02-fase-1-registry-command-api.md).
