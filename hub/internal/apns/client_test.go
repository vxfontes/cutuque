package apns

import (
	"context"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// newTestClient monta um Client apontado para um httptest.Server h2, confiando
// no cert dele via ts.Client(). Usa uma chave descartável e um relógio fixo.
func newTestClient(t *testing.T, ts *httptest.Server) *Client {
	t.Helper()
	return &Client{
		http:   ts.Client(),
		key:    newTestKey(t),
		keyID:  "KID",
		teamID: "TEAM",
		topic:  "com.vxfontes.cutuque",
		host:   strings.TrimPrefix(ts.URL, "https://"),
		now:    func() time.Time { return time.Unix(1_700_000_000, 0) },
	}
}

// h2Server sobe um httptest.Server com HTTP/2 habilitado (o cenário real da APNs).
func h2Server(t *testing.T, h http.HandlerFunc) *httptest.Server {
	t.Helper()
	ts := httptest.NewUnstartedServer(h)
	ts.EnableHTTP2 = true
	ts.StartTLS()
	t.Cleanup(ts.Close)
	return ts
}

func TestPushSendsCorrectPathHeadersAndBody(t *testing.T) {
	var (
		gotPath     string
		gotProto    string
		gotAuth     string
		gotTopic    string
		gotPushType string
		gotPrio     string
		gotCollapse string
		gotBody     []byte
	)
	ts := h2Server(t, func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotProto = r.Proto
		gotAuth = r.Header.Get("authorization")
		gotTopic = r.Header.Get("apns-topic")
		gotPushType = r.Header.Get("apns-push-type")
		gotPrio = r.Header.Get("apns-priority")
		gotCollapse = r.Header.Get("apns-collapse-id")
		gotBody, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusOK)
	})
	c := newTestClient(t, ts)

	payload := []byte(`{"aps":{"alert":{"title":"oi"}}}`)
	err := c.Push(context.Background(), "abc123", payload, PushOptions{
		Category: "NEEDS_YOU",
		ThreadID: "sess-1",
	})
	if err != nil {
		t.Fatalf("Push: %v", err)
	}

	if gotPath != "/3/device/abc123" {
		t.Errorf("path = %q, quero /3/device/abc123", gotPath)
	}
	if !strings.HasPrefix(gotProto, "HTTP/2") {
		t.Errorf("proto = %q, quero HTTP/2 (APNs é h2)", gotProto)
	}
	if !strings.HasPrefix(gotAuth, "bearer ") {
		t.Errorf("authorization = %q, quero prefixo 'bearer '", gotAuth)
	}
	if gotTopic != "com.vxfontes.cutuque" {
		t.Errorf("apns-topic = %q", gotTopic)
	}
	if gotPushType != "alert" {
		t.Errorf("apns-push-type = %q, quero alert (default)", gotPushType)
	}
	if gotPrio != "10" {
		t.Errorf("apns-priority = %q, quero 10 (default)", gotPrio)
	}
	if gotCollapse != "sess-1" {
		t.Errorf("apns-collapse-id = %q, quero sess-1 (do ThreadID)", gotCollapse)
	}
	if string(gotBody) != string(payload) {
		t.Errorf("body = %q, quero %q", gotBody, payload)
	}
}

func TestPushOmitsCollapseWhenThreadEmpty(t *testing.T) {
	var gotCollapse string
	ts := h2Server(t, func(w http.ResponseWriter, r *http.Request) {
		gotCollapse = r.Header.Get("apns-collapse-id")
		w.WriteHeader(http.StatusOK)
	})
	c := newTestClient(t, ts)

	if err := c.Push(context.Background(), "tok", []byte(`{}`), PushOptions{}); err != nil {
		t.Fatalf("Push: %v", err)
	}
	if gotCollapse != "" {
		t.Errorf("apns-collapse-id = %q, quero vazio quando ThreadID é vazio", gotCollapse)
	}
}

func TestPushGoneReturnsErrGone(t *testing.T) {
	ts := h2Server(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusGone)
		_, _ = w.Write([]byte(`{"reason":"Unregistered"}`))
	})
	c := newTestClient(t, ts)

	err := c.Push(context.Background(), "tok", []byte(`{}`), PushOptions{})
	if !errors.Is(err, ErrGone) {
		t.Errorf("erro = %v, quero ErrGone em 410", err)
	}
}

func TestPushOtherStatusReturnsTypedError(t *testing.T) {
	ts := h2Server(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"reason":"BadDeviceToken"}`))
	})
	c := newTestClient(t, ts)

	err := c.Push(context.Background(), "tok", []byte(`{}`), PushOptions{})
	var apnsErr *APNSError
	if !errors.As(err, &apnsErr) {
		t.Fatalf("erro = %v, quero *APNSError", err)
	}
	if apnsErr.Status != http.StatusBadRequest || apnsErr.Reason != "BadDeviceToken" {
		t.Errorf("APNSError = %+v, quero status 400 reason BadDeviceToken", apnsErr)
	}
}

func TestParseP8KeyRejectsNonECDSA(t *testing.T) {
	// PEM válido mas sem chave EC: garante a mensagem de erro tipada.
	bad := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: []byte("lixo")})
	if _, err := parseP8Key(bad); err == nil {
		t.Error("parseP8Key aceitou bytes inválidos; quero erro")
	}
}

func TestParseP8KeyAcceptsEC(t *testing.T) {
	key := newTestKey(t)
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal pkcs8: %v", err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})

	parsed, err := parseP8Key(pemBytes)
	if err != nil {
		t.Fatalf("parseP8Key: %v", err)
	}
	if !parsed.Equal(key) {
		t.Error("chave parseada difere da original")
	}
}
