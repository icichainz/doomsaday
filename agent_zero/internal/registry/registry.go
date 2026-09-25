// Package registry stores registry credentials. Secrets are encrypted at
// rest and are never returned by any endpoint: the only way out of this
// package is Credential, used when pulling an image.
package registry

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sort"
	"strings"
	"time"

	"agent_zero/internal/store"
)

// Errors returned by this package.
var (
	ErrNotFound = errors.New("registry: not found")
	ErrInvalid  = errors.New("registry: invalid input")
)

// Registry is a stored credential. The sealed secret is unexported in JSON
// terms: it lives in a separate field that the API DTO never copies.
type Registry struct {
	ID          string     `json:"id"`
	Host        string     `json:"host"`
	Username    string     `json:"username"`
	Status      string     `json:"status"`
	StatusAt    time.Time  `json:"status_at,omitempty"`
	StatusError string     `json:"status_error,omitempty"`
	TokenExpiry *time.Time `json:"token_expiry,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at"`
	// Sealed is the AES-GCM ciphertext of the secret. It is persisted but is
	// stripped by Public before anything is serialised to a client.
	Sealed string `json:"sealed_secret,omitempty"`
}

// Public returns a copy safe to serialise towards a client.
func (r Registry) Public() Registry {
	r.Sealed = ""
	return r
}

// Statuses a credential can be in.
const (
	StatusUnknown = "unknown"
	StatusOK      = "ok"
	StatusFailed  = "failed"
)

// Manager stores registries.
type Manager struct {
	st     *store.Store
	sealer *Sealer
	newID  func() (string, error)
	now    func() time.Time
}

// NewManager builds a Manager.
func NewManager(st *store.Store, sealer *Sealer, newID func() (string, error)) *Manager {
	return &Manager{st: st, sealer: sealer, newID: newID, now: time.Now}
}

// List returns every registry without secrets.
func (m *Manager) List() ([]Registry, error) {
	var out []Registry
	err := m.st.ForEach(store.BucketRegistries, func(_ string, raw []byte) error {
		var r Registry
		if err := json.Unmarshal(raw, &r); err != nil {
			return err
		}
		out = append(out, r.Public())
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out, nil
}

func (m *Manager) get(id string) (Registry, error) {
	var r Registry
	if err := m.st.Get(store.BucketRegistries, id, &r); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return Registry{}, ErrNotFound
		}
		return Registry{}, err
	}
	return r, nil
}

// Get returns one registry without its secret.
func (m *Manager) Get(id string) (Registry, error) {
	r, err := m.get(id)
	if err != nil {
		return Registry{}, err
	}
	return r.Public(), nil
}

// Create stores a new credential.
func (m *Manager) Create(host, username, secret string) (Registry, error) {
	host, err := NormalizeHost(host)
	if err != nil {
		return Registry{}, err
	}
	if err := validateUsername(username); err != nil {
		return Registry{}, err
	}
	if secret == "" || len(secret) > 8192 {
		return Registry{}, fmt.Errorf("%w: secret must be 1 to 8192 characters", ErrInvalid)
	}
	id, err := m.newID()
	if err != nil {
		return Registry{}, err
	}
	sealed, err := m.sealer.Seal(id, secret)
	if err != nil {
		return Registry{}, err
	}
	now := m.now().UTC()
	r := Registry{
		ID:        id,
		Host:      host,
		Username:  username,
		Status:    StatusUnknown,
		CreatedAt: now,
		UpdatedAt: now,
		Sealed:    sealed,
	}
	if err := m.st.Put(store.BucketRegistries, id, r); err != nil {
		return Registry{}, err
	}
	return r.Public(), nil
}

// Update replaces the username or the secret.
func (m *Manager) Update(id string, username, secret *string) (Registry, error) {
	r, err := m.get(id)
	if err != nil {
		return Registry{}, err
	}
	if username != nil {
		if err := validateUsername(*username); err != nil {
			return Registry{}, err
		}
		r.Username = *username
	}
	if secret != nil {
		if *secret == "" || len(*secret) > 8192 {
			return Registry{}, fmt.Errorf("%w: secret must be 1 to 8192 characters", ErrInvalid)
		}
		sealed, err := m.sealer.Seal(r.ID, *secret)
		if err != nil {
			return Registry{}, err
		}
		r.Sealed = sealed
		r.Status = StatusUnknown
		r.StatusError = ""
	}
	r.UpdatedAt = m.now().UTC()
	if err := m.st.Put(store.BucketRegistries, r.ID, r); err != nil {
		return Registry{}, err
	}
	return r.Public(), nil
}

