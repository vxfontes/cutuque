package machine

import (
	"bytes"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
)

// Estes testes travam os dois invariantes de secret.go que protegem a senha
// guardada: (1) sem CUTUQUE_IDENTITY_KEY o hub recusa cifrar em vez de gravar
// em claro, e (2) o que foi cifrado só abre com a MESMA chave e sem nenhuma
// adulteração — GCM é AEAD, então um byte trocado vira erro, nunca uma senha
// diferente e silenciosa.

// chave32 gera uma chave válida em base64 (32 bytes) para os testes de
// round-trip. Não usa crypto/rand por padrão para o teste ser determinístico
// e legível — o valor não protege nada de verdade aqui.
func chave32(b byte) string {
	buf := bytes.Repeat([]byte{b}, secretKeyBytes)
	return base64.StdEncoding.EncodeToString(buf)
}

func TestNewSecretBoxSemChaveDevolveErrNoSecretKey(t *testing.T) {
	_, err := newSecretBox("")
	if !errors.Is(err, ErrNoSecretKey) {
		t.Fatalf("erro = %v, esperava ErrNoSecretKey", err)
	}
	// Espaços em branco também contam como "ausente" — strings.TrimSpace no
	// início de newSecretBox existe para o CUTUQUE_IDENTITY_KEY vindo do
	// ambiente com quebra de linha (comum em `.env`) não virar chave inválida.
	_, err = newSecretBox("   \n")
	if !errors.Is(err, ErrNoSecretKey) {
		t.Fatalf("chave só de espaço: erro = %v, esperava ErrNoSecretKey", err)
	}
}

func TestNewSecretBoxBase64Invalido(t *testing.T) {
	_, err := newSecretBox("isto não é base64 !!!")
	if err == nil {
		t.Fatal("aceitou string que não é base64")
	}
	if errors.Is(err, ErrNoSecretKey) {
		t.Error("base64 inválido não pode ser confundido com chave ausente — são dois avisos diferentes para a usuária")
	}
}

// Tamanho errado depois do base64 (16, 31, 33 bytes) tem que ser recusado —
// só 32 bytes é AES-256. A mensagem deve orientar como gerar a chave certa.
func TestNewSecretBoxTamanhoErrado(t *testing.T) {
	tamanhos := []int{16, 31, 33}
	for _, n := range tamanhos {
		keyB64 := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x42}, n))
		_, err := newSecretBox(keyB64)
		if err == nil {
			t.Fatalf("chave de %d bytes foi aceita", n)
		}
		if errors.Is(err, ErrNoSecretKey) {
			t.Errorf("chave de %d bytes: não pode virar ErrNoSecretKey (existe, só está errada)", n)
		}
		if !strings.Contains(err.Error(), "openssl rand -base64 32") {
			t.Errorf("chave de %d bytes: mensagem não orienta como gerar a chave certa: %v", n, err)
		}
	}
}

// Round-trip seal/open com variações de conteúdo: ascii, acento+emoji (bytes
// multibyte no meio do plaintext), senha de 1 caractere e uma senha grande
// (perto do que um gerenciador de senha exportaria).
func TestSealOpenRoundTrip(t *testing.T) {
	box, err := newSecretBox(chave32(0x01))
	if err != nil {
		t.Fatalf("newSecretBox: %v", err)
	}

	longa := strings.Repeat("Sxp3-quatro-kb-", 300) // ~4.5KB
	casos := map[string]string{
		"ascii":        "senha-simples-123",
		"acento+emoji": "sénhá-com-açentõ-🔒🐙-e-mais-🚀",
		"um-caractere": "x",
		"longa":        longa,
	}
	for nome, plain := range casos {
		t.Run(nome, func(t *testing.T) {
			ct, err := box.seal(plain)
			if err != nil {
				t.Fatalf("seal: %v", err)
			}
			got, err := box.open(ct)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			if got != plain {
				t.Errorf("round-trip mudou o conteúdo:\nqueria %q\nveio   %q", plain, got)
			}
		})
	}
}

