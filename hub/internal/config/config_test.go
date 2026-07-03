package config

import "testing"

func TestLoadDefaultsToDevLocalhost(t *testing.T) {
	t.Setenv("CUTUQUE_ENV", "")
	t.Setenv("CUTUQUE_PORT", "")
	t.Setenv("CUTUQUE_BIND", "")

	c := Load()

	if c.Env != "dev" {
		t.Errorf("Env = %q, quero \"dev\"", c.Env)
	}
	if c.BindAddr != "127.0.0.1" {
		t.Errorf("BindAddr = %q, quero \"127.0.0.1\"", c.BindAddr)
	}
	if c.Port != 8787 {
		t.Errorf("Port = %d, quero 8787", c.Port)
	}
	if got := c.Addr(); got != "127.0.0.1:8787" {
		t.Errorf("Addr() = %q, quero \"127.0.0.1:8787\"", got)
	}
}

func TestLoadProdBindsTailscale(t *testing.T) {
	t.Setenv("CUTUQUE_ENV", "prod")
	t.Setenv("CUTUQUE_PORT", "")
	t.Setenv("CUTUQUE_BIND", "")

	c := Load()

	if c.BindAddr != "192.0.2.10" {
		t.Errorf("BindAddr = %q, quero \"192.0.2.10\"", c.BindAddr)
	}
}

func TestLoadExplicitBindOverrides(t *testing.T) {
	t.Setenv("CUTUQUE_ENV", "prod")
	t.Setenv("CUTUQUE_BIND", "0.0.0.0")

	if c := Load(); c.BindAddr != "0.0.0.0" {
		t.Errorf("BindAddr = %q, quero \"0.0.0.0\"", c.BindAddr)
	}
}

func TestLoadDevDefaultsToken(t *testing.T) {
	t.Setenv("CUTUQUE_ENV", "dev")
	t.Setenv("CUTUQUE_TOKEN", "")

	if c := Load(); c.Token != "dev-token" {
		t.Errorf("Token = %q, quero \"dev-token\"", c.Token)
	}
}

func TestLoadDevRespectsExplicitToken(t *testing.T) {
	t.Setenv("CUTUQUE_ENV", "dev")
	t.Setenv("CUTUQUE_TOKEN", "meu-token")

	if c := Load(); c.Token != "meu-token" {
		t.Errorf("Token = %q, quero \"meu-token\"", c.Token)
	}
}

func TestLoadProdEmptyTokenStaysEmpty(t *testing.T) {
	t.Setenv("CUTUQUE_ENV", "prod")
	t.Setenv("CUTUQUE_TOKEN", "")

	if c := Load(); c.Token != "" {
		t.Errorf("Token = %q, quero vazio (prod exige token explícito)", c.Token)
	}
}

// clearAPNSEnv zera todas as env vars de APNs para o teste não herdar valores
// reais do ambiente (config/apns.env pode estar sourced no shell da dev).
func clearAPNSEnv(t *testing.T) {
	t.Helper()
	for _, k := range []string{
		"CUTUQUE_APNS_KEY_PATH", "CUTUQUE_APNS_KEY_ID",
		"CUTUQUE_APNS_TEAM_ID", "CUTUQUE_APNS_TOPIC", "CUTUQUE_APNS_HOST",
	} {
		t.Setenv(k, "")
	}
}

func TestLoadAPNSFromEnv(t *testing.T) {
	clearAPNSEnv(t)
	t.Setenv("CUTUQUE_APNS_KEY_PATH", "config/key.p8")
	t.Setenv("CUTUQUE_APNS_KEY_ID", "ABC123")
	t.Setenv("CUTUQUE_APNS_TEAM_ID", "TEAM99")
	t.Setenv("CUTUQUE_APNS_TOPIC", "com.vxfontes.cutuque")

	c := Load()

	if c.APNSKeyPath != "config/key.p8" {
		t.Errorf("APNSKeyPath = %q", c.APNSKeyPath)
	}
	if c.APNSKeyID != "ABC123" {
		t.Errorf("APNSKeyID = %q", c.APNSKeyID)
	}
	if c.APNSTeamID != "TEAM99" {
		t.Errorf("APNSTeamID = %q", c.APNSTeamID)
	}
	if c.APNSTopic != "com.vxfontes.cutuque" {
		t.Errorf("APNSTopic = %q", c.APNSTopic)
	}
}

