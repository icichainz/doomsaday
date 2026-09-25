// Package config holds the agent's runtime configuration, built from
// command line flags with AGENT_ZERO_* environment variables as defaults.
package config

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Config is the fully resolved agent configuration.
type Config struct {
	Listen       string
	DataDir      string
	StacksDir    string
	DockerHost   string
	DockerBin    string
	TLSCert      string
	TLSKey       string
	InsecureHTTP bool
	LogLevel     string

	PairTokenTTL time.Duration
	AlertsPeriod time.Duration
}

// Defaults returns the configuration used when nothing is set.
func Defaults() Config {
	return Config{
		Listen:       ":8443",
		DataDir:      "/var/lib/agent_zero",
		StacksDir:    "/opt/stacks",
		DockerBin:    "docker",
		LogLevel:     "info",
		PairTokenTTL: 15 * time.Minute,
		AlertsPeriod: 15 * time.Second,
	}
}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func envBool(key string, def bool) bool {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return def
	}
	return b
}

func envDuration(key string, def time.Duration) time.Duration {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 {
		return def
	}
	return d
}

// Parse builds a Config from the given arguments. The returned FlagSet is
// used by callers that want to print usage.
func Parse(args []string) (Config, error) {
	d := Defaults()
	c := Config{}

	fs := flag.NewFlagSet("agent_zero", flag.ContinueOnError)
	fs.StringVar(&c.Listen, "listen", env("AGENT_ZERO_LISTEN", d.Listen), "listen address (AGENT_ZERO_LISTEN)")
	fs.StringVar(&c.DataDir, "data-dir", env("AGENT_ZERO_DATA_DIR", d.DataDir), "data directory (AGENT_ZERO_DATA_DIR)")
	fs.StringVar(&c.StacksDir, "stacks-dir", env("AGENT_ZERO_STACKS_DIR", d.StacksDir), "compose stacks directory (AGENT_ZERO_STACKS_DIR)")
	fs.StringVar(&c.DockerHost, "docker-host", env("AGENT_ZERO_DOCKER_HOST", ""), "docker host, e.g. unix:///var/run/docker.sock (AGENT_ZERO_DOCKER_HOST)")
	fs.StringVar(&c.DockerBin, "docker-bin", env("AGENT_ZERO_DOCKER_BIN", d.DockerBin), "docker CLI used for compose (AGENT_ZERO_DOCKER_BIN)")
	fs.StringVar(&c.TLSCert, "tls-cert", env("AGENT_ZERO_TLS_CERT", ""), "PEM certificate; self-signed is generated when empty (AGENT_ZERO_TLS_CERT)")
	fs.StringVar(&c.TLSKey, "tls-key", env("AGENT_ZERO_TLS_KEY", ""), "PEM private key (AGENT_ZERO_TLS_KEY)")
	fs.BoolVar(&c.InsecureHTTP, "insecure-http", envBool("AGENT_ZERO_INSECURE_HTTP", false), "serve plain HTTP; local development only (AGENT_ZERO_INSECURE_HTTP)")
	fs.StringVar(&c.LogLevel, "log-level", env("AGENT_ZERO_LOG_LEVEL", d.LogLevel), "debug|info|warn|error (AGENT_ZERO_LOG_LEVEL)")

	fs.SetOutput(os.Stderr)
	if err := fs.Parse(args); err != nil {
		return c, err
	}

	c.PairTokenTTL = envDuration("AGENT_ZERO_PAIR_TOKEN_TTL", d.PairTokenTTL)
	c.AlertsPeriod = envDuration("AGENT_ZERO_ALERTS_PERIOD", d.AlertsPeriod)

	if err := c.validate(); err != nil {
		return c, err
	}
	return c, nil
}

func (c *Config) validate() error {
	if strings.TrimSpace(c.Listen) == "" {
		return errors.New("listen address must not be empty")
	}
	if strings.TrimSpace(c.DataDir) == "" {
		return errors.New("data dir must not be empty")
	}
	abs, err := filepath.Abs(c.DataDir)
	if err != nil {
		return fmt.Errorf("data dir: %w", err)
	}
	c.DataDir = abs
	if c.StacksDir != "" {
		abs, err := filepath.Abs(c.StacksDir)
		if err != nil {
			return fmt.Errorf("stacks dir: %w", err)
		}
		c.StacksDir = abs
	}
	if (c.TLSCert == "") != (c.TLSKey == "") {
		return errors.New("--tls-cert and --tls-key must be given together")
	}
	if c.InsecureHTTP && c.TLSCert != "" {
		return errors.New("--insecure-http cannot be combined with --tls-cert")
	}
	switch c.LogLevel {
	case "debug", "info", "warn", "error":
	default:
		return fmt.Errorf("unknown log level %q", c.LogLevel)
	}
	return nil
}

// DBPath is the bbolt database file.
func (c Config) DBPath() string { return filepath.Join(c.DataDir, "agent_zero.db") }

// SecretKeyPath is the file holding the registry secret encryption key.
func (c Config) SecretKeyPath() string { return filepath.Join(c.DataDir, "secret.key") }

// CertPath is the generated self-signed certificate.
func (c Config) CertPath() string { return filepath.Join(c.DataDir, "agent-cert.pem") }

// KeyPath is the generated self-signed private key.
func (c Config) KeyPath() string { return filepath.Join(c.DataDir, "agent-key.pem") }
