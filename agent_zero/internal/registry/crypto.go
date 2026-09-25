package registry

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// ErrCorrupt is returned when a stored secret cannot be decrypted.
var ErrCorrupt = errors.New("registry: secret could not be decrypted")

// Sealer encrypts and decrypts registry secrets with AES-256-GCM.
type Sealer struct {
	aead cipher.AEAD
}

// LoadOrCreateKey reads the 32 byte key at path, creating it with 0600
// permissions when it does not exist. It refuses a key file that is readable
// by anyone else.
func LoadOrCreateKey(path string) (*Sealer, error) {
	raw, err := os.ReadFile(path)
	switch {
	case err == nil:
		info, statErr := os.Stat(path)
		if statErr == nil && info.Mode().Perm()&0o077 != 0 {
			return nil, fmt.Errorf("registry: key file %s must not be group or world readable (mode %o)", path, info.Mode().Perm())
		}
		if len(raw) != 32 {
			return nil, fmt.Errorf("registry: key file %s must hold exactly 32 bytes", path)
		}
	case errors.Is(err, fs.ErrNotExist):
		if mkErr := os.MkdirAll(filepath.Dir(path), 0o700); mkErr != nil {
			return nil, mkErr
		}
		raw = make([]byte, 32)
		if _, rErr := rand.Read(raw); rErr != nil {
			return nil, rErr
		}
		if wErr := writeFile0600(path, raw); wErr != nil {
			return nil, wErr
		}
	default:
		return nil, err
	}
	return NewSealer(raw)
}

func writeFile0600(path string, raw []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(raw); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// NewSealer builds a Sealer from a 32 byte key.
func NewSealer(key []byte) (*Sealer, error) {
	if len(key) != 32 {
		return nil, errors.New("registry: key must be 32 bytes")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &Sealer{aead: aead}, nil
}

// Seal encrypts plaintext, binding it to the given registry id.
func (s *Sealer) Seal(id, plaintext string) (string, error) {
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	ct := s.aead.Seal(nonce, nonce, []byte(plaintext), []byte(id))
	return base64.StdEncoding.EncodeToString(ct), nil
}

// Open decrypts a value produced by Seal.
func (s *Sealer) Open(id, sealed string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(sealed)
	if err != nil {
		return "", ErrCorrupt
	}
	n := s.aead.NonceSize()
	if len(raw) < n {
		return "", ErrCorrupt
	}
	pt, err := s.aead.Open(nil, raw[:n], raw[n:], []byte(id))
	if err != nil {
		return "", ErrCorrupt
	}
	return string(pt), nil
}