// Delete removes a credential.
func (m *Manager) Delete(id string) error {
	if _, err := m.get(id); err != nil {
		return err
	}
	return m.st.Delete(store.BucketRegistries, id)
}

// SetStatus records the outcome of a login test.
func (m *Manager) SetStatus(id, status, errMsg string) (Registry, error) {
	r, err := m.get(id)
	if err != nil {
		return Registry{}, err
	}
	r.Status = status
	r.StatusError = errMsg
	r.StatusAt = m.now().UTC()
	if err := m.st.Put(store.BucketRegistries, r.ID, r); err != nil {
		return Registry{}, err
	}
	return r.Public(), nil
}

// Credential is a decrypted credential, handed only to the Docker client.
type Credential struct {
	Host     string
	Username string
	Secret   string
}

// Credential decrypts one registry's secret.
func (m *Manager) Credential(id string) (Credential, error) {
	r, err := m.get(id)
	if err != nil {
		return Credential{}, err
	}
	secret, err := m.sealer.Open(r.ID, r.Sealed)
	if err != nil {
		return Credential{}, err
	}
	return Credential{Host: r.Host, Username: r.Username, Secret: secret}, nil
}

// CredentialForRef finds the credential matching an image reference, if any.
func (m *Manager) CredentialForRef(ref string) (Credential, bool) {
	host := RegistryHostOf(ref)
	var found *Registry
	err := m.st.ForEach(store.BucketRegistries, func(_ string, raw []byte) error {
		var r Registry
		if err := json.Unmarshal(raw, &r); err != nil {
			return err
		}
		if strings.EqualFold(r.Host, host) {
			cp := r
			found = &cp
		}
		return nil
	})
	if err != nil || found == nil {
		return Credential{}, false
	}
	secret, err := m.sealer.Open(found.ID, found.Sealed)
	if err != nil {
		return Credential{}, false
	}
	return Credential{Host: found.Host, Username: found.Username, Secret: secret}, true
}

// NormalizeHost validates and canonicalises a registry host.
func NormalizeHost(host string) (string, error) {
	host = strings.TrimSpace(host)
	host = strings.TrimPrefix(strings.TrimPrefix(host, "https://"), "http://")
	host = strings.TrimSuffix(host, "/")
	if host == "" || len(host) > 253 {
		return "", fmt.Errorf("%w: host must be 1 to 253 characters", ErrInvalid)
	}
	if strings.ContainsAny(host, " \t\n\r/\\?#") {
		return "", fmt.Errorf("%w: host contains invalid characters", ErrInvalid)
	}
	name := host
	if h, _, err := net.SplitHostPort(host); err == nil {
		name = h
	}
	for _, label := range strings.Split(name, ".") {
		if label == "" {
			return "", fmt.Errorf("%w: host has an empty label", ErrInvalid)
		}
		for _, r := range label {
			isOK := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_'
			if !isOK {
				return "", fmt.Errorf("%w: host contains invalid characters", ErrInvalid)
			}
		}
	}
	return strings.ToLower(host), nil
}

func validateUsername(u string) error {
	if u == "" || len(u) > 255 {
		return fmt.Errorf("%w: username must be 1 to 255 characters", ErrInvalid)
	}
	for _, r := range u {
		if r < 0x21 || r > 0x7e {
			return fmt.Errorf("%w: username contains invalid characters", ErrInvalid)
		}
	}
	return nil
}

// RegistryHostOf extracts the registry host from an image reference,
// defaulting to Docker Hub.
func RegistryHostOf(ref string) string {
	first, rest, ok := strings.Cut(ref, "/")
	if !ok {
		return "docker.io"
	}
	if strings.ContainsAny(first, ".:") || first == "localhost" {
		return strings.ToLower(first)
	}
	_ = rest
	return "docker.io"
}