// O nonce é aleatório por gravação: duas cifragens da MESMA senha têm que
// produzir ciphertexts DIFERENTES. Sem isso, dois hosts com a mesma senha
// ficariam visivelmente iguais no arquivo em /data — um vazamento de metadado
// que o desenho existe para evitar.
func TestSealMesmaSenhaDuasVezesProduzCiphertextsDiferentes(t *testing.T) {
	box, err := newSecretBox(chave32(0x02))
	if err != nil {
		t.Fatalf("newSecretBox: %v", err)
	}
	ct1, err := box.seal("mesma-senha")
	if err != nil {
		t.Fatalf("seal 1: %v", err)
	}
	ct2, err := box.seal("mesma-senha")
	if err != nil {
		t.Fatalf("seal 2: %v", err)
	}
	if bytes.Equal(ct1, ct2) {
		t.Error("duas cifragens da mesma senha produziram o mesmo ciphertext — o nonce não está variando")
	}
	// Mas as duas continuam abrindo para o mesmo texto.
	p1, err := box.open(ct1)
	if err != nil || p1 != "mesma-senha" {
		t.Fatalf("open(ct1) = %q, %v", p1, err)
	}
	p2, err := box.open(ct2)
	if err != nil || p2 != "mesma-senha" {
		t.Fatalf("open(ct2) = %q, %v", p2, err)
	}
}

// Ciphertext adulterado (um bit virado no meio) tem que virar ErrSecretUnreadable
// — nunca uma senha diferente entregue em silêncio. É a propriedade central de
// AEAD: adulteração é detectada, não decodificada.
func TestOpenCiphertextAdulteradoDaErro(t *testing.T) {
	box, err := newSecretBox(chave32(0x03))
	if err != nil {
		t.Fatalf("newSecretBox: %v", err)
	}
	ct, err := box.seal("senha-que-nao-pode-vazar-trocada")
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	if len(ct) == 0 {
		t.Fatal("ciphertext vazio")
	}
	adulterado := bytes.Clone(ct)
	meio := len(adulterado) / 2
	adulterado[meio] ^= 0xFF // vira um byte do meio (dentro do ciphertext, depois do nonce)

	_, err = box.open(adulterado)
	if !errors.Is(err, ErrSecretUnreadable) {
		t.Fatalf("erro = %v, esperava ErrSecretUnreadable", err)
	}
}

// Ciphertext truncado (menor que o nonce) não pode nem tentar decifrar — tem
// que recusar de cara.
func TestOpenCiphertextTruncadoDaErro(t *testing.T) {
	box, err := newSecretBox(chave32(0x04))
	if err != nil {
		t.Fatalf("newSecretBox: %v", err)
	}
	ct, err := box.seal("qualquer-coisa")
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	truncado := ct[:len(ct)/4] // bem menor que o nonce (12 bytes do GCM padrão)
	if len(truncado) >= box.aead.NonceSize() {
		truncado = truncado[:box.aead.NonceSize()-1]
	}
	_, err = box.open(truncado)
	if !errors.Is(err, ErrSecretUnreadable) {
		t.Fatalf("erro = %v, esperava ErrSecretUnreadable", err)
	}
}

// Abrir com uma chave DIFERENTE da que selou é o caso mais comum na prática:
// CUTUQUE_IDENTITY_KEY trocada depois de já ter senha guardada.
func TestOpenComChaveDiferenteDaQueSelouDaErro(t *testing.T) {
	boxA, err := newSecretBox(chave32(0x05))
	if err != nil {
		t.Fatalf("newSecretBox A: %v", err)
	}
	boxB, err := newSecretBox(chave32(0x06))
	if err != nil {
		t.Fatalf("newSecretBox B: %v", err)
	}
	ct, err := boxA.seal("senha-da-chave-A")
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	_, err = boxB.open(ct)
	if !errors.Is(err, ErrSecretUnreadable) {
		t.Fatalf("erro = %v, esperava ErrSecretUnreadable (chave trocada)", err)
	}
}
