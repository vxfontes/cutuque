package apns

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"time"
)

// ecP256ScalarSize é o tamanho em bytes de cada componente (r, s) da assinatura
// numa curva P-256. A assinatura JWS ES256 é a concatenação crua r‖s, cada um
// com padding à esquerda para exatamente 32 bytes (RFC 7518 §3.4).
const ecP256ScalarSize = 32

// jwtHeader é o cabeçalho do provider token da Apple: algoritmo ES256 e o Key ID
// da chave .p8 (a Apple usa o kid para localizar a chave pública correspondente).
type jwtHeader struct {
	Alg string `json:"alg"`
	Kid string `json:"kid"`
}

// jwtClaims são os claims mínimos exigidos pela APNs: o Team ID como emissor e o
// instante de emissão. A Apple rejeita tokens com iat de mais de 1h.
type jwtClaims struct {
	Iss string `json:"iss"`
	Iat int64  `json:"iat"`
}

// signJWT assina um provider token ES256 para a APNs com a chave ECDSA P-256.
// iat é o instante de emissão (injetado para tornar o cache testável).
func signJWT(key *ecdsa.PrivateKey, keyID, teamID string, iat time.Time) (string, error) {
	headerJSON, err := json.Marshal(jwtHeader{Alg: "ES256", Kid: keyID})
	if err != nil {
		return "", fmt.Errorf("apns: marshal header do jwt: %w", err)
	}
	claimsJSON, err := json.Marshal(jwtClaims{Iss: teamID, Iat: iat.Unix()})
	if err != nil {
		return "", fmt.Errorf("apns: marshal claims do jwt: %w", err)
	}

	enc := base64.RawURLEncoding
	signingInput := enc.EncodeToString(headerJSON) + "." + enc.EncodeToString(claimsJSON)

	// ES256 = ECDSA sobre P-256 com SHA-256 do signing input.
	digest := sha256.Sum256([]byte(signingInput))
	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		return "", fmt.Errorf("apns: assinar jwt: %w", err)
	}

	return signingInput + "." + enc.EncodeToString(encodeES256Signature(r, s)), nil
}

// encodeES256Signature serializa (r, s) no formato cru r‖s de 64 bytes exigido
// pelo JWS (não o DER usado por ecdsa.SignASN1). FillBytes preenche à esquerda
// com zeros, garantindo exatamente 32 bytes por componente.
func encodeES256Signature(r, s *big.Int) []byte {
	out := make([]byte, 2*ecP256ScalarSize)
	r.FillBytes(out[:ecP256ScalarSize])
	s.FillBytes(out[ecP256ScalarSize:])
	return out
}
