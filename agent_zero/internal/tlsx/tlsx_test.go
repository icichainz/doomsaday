package tlsx

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGeneratesSelfSignedECDSA(t *testing.T) {
	dir := t.TempDir()
	certPath := filepath.Join(dir, "cert.pem")
	keyPath := filepath.Join(dir, "key.pem")

	m, err := Load(certPath, keyPath, true)
	if err != nil {
		t.Fatal(err)
	}
	if !m.SelfSigned {
		t.Fatal("SelfSigned is false")
	}

	leaf, err := x509.ParseCertificate(m.Certificate.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := leaf.PublicKey.(*ecdsa.PublicKey); !ok {
		t.Fatalf("public key is %T, want ECDSA", leaf.PublicKey)
	}
	if !contains(leaf.DNSNames, "localhost") {
		t.Fatalf("DNS names = %v", leaf.DNSNames)
	}

	sum := sha256.Sum256(m.Certificate.Certificate[0])
	want := formatFingerprint(sum[:])
	if m.Fingerprint != want {
		t.Fatalf("fingerprint = %q, want %q", m.Fingerprint, want)
	}
	if len(strings.Split(m.Fingerprint, ":")) != 32 {
		t.Fatalf("fingerprint %q is not 32 colon separated bytes", m.Fingerprint)
	}

	info, err := os.Stat(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("key file mode = %o, want 600", info.Mode().Perm())
	}
}

func TestExistingMaterialIsReused(t *testing.T) {
	dir := t.TempDir()
	certPath := filepath.Join(dir, "cert.pem")
	keyPath := filepath.Join(dir, "key.pem")

	first, err := Load(certPath, keyPath, true)
	if err != nil {
		t.Fatal(err)
	}
	second, err := Load(certPath, keyPath, true)
	if err != nil {
		t.Fatal(err)
	}
	if first.Fingerprint != second.Fingerprint {
		t.Fatal("restarting regenerated the certificate, which would break pinning")
	}
}

func TestMissingSuppliedCertificateIsAnError(t *testing.T) {
	dir := t.TempDir()
	if _, err := Load(filepath.Join(dir, "nope.pem"), filepath.Join(dir, "nope.key"), false); err == nil {
		t.Fatal("a missing supplied certificate was accepted")
	}
}

func TestServerConfigIsModern(t *testing.T) {
	dir := t.TempDir()
	m, err := Load(filepath.Join(dir, "c.pem"), filepath.Join(dir, "k.pem"), true)
	if err != nil {
		t.Fatal(err)
	}
	cfg := ServerConfig(m)
	if cfg.MinVersion < 0x0303 {
		t.Fatalf("min TLS version = %x, want at least TLS 1.2", cfg.MinVersion)
	}
	if len(cfg.Certificates) != 1 {
		t.Fatal("no certificate in the config")
	}
}

func contains(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}
