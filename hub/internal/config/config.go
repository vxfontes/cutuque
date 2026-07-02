// Package config carrega a configuração do hub a partir de variáveis de ambiente.
package config

import (
	"os"
	"strconv"
)

const (
	defaultPort       = 8787
	devBindAddr       = "127.0.0.1"
	tailscaleBindAddr = "192.0.2.10"
	// devDefaultToken é o token usado em dev quando CUTUQUE_TOKEN não é definido,
	// para não precisar exportar a env var no desenvolvimento local. Em prod o
	// token é obrigatório e nunca recebe default.
	devDefaultToken = "dev-token"
)

// Config é a configuração resolvida do hub.
type Config struct {
	Env      string // "dev" (padrão) ou "prod"
	BindAddr string // endereço IP para escutar
	Port     int
	Token    string // bearer token dos devices ("dev-token" em dev se não definido)
}

// Load lê as env vars e resolve a configuração.
// CUTUQUE_ENV: "dev" (padrão) ou "prod".
// CUTUQUE_PORT: porta (padrão 8787).
// CUTUQUE_BIND: sobrescreve o BindAddr resolvido por ambiente.
// CUTUQUE_TOKEN: bearer token dos devices. Em dev, se vazio, assume "dev-token".
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

	token := os.Getenv("CUTUQUE_TOKEN")
	if token == "" && env == "dev" {
		token = devDefaultToken
	}

	return Config{
		Env:      env,
		BindAddr: bind,
		Port:     port,
		Token:    token,
	}
}

// Addr retorna o endereço "BindAddr:Port" para o http.Server.
func (c Config) Addr() string {
	return c.BindAddr + ":" + strconv.Itoa(c.Port)
}
