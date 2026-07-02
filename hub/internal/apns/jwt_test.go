package apns

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"strings"
	"testing"
	"time"
)

// newTestKey gera uma chave ECDSA P-256 DESCARTÁVEL só para o teste — jamais a
// credencial real da Apple.
func newTestKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("gerar chave de teste: %v", err)
	}
	return key
}

// decodeSegment decodifica um segmento base64url (sem padding) do JWT.
func decodeSegment(t *testing.T, seg string) []byte {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(seg)
	if err != nil {
		t.Fatalf("decode base64url do segmento: %v", err)
	}
	return raw
}

func TestSignJWTHeaderAndClaims(t *testing.T) {
	key := newTestKey(t)
	iat := time.Unix(1_700_000_000, 0)

	tok, err := signJWT(key, "KID123", "TEAM99", iat)
	if err != nil {
		t.Fatalf("signJWT: %v", err)
	}

	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatalf("jwt tem %d partes, quero 3", len(parts))
	}

	var hdr jwtHeader
	if err := json.Unmarshal(decodeSegment(t, parts[0]), &hdr); err != nil {
		t.Fatalf("unmarshal header: %v", err)
	}
	if hdr.Alg != "ES256" {
		t.Errorf("alg = %q, quero ES256", hdr.Alg)
	}
	if hdr.Kid != "KID123" {
		t.Errorf("kid = %q, quero KID123", hdr.Kid)
	}

	var claims jwtClaims
	if err := json.Unmarshal(decodeSegment(t, parts[1]), &claims); err != nil {
		t.Fatalf("unmarshal claims: %v", err)
	}
	if claims.Iss != "TEAM99" {
		t.Errorf("iss = %q, quero TEAM99", claims.Iss)
	}
	if claims.Iat != iat.Unix() {
		t.Errorf("iat = %d, quero %d", claims.Iat, iat.Unix())
	}
}

func TestSignJWTSignatureVerifies(t *testing.T) {
	key := newTestKey(t)
	tok, err := signJWT(key, "KID", "TEAM", time.Unix(1_700_000_000, 0))
	if err != nil {
		t.Fatalf("signJWT: %v", err)
	}

	parts := strings.Split(tok, ".")
	signingInput := parts[0] + "." + parts[1]
	digest := sha256.Sum256([]byte(signingInput))

	sig := decodeSegment(t, parts[2])
	if len(sig) != 2*ecP256ScalarSize {
		t.Fatalf("assinatura tem %d bytes, quero %d (r‖s crus)", len(sig), 2*ecP256ScalarSize)
	}
	r := new(big.Int).SetBytes(sig[:ecP256ScalarSize])
	s := new(big.Int).SetBytes(sig[ecP256ScalarSize:])

	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Error("assinatura ES256 não verifica com a chave pública")
	}
}

func TestBearerTokenCachesUntilRefresh(t *testing.T) {
	key := newTestKey(t)
	base := time.Unix(1_700_000_000, 0)
	cur := base
	c := &Client{key: key, keyID: "KID", teamID: "TEAM", now: func() time.Time { return cur }}

	first, err := c.bearerToken()
	if err != nil {
		t.Fatalf("bearerToken 1: %v", err)
	}

	// Dentro da janela de refresh: mesmo token (não reassina).
	cur = base.Add(49 * time.Minute)
	second, err := c.bearerToken()
	if err != nil {
		t.Fatalf("bearerToken 2: %v", err)
	}
	if first != second {
		t.Error("token reassinado dentro da janela de 50min; deveria vir do cache")
	}

	// Passou da janela: reassina (iat novo → token diferente).
	cur = base.Add(51 * time.Minute)
	third, err := c.bearerToken()
	if err != nil {
		t.Fatalf("bearerToken 3: %v", err)
	}
	if third == second {
		t.Error("token não reassinado após 50min; deveria ter reassinado")
	}
}
