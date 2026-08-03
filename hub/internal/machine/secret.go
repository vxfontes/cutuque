package machine

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"strings"
)

// A senha de uma identidade é guardada CIFRADA em /data, e a chave que a decifra
// vem do ambiente (CUTUQUE_IDENTITY_KEY) — não do disco. A distinção é o que
// muda num vazamento: /data copiado (backup, snapshot, volume exposto) não abre
// nenhuma senha; só abre quem tenha também o hub.env.
//
// O que isto não protege: hub invadido. Um processo rodando como o hub lê a env
// e decifra tudo. Guardar senha foi decisão da usuária em 2026-08-03, ciente
// disso; o dever aqui é não piorar — chave fora do disco, senha fora de log, e
// nenhuma rota que devolva senha.
//
// AES-256-GCM é AEAD: além de esconder, detecta adulteração. Um byte trocado no
// arquivo vira erro, não uma senha diferente.

var (
	// ErrNoSecretKey: pedido para guardar senha sem o hub ter chave para cifrá-la.
	// Recusar é o ponto — gravar em claro seria pior que não guardar.
	ErrNoSecretKey = errors.New("o hub não tem CUTUQUE_IDENTITY_KEY: não guardo senha")
	// ErrSecretUnreadable: o ciphertext não abre com a chave atual. Quase sempre
	// é CUTUQUE_IDENTITY_KEY trocada depois de guardar as senhas.
	ErrSecretUnreadable = errors.New("a senha guardada não decifra com a chave atual do hub")
)

// secretKeyBytes é o tamanho exigido da chave: AES-256.
const secretKeyBytes = 32

// secretBox cifra e decifra as senhas das identidades.
type secretBox struct{ aead cipher.AEAD }

// newSecretBox monta a caixa a partir da chave em base64. Chave ausente devolve
// ErrNoSecretKey (o hub roda sem guardar senha); chave presente mas inválida
// devolve erro de verdade — não dá para "quase" configurar cifra.
func newSecretBox(keyB64 string) (*secretBox, error) {
	keyB64 = strings.TrimSpace(keyB64)
	if keyB64 == "" {
		return nil, ErrNoSecretKey
	}
	key, err := base64.StdEncoding.DecodeString(keyB64)
	if err != nil {
		return nil, fmt.Errorf("CUTUQUE_IDENTITY_KEY não é base64 válido: %w", err)
	}
	if len(key) != secretKeyBytes {
		return nil, fmt.Errorf("CUTUQUE_IDENTITY_KEY precisa ter %d bytes depois do base64 (veio %d) — gere com `openssl rand -base64 32`",
			secretKeyBytes, len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &secretBox{aead: aead}, nil
}

// seal cifra a senha. O nonce vai no começo do resultado: ele não é segredo,
// mas precisa ser único por gravação — daí vir do crypto/rand a cada chamada e
// não de um contador que um restore de backup faria repetir.
func (s *secretBox) seal(plain string) ([]byte, error) {
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	return s.aead.Seal(nonce, nonce, []byte(plain), nil), nil
}

// open decifra. Qualquer falha — curto demais, adulterado, chave trocada — vira
// o mesmo ErrSecretUnreadable: distinguir os casos só ajudaria quem estivesse
// atacando o arquivo.
func (s *secretBox) open(ct []byte) (string, error) {
	n := s.aead.NonceSize()
	if len(ct) < n {
		return "", ErrSecretUnreadable
	}
	plain, err := s.aead.Open(nil, ct[:n], ct[n:], nil)
	if err != nil {
		return "", ErrSecretUnreadable
	}
	return string(plain), nil
}
