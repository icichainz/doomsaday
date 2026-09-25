// Package tlsx generates and loads the agent's TLS material.
package tlsx

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"io/fs"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// CertValidity is how long a generated self-signed certificate lasts.
const CertValidity = 10 * 365 * 24 * time.Hour

// Material is a loaded certificate plus the fingerprint the app pins.
type Material struct {
	Certificate tls.Certificate
	Fingerprint string
	SelfSigned  bool
	CertPath    string
	KeyPath     string
}

// Load returns the certificate at certPath/keyPath, generating a self-signed
// ECDSA P-256 certificate there when both files are missing.
func Load(certPath, keyPath string, selfSigned bool) (Material, error) {
	_, certErr := os.Stat(certPath)
	_, keyErr := os.Stat(keyPath)

	if errors.Is(certErr, fs.ErrNotExist) && errors.Is(keyErr, fs.ErrNotExist) && selfSigned {
		if err := generate(certPath, keyPath); err != nil {
			return Material{}, err
		}
	}

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return Material{}, fmt.Errorf("tlsx: load key pair: %w", err)
	}
	if len(cert.Certificate) == 0 {
		return Material{}, errors.New("tlsx: certificate chain is empty")
	}
	sum := sha256.Sum256(cert.Certificate[0])
	return Material{
		Certificate: cert,
		Fingerprint: formatFingerprint(sum[:]),
		SelfSigned:  selfSigned,
		CertPath:    certPath,
		KeyPath:     keyPath,
	}, nil
}

func formatFingerprint(sum []byte) string {
	h := hex.EncodeToString(sum)
	parts := make([]string, 0, len(h)/2)
	for i := 0; i < len(h); i += 2 {
		parts = append(parts, h[i:i+2])
	}
	return strings.ToUpper(strings.Join(parts, ":"))
}

func generate(certPath, keyPath string) error {
	if err := os.MkdirAll(filepath.Dir(certPath), 0o700); err != nil {
		return err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return err
	}
	host, _ := os.Hostname()
	if host == "" {
		host = "agent-zero"
	}
	now := time.Now()
	tmpl := x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: host, Organization: []string{"agent_zero"}},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(CertValidity),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		DNSNames:              dnsNames(host),
		IPAddresses:           localIPs(),
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		return err
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	if err := os.WriteFile(certPath, certPEM, 0o644); err != nil {
		return err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	f, err := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(keyPEM); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func dnsNames(host string) []string {
	names := []string{"localhost"}
	if host != "" && host != "localhost" {
		names = append(names, host)
		if !strings.Contains(host, ".") {
			names = append(names, host+".local")
		}
	}
	return names
}

func localIPs() []net.IP {
	ips := []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ips
	}
	for _, a := range addrs {
		if ipnet, ok := a.(*net.IPNet); ok && !ipnet.IP.IsLoopback() && !ipnet.IP.IsLinkLocalUnicast() {
			ips = append(ips, ipnet.IP)
		}
	}
	return ips
}

// ServerConfig returns a modern TLS configuration for the given material.
func ServerConfig(m Material) *tls.Config {
	return &tls.Config{
		Certificates: []tls.Certificate{m.Certificate},
		MinVersion:   tls.VersionTLS12,
		NextProtos:   []string{"http/1.1"},
	}
}
