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

	// Hosts APNs da Apple. Sandbox atende tokens do build de desenvolvimento;
	// prod atende tokens de TestFlight/App Store. Enviar para o host errado
	// devolve 400 BadDeviceToken — por isso o default segue o ambiente.
	apnsHostSandbox = "api.sandbox.push.apple.com"
	apnsHostProd    = "api.push.apple.com"

	// Intervalo padrão do re-cutucão (opção 1): de quanto em quanto tempo o hub
	// reenvia o push enquanto a sessão segue em needs_you. Configurável em runtime
	// pelo app (ver /settings) e no boot via CUTUQUE_RENUDGE_SECONDS.
	defaultRenudgeSeconds = 15
)

// Config é a configuração resolvida do hub.
type Config struct {
	Env      string // "dev" (padrão) ou "prod"
	BindAddr string // endereço IP para escutar
	Port     int
	Token    string // bearer token dos devices ("dev-token" em dev se não definido)

	// APNs (Fase 4). Todos opcionais: o hub sobe normalmente sem eles, só não
	// envia push. A credencial .p8 mora só no hub e nunca é versionada (o dir
	// config/ é gitignored); aqui guardamos apenas o caminho, lido em runtime.
	APNSKeyPath string // caminho do .p8 (CUTUQUE_APNS_KEY_PATH)
	APNSKeyID   string // Key ID da chave APNs (CUTUQUE_APNS_KEY_ID)
	APNSTeamID  string // Team ID da conta Apple Developer (CUTUQUE_APNS_TEAM_ID)
	APNSTopic   string // bundle id do app (CUTUQUE_APNS_TOPIC)
	APNSHost    string // host APNs; default por ambiente (CUTUQUE_APNS_HOST)

	RenudgeSeconds int // intervalo do re-cutucão em needs_you (CUTUQUE_RENUDGE_SECONDS)
}

// APNSEnabled indica se há credencial APNs suficiente para o Notifier subir.
// Exige KeyPath, KeyID, TeamID e Topic; sem qualquer um deles o hub segue sem
// push (o Host sempre tem default, então não entra na checagem).
func (c Config) APNSEnabled() bool {
	return c.APNSKeyPath != "" && c.APNSKeyID != "" &&
		c.APNSTeamID != "" && c.APNSTopic != ""
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

	// Host APNs: default segue o ambiente (sandbox em dev, prod em prod), mas
	// CUTUQUE_APNS_HOST sobrescreve (ex.: apontar prod para sandbox num teste).
	apnsHost := apnsHostSandbox
	if env == "prod" {
		apnsHost = apnsHostProd
	}
	if h := os.Getenv("CUTUQUE_APNS_HOST"); h != "" {
		apnsHost = h
	}

	renudge := defaultRenudgeSeconds
	if r := os.Getenv("CUTUQUE_RENUDGE_SECONDS"); r != "" {
		if n, err := strconv.Atoi(r); err == nil && n > 0 {
			renudge = n
		}
	}

	return Config{
		Env:      env,
		BindAddr: bind,
		Port:     port,
		Token:    token,

		APNSKeyPath: os.Getenv("CUTUQUE_APNS_KEY_PATH"),
		APNSKeyID:   os.Getenv("CUTUQUE_APNS_KEY_ID"),
		APNSTeamID:  os.Getenv("CUTUQUE_APNS_TEAM_ID"),
		APNSTopic:   os.Getenv("CUTUQUE_APNS_TOPIC"),
		APNSHost:    apnsHost,

		RenudgeSeconds: renudge,
	}
}

// Addr retorna o endereço "BindAddr:Port" para o http.Server.
func (c Config) Addr() string {
	return c.BindAddr + ":" + strconv.Itoa(c.Port)
}
