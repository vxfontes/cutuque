package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeRenudge implementa RenudgeController para os testes.
type fakeRenudge struct {
	mu sync.Mutex
	d  time.Duration
}

func (f *fakeRenudge) RenudgeInterval() time.Duration {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.d
}

func (f *fakeRenudge) SetRenudgeInterval(d time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.d = d
}

func TestSettingsGetReturnsSeconds(t *testing.T) {
	rc := &fakeRenudge{d: 20 * time.Second}
	req := httptest.NewRequest(http.MethodGet, "/settings/renudge", nil)
	rec := httptest.NewRecorder()

	SettingsHandler(rc).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	var b settingsBody
	if err := json.Unmarshal(rec.Body.Bytes(), &b); err != nil {
		t.Fatalf("json inválido: %v", err)
	}
	if b.RenudgeSeconds != 20 {
		t.Errorf("renudge_seconds = %d, quero 20", b.RenudgeSeconds)
	}
}

func TestSettingsPutValidUpdates(t *testing.T) {
	rc := &fakeRenudge{d: 15 * time.Second}
	req := httptest.NewRequest(http.MethodPut, "/settings/renudge", strings.NewReader(`{"renudge_seconds":30}`))
	rec := httptest.NewRecorder()

	SettingsHandler(rc).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if got := rc.RenudgeInterval(); got != 30*time.Second {
		t.Errorf("intervalo = %v, quero 30s", got)
	}
}

func TestSettingsPutOutOfRangeRejected(t *testing.T) {
	for _, secs := range []int{4, 601, 0, -5} {
		rc := &fakeRenudge{d: 15 * time.Second}
		body := `{"renudge_seconds":` + itoa(secs) + `}`
		req := httptest.NewRequest(http.MethodPut, "/settings/renudge", strings.NewReader(body))
		rec := httptest.NewRecorder()

		SettingsHandler(rc).ServeHTTP(rec, req)

		if rec.Code != http.StatusBadRequest {
			t.Errorf("secs=%d: status = %d, quero 400", secs, rec.Code)
		}
		if got := rc.RenudgeInterval(); got != 15*time.Second {
			t.Errorf("secs=%d: intervalo mudou para %v (não devia)", secs, got)
		}
	}
}

func TestSettingsPutBadJSON(t *testing.T) {
	rc := &fakeRenudge{d: 15 * time.Second}
	req := httptest.NewRequest(http.MethodPut, "/settings/renudge", strings.NewReader(`nao-json`))
	rec := httptest.NewRecorder()

	SettingsHandler(rc).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, quero 400", rec.Code)
	}
}

// itoa evita importar strconv só para o teste de tabela.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [12]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
