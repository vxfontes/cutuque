package server

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/devices"
)

// validToken64 é um device token de exemplo (64 hex chars, como um real).
const validToken64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func postDevices(t *testing.T, store *devices.Store, body string) *httptest.ResponseRecorder {
	t.Helper()
	cfg, reg := testDeps()
	req := httptest.NewRequest(http.MethodPost, "/devices", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil, WithDevices(store)).ServeHTTP(rec, req)
	return rec
}

func TestRegisterDeviceOK(t *testing.T) {
	store := devices.New()
	rec := postDevices(t, store, `{"token":"`+validToken64+`","platform":"ios"}`)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if got := store.List(); len(got) != 1 || got[0].Token != validToken64 {
		t.Errorf("device não registrado no store: %+v", got)
	}
}

func TestRegisterDeviceRejectsNonHexToken(t *testing.T) {
	store := devices.New()
	// 64 chars mas com um 'z' inválido.
	tok := "z123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	rec := postDevices(t, store, `{"token":"`+tok+`","platform":"ios"}`)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, quero 400 para token não-hex", rec.Code)
	}
	if len(store.List()) != 0 {
		t.Error("token inválido foi registrado")
	}
}

func TestRegisterDeviceRejectsShortToken(t *testing.T) {
	store := devices.New()
	rec := postDevices(t, store, `{"token":"abcd","platform":"ios"}`) // < 32 chars

	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, quero 400 para token curto", rec.Code)
	}
}

func TestRegisterDeviceRejectsEmptyPlatform(t *testing.T) {
	store := devices.New()
	rec := postDevices(t, store, `{"token":"`+validToken64+`","platform":""}`)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, quero 400 para platform vazio", rec.Code)
	}
}

func TestRegisterDeviceRequiresAuth(t *testing.T) {
	cfg, reg := testDeps()
	store := devices.New()
	req := httptest.NewRequest(http.MethodPost, "/devices",
		strings.NewReader(`{"token":"`+validToken64+`","platform":"ios"}`))
	// sem header Authorization
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil, WithDevices(store)).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, quero 401 sem token", rec.Code)
	}
}
