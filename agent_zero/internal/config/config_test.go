package config

import (
	"strings"
	"testing"
)

func TestDefaults(t *testing.T) {
	c, err := Parse(nil)
	if err != nil {
		t.Fatal(err)
	}
	if c.Listen != ":8443" {
		t.Fatalf("listen = %q, want :8443", c.Listen)
	}
	if c.InsecureHTTP {
		t.Fatal("TLS is not on by default")
	}
	if c.LogLevel != "info" {
		t.Fatalf("log level = %q", c.LogLevel)
	}
}

func TestEnvironmentIsUsedAsTheDefault(t *testing.T) {
	t.Setenv("AGENT_ZERO_LISTEN", ":9999")
	t.Setenv("AGENT_ZERO_DATA_DIR", "/tmp/agentzero-test-data")
	t.Setenv("AGENT_ZERO_INSECURE_HTTP", "true")

	c, err := Parse(nil)
	if err != nil {
		t.Fatal(err)
	}
	if c.Listen != ":9999" || c.DataDir != "/tmp/agentzero-test-data" || !c.InsecureHTTP {
		t.Fatalf("config = %+v", c)
	}
}

func TestFlagsBeatTheEnvironment(t *testing.T) {
	t.Setenv("AGENT_ZERO_LISTEN", ":9999")
	c, err := Parse([]string{"--listen", ":7777"})
	if err != nil {
		t.Fatal(err)
	}
	if c.Listen != ":7777" {
		t.Fatalf("listen = %q", c.Listen)
	}
}

func TestValidation(t *testing.T) {
	for _, tc := range []struct {
		name string
		args []string
		want string
	}{
		{"empty listen", []string{"--listen", ""}, "listen"},
		{"cert without key", []string{"--tls-cert", "/tmp/c.pem"}, "together"},
		{"insecure with cert", []string{"--insecure-http", "--tls-cert", "/a", "--tls-key", "/b"}, "insecure-http"},
		{"bad log level", []string{"--log-level", "shout"}, "log level"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Parse(tc.args)
			if err == nil {
				t.Fatalf("%v was accepted", tc.args)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %q does not mention %q", err, tc.want)
			}
		})
	}
}

func TestPathsAreDerivedFromTheDataDir(t *testing.T) {
	c, err := Parse([]string{"--data-dir", "/tmp/agentzero-test-dd"})
	if err != nil {
		t.Fatal(err)
	}
	for _, got := range []string{c.DBPath(), c.SecretKeyPath(), c.CertPath(), c.KeyPath()} {
		if !strings.HasPrefix(got, "/tmp/agentzero-test-dd/") {
			t.Fatalf("%q is not inside the data dir", got)
		}
	}
}
