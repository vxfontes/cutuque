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
