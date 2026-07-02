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
