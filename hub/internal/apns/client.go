// Package apns é um cliente mínimo do APNs provider API (HTTP/2 + JWT ES256),
// sem dependências externas: o http.Client padrão já negocia h2 via ALPN sobre
// TLS. Assina o provider token a partir da chave .p8 (PKCS8/ECDSA P-256) e o
// mantém em cache, reassinando só perto de expirar (a Apple rejeita tokens de
// mais de 1h e faz throttle de reassinaturas frequentes). Ver docs/11-apns.md.
package apns

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/config"
)

// ErrGone é devolvido quando a APNs responde 410 Unregistered: o device token
// não é mais válido (app desinstalado, etc.) e deve ser removido do store.
var ErrGone = errors.New("apns: device token não registrado (410 Unregistered)")

// tokenRefresh é a idade a partir da qual o provider token é reassinado. Bem
// abaixo do limite de 1h da Apple, e alto o suficiente para não reassinar a cada
// push (a Apple faz throttle de reassinaturas muito frequentes).
const tokenRefresh = 50 * time.Minute

// PushOptions controla os headers e metadados de um push. Category e ThreadID
// espelham campos que o Notifier também coloca no payload (aps.category /
// aps.thread-id); no nível de header, ThreadID vira o apns-collapse-id opcional
// e Category é informativo (a APNs não tem header de categoria).
type PushOptions struct {
	Category string // categoria da notificação (informativo; vai no payload)
	ThreadID string // se não-vazio, vira apns-collapse-id (colapsa notificações)
	Priority int    // apns-priority; 0 assume 10 (entrega imediata)
	PushType string // apns-push-type; vazio assume "alert"
}

// APNSError é um erro tipado para respostas não-2xx que não sejam 410. Carrega o
// status HTTP e o reason textual devolvido pela APNs, útil para diagnóstico.
type APNSError struct {
	Status int
	Reason string
}

func (e *APNSError) Error() string {
	return fmt.Sprintf("apns: status %d (%s)", e.Status, e.Reason)
}

// Client envia pushes para a APNs. É seguro para uso concorrente.
type Client struct {
	http   *http.Client
	key    *ecdsa.PrivateKey
	keyID  string
	teamID string
	topic  string
	host   string
	now    func() time.Time // injetável para tornar o cache do token testável

	mu            sync.Mutex
	cachedToken   string
	tokenIssuedAt time.Time
}

// NewClient carrega a chave .p8 do caminho em cfg e monta o cliente. Erra se a
// chave não puder ser lida/parseada ou não for uma chave ECDSA (P-256). Só deve
// ser chamado quando cfg.APNSEnabled(); o caller decide subir o Notifier ou não.
func NewClient(cfg config.Config) (*Client, error) {
	pemBytes, err := os.ReadFile(cfg.APNSKeyPath)
	if err != nil {
		return nil, fmt.Errorf("apns: ler chave em %q: %w", cfg.APNSKeyPath, err)
	}
	key, err := parseP8Key(pemBytes)
	if err != nil {
		return nil, err
	}
	return &Client{
		http:   &http.Client{}, // http.DefaultTransport negocia h2 via ALPN
		key:    key,
		keyID:  cfg.APNSKeyID,
		teamID: cfg.APNSTeamID,
		topic:  cfg.APNSTopic,
		host:   cfg.APNSHost,
		now:    time.Now,
	}, nil
}

// parseP8Key decodifica um PEM PKCS8 e extrai a chave ECDSA (as chaves APNs .p8
// da Apple são EC P-256). Nunca loga o conteúdo da chave.
func parseP8Key(pemBytes []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("apns: .p8 não contém bloco PEM válido")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("apns: parse PKCS8 da chave: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("apns: chave não é ECDSA (é %T)", parsed)
	}
	return key, nil
}

// bearerToken devolve o provider token, reassinando se o cache estiver vazio ou
// velho demais (>= tokenRefresh). Seguro para chamadas concorrentes.
func (c *Client) bearerToken() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	now := c.now()
	if c.cachedToken == "" || now.Sub(c.tokenIssuedAt) >= tokenRefresh {
		tok, err := signJWT(c.key, c.keyID, c.teamID, now)
		if err != nil {
			return "", err
		}
		c.cachedToken = tok
		c.tokenIssuedAt = now
	}
	return c.cachedToken, nil
}

// Push envia payload (JSON já montado) ao device token via POST /3/device/<token>.
// 200 → nil; 410 → ErrGone (remover o device); demais → *APNSError.
func (c *Client) Push(ctx context.Context, deviceToken string, payload []byte, opts PushOptions) error {
	tok, err := c.bearerToken()
	if err != nil {
		return err
	}

	url := "https://" + c.host + "/3/device/" + deviceToken
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("apns: montar request: %w", err)
	}

	pushType := opts.PushType
	if pushType == "" {
		pushType = "alert"
	}
	priority := opts.Priority
	if priority == 0 {
		priority = 10
	}
	// Live Activity usa um topic dedicado (<bundle>.push-type.liveactivity).
	topic := c.topic
	if pushType == "liveactivity" {
		topic = c.topic + ".push-type.liveactivity"
	}
	req.Header.Set("authorization", "bearer "+tok)
	req.Header.Set("apns-topic", topic)
	req.Header.Set("apns-push-type", pushType)
	req.Header.Set("apns-priority", strconv.Itoa(priority))
	if opts.ThreadID != "" {
		req.Header.Set("apns-collapse-id", opts.ThreadID)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("apns: enviar push: %w", err)
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusOK:
		return nil
	case http.StatusGone:
		return ErrGone
	default:
		return &APNSError{Status: resp.StatusCode, Reason: readReason(resp.Body)}
	}
}

// readReason extrai o campo "reason" do corpo de erro da APNs (best-effort).
func readReason(body io.Reader) string {
	raw, err := io.ReadAll(io.LimitReader(body, 4*1024))
	if err != nil || len(raw) == 0 {
		return ""
	}
	var parsed struct {
		Reason string `json:"reason"`
	}
	if json.Unmarshal(raw, &parsed) == nil && parsed.Reason != "" {
		return parsed.Reason
	}
	return string(raw)
}