func TestAPNSHostDefaultsSandboxInDev(t *testing.T) {
	clearAPNSEnv(t)
	t.Setenv("CUTUQUE_ENV", "dev")

	if c := Load(); c.APNSHost != "api.sandbox.push.apple.com" {
		t.Errorf("APNSHost = %q, quero sandbox em dev", c.APNSHost)
	}
}

func TestAPNSHostDefaultsProdInProd(t *testing.T) {
	clearAPNSEnv(t)
	t.Setenv("CUTUQUE_ENV", "prod")

	if c := Load(); c.APNSHost != "api.push.apple.com" {
		t.Errorf("APNSHost = %q, quero prod em prod", c.APNSHost)
	}
}

func TestAPNSHostExplicitOverrides(t *testing.T) {
	clearAPNSEnv(t)
	t.Setenv("CUTUQUE_ENV", "prod")
	t.Setenv("CUTUQUE_APNS_HOST", "api.sandbox.push.apple.com")

	if c := Load(); c.APNSHost != "api.sandbox.push.apple.com" {
		t.Errorf("APNSHost = %q, quero override explícito", c.APNSHost)
	}
}

func TestAPNSEnabledRequiresAllFields(t *testing.T) {
	clearAPNSEnv(t)
	t.Setenv("CUTUQUE_APNS_KEY_PATH", "config/key.p8")
	t.Setenv("CUTUQUE_APNS_KEY_ID", "ABC123")
	t.Setenv("CUTUQUE_APNS_TEAM_ID", "TEAM99")
	// falta o topic

	if c := Load(); c.APNSEnabled() {
		t.Error("APNSEnabled() = true faltando o topic; quero false")
	}
}

func TestAPNSEnabledTrueWhenComplete(t *testing.T) {
	clearAPNSEnv(t)
	t.Setenv("CUTUQUE_APNS_KEY_PATH", "config/key.p8")
	t.Setenv("CUTUQUE_APNS_KEY_ID", "ABC123")
	t.Setenv("CUTUQUE_APNS_TEAM_ID", "TEAM99")
	t.Setenv("CUTUQUE_APNS_TOPIC", "com.vxfontes.cutuque")

	if c := Load(); !c.APNSEnabled() {
		t.Error("APNSEnabled() = false com todos os campos; quero true")
	}
}

func TestAPNSDisabledByDefault(t *testing.T) {
	clearAPNSEnv(t)

	if c := Load(); c.APNSEnabled() {
		t.Error("APNSEnabled() = true sem nenhuma env APNs; quero false (hub sobe sem APNs)")
	}
}

func TestLoadMaxSessionsDefaultsTo20(t *testing.T) {
	t.Setenv("CUTUQUE_MAX_SESSIONS", "")

	if c := Load(); c.MaxSessions != 20 {
		t.Errorf("MaxSessions = %d, quero 20 (default)", c.MaxSessions)
	}
}

func TestLoadMaxSessionsFromEnv(t *testing.T) {
	t.Setenv("CUTUQUE_MAX_SESSIONS", "5")

	if c := Load(); c.MaxSessions != 5 {
		t.Errorf("MaxSessions = %d, quero 5", c.MaxSessions)
	}
}

func TestLoadMaxSessionsIgnoresInvalidOrNonPositive(t *testing.T) {
	for _, v := range []string{"não-é-número", "0", "-3"} {
		t.Run(v, func(t *testing.T) {
			t.Setenv("CUTUQUE_MAX_SESSIONS", v)
			if c := Load(); c.MaxSessions != 20 {
				t.Errorf("MaxSessions = %d com CUTUQUE_MAX_SESSIONS=%q, quero default 20", c.MaxSessions, v)
			}
		})
	}
}
