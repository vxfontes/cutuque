package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/launcher"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// codeServerFake acrescenta a capability de code-server ao fake compartilhado
// pelos testes dos handlers de launch.go. O embedding mantém o teste focado na
// nova operação sem duplicar a superfície inteira de Launcher.
type codeServerFake struct {
	*fakeLauncher
	result     session.CodeServer
	err        error
	gotMachine string
	gotDir     string
}

func (f *codeServerFake) StartCodeServer(machine, dir string) (session.CodeServer, error) {
	f.gotMachine, f.gotDir = machine, dir
	return f.result, f.err
}

func newCodeServerFake() *codeServerFake {
	return &codeServerFake{fakeLauncher: &fakeLauncher{}}
}

func doCodeServer(t *testing.T, f *codeServerFake, auth bool, body string) *httptest.ResponseRecorder {
	t.Helper()
	cfg, reg := testDeps()
	req := httptest.NewRequest(http.MethodPost, "/machines/macbook/code-server", strings.NewReader(body))
	if auth {
		req.Header.Set("Authorization", "Bearer secret")
	}
	rec := httptest.NewRecorder()
	Router(cfg, reg, f).ServeHTTP(rec, req)
	return rec
}

func TestPostCodeServerStartsAndReturnsStateAndURL(t *testing.T) {
	f := newCodeServerFake()
	f.result = session.CodeServer{URL: "https://macbook.example.ts.net", State: "running"}

	rec := doCodeServer(t, f, true, `{"dir":"/workspace/project"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	if f.gotMachine != "macbook" || f.gotDir != "/workspace/project" {
		t.Fatalf("argumentos incorretos: machine=%q dir=%q", f.gotMachine, f.gotDir)
	}

	var got session.CodeServer
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("JSON inválido: %v", err)
	}
	if got != f.result {
		t.Fatalf("resposta = %+v, esperava %+v", got, f.result)
	}
}

func TestPostCodeServerRequiresAuth(t *testing.T) {
	f := newCodeServerFake()
	rec := doCodeServer(t, f, false, `{"dir":"/workspace/project"}`)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status %d, esperava 401: %s", rec.Code, rec.Body.String())
	}
	if f.gotMachine != "" || f.gotDir != "" {
		t.Fatalf("launcher não deveria ser chamado: machine=%q dir=%q", f.gotMachine, f.gotDir)
	}
}

func TestPostCodeServerOmittedOrEmptyDirUsesHome(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
	}{
		{name: "omitted", body: `{}`},
		{name: "empty", body: `{"dir":""}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newCodeServerFake()
			f.result = session.CodeServer{URL: "https://macbook.example.ts.net", State: "running"}

			rec := doCodeServer(t, f, true, tc.body)
			if rec.Code != http.StatusOK {
				t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
			}
			if f.gotMachine != "macbook" || f.gotDir != "" {
				t.Fatalf("launcher deveria receber HOME implícito: machine=%q dir=%q", f.gotMachine, f.gotDir)
			}
		})
	}
}

func TestPostCodeServerInvalidJSONReturnsBadRequest(t *testing.T) {
	f := newCodeServerFake()
	rec := doCodeServer(t, f, true, `{"dir":`)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, esperava 400: %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"error":"bad_request"`) {
		t.Fatalf("erro = %s, esperava bad_request", rec.Body.String())
	}
	if f.gotMachine != "" || f.gotDir != "" {
		t.Fatalf("launcher não deveria ser chamado: machine=%q dir=%q", f.gotMachine, f.gotDir)
	}
}

func TestPostCodeServerUnknownMachineReturnsNotFound(t *testing.T) {
	f := newCodeServerFake()
	f.err = launcher.ErrUnknownMachine

	rec := doCodeServer(t, f, true, `{"dir":"/workspace/project"}`)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404: %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"error":"unknown_machine"`) {
		t.Fatalf("erro = %s, esperava unknown_machine", rec.Body.String())
	}
}

func TestPostCodeServerStartFailureReturnsBadGateway(t *testing.T) {
	f := newCodeServerFake()
	f.err = errors.New("code-server exited with status 1")

	rec := doCodeServer(t, f, true, `{"dir":"/workspace/project"}`)
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status %d, esperava 502: %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"error":"code_server_failed"`) {
		t.Fatalf("erro = %s, esperava code_server_failed", rec.Body.String())
	}
}
