// Package auth owns pairing tokens, device keys and roles.
//
// A device key is 256 bits of crypto/rand, handed to the phone once at
// pairing time and never stored in the clear: the store holds only
// SHA-256(key), and lookups compare with crypto/subtle.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"agent_zero/internal/store"
)

// Role is a device's permission level.
type Role string

// The three roles from the contract.
const (
	RoleAdmin    Role = "admin"
	RoleOperator Role = "operator"
	RoleViewer   Role = "viewer"
)

// ValidRole reports whether r is one of the three known roles.
func ValidRole(r Role) bool {
	switch r {
	case RoleAdmin, RoleOperator, RoleViewer:
		return true
	}
	return false
}

// rank orders roles so that comparisons are simple.
func rank(r Role) int {
	switch r {
	case RoleAdmin:
		return 3
	case RoleOperator:
		return 2
	case RoleViewer:
		return 1
	}
	return 0
}

// AtLeast reports whether r satisfies the minimum role min.
func (r Role) AtLeast(min Role) bool { return rank(r) >= rank(min) && rank(r) > 0 }

// Errors returned by this package.
var (
	ErrBadToken     = errors.New("auth: invalid or expired pairing token")
	ErrBadKey       = errors.New("auth: invalid device key")
	ErrNoDevice     = errors.New("auth: device not found")
	ErrRateLimited  = errors.New("auth: too many attempts")
	ErrInvalidInput = errors.New("auth: invalid input")
)

// Device is a paired phone.
type Device struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	Role       Role      `json:"role"`
	CreatedAt  time.Time `json:"created_at"`
	LastSeenAt time.Time `json:"last_seen_at"`
	PushToken  string    `json:"push_token,omitempty"`
	// KeyHash is SHA-256 of the device key, hex encoded. It is never
	// serialised towards a client: handlers convert to a DTO first.
	KeyHash string `json:"key_hash"`
}

// Manager stores devices and mints pairing tokens.
type Manager struct {
	st  *store.Store
	ttl time.Duration

	mu     sync.Mutex
	tokens map[string]time.Time // sha256(token) hex -> expiry

	now func() time.Time
}

// NewManager builds a Manager over st. ttl is the pairing token lifetime.
func NewManager(st *store.Store, ttl time.Duration) *Manager {
	return &Manager{st: st, ttl: ttl, tokens: map[string]time.Time{}, now: time.Now}
}

// SetClock replaces the time source; used by tests.
func (m *Manager) SetClock(f func() time.Time) { m.now = f }

var tokenEnc = base32.StdEncoding.WithPadding(base32.NoPadding)

// NewPairingToken mints a one-time, short-lived pairing token and returns the
// clear text form. Only a hash is kept in memory.
func (m *Manager) NewPairingToken() (string, time.Time, error) {
	var raw [15]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", time.Time{}, err
	}
	s := tokenEnc.EncodeToString(raw[:]) // 24 chars
	tok := fmt.Sprintf("%s-%s-%s-%s-%s-%s", s[0:4], s[4:8], s[8:12], s[12:16], s[16:20], s[20:24])
	exp := m.now().Add(m.ttl)

	m.mu.Lock()
	defer m.mu.Unlock()
	m.sweepLocked()
	m.tokens[hashToken(tok)] = exp
	return tok, exp, nil
}

func (m *Manager) sweepLocked() {
	now := m.now()
	for k, exp := range m.tokens {
		if now.After(exp) {
			delete(m.tokens, k)
		}
	}
}

func hashToken(tok string) string {
	sum := sha256.Sum256([]byte(strings.ToUpper(strings.TrimSpace(tok))))
	return hex.EncodeToString(sum[:])
}

// consumeToken checks a pairing token and burns it. Comparison is constant
// time against every live token so a wrong token costs the same as a right one.
func (m *Manager) consumeToken(tok string) error {
	h := hashToken(tok)
	hb := []byte(h)

	m.mu.Lock()
	defer m.mu.Unlock()
	m.sweepLocked()

	match := ""
	for k := range m.tokens {
		if subtle.ConstantTimeCompare([]byte(k), hb) == 1 {
			match = k
		}
	}
	if match == "" {
		return ErrBadToken
	}
	delete(m.tokens, match)
	return nil
}

// PendingTokens reports how many pairing tokens are live. Used by tests and
// by the /settings view.
func (m *Manager) PendingTokens() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sweepLocked()
	return len(m.tokens)
}

// PairResult is what a successful pairing produced.
type PairResult struct {
	DeviceKey string
	Device    Device
}

// Pair exchanges a pairing token for a fresh device key. The first device to
// pair becomes admin; later devices default to operator.
func (m *Manager) Pair(token, deviceName, pushToken string) (PairResult, error) {
	deviceName = strings.TrimSpace(deviceName)
	if deviceName == "" {
		deviceName = "phone"
	}
	if len(deviceName) > 64 || !printableASCII(deviceName) {
		return PairResult{}, fmt.Errorf("%w: device_name", ErrInvalidInput)
	}
	if len(pushToken) > 512 || !printableASCII(pushToken) {
		return PairResult{}, fmt.Errorf("%w: push_token", ErrInvalidInput)
	}
	if err := m.consumeToken(token); err != nil {
		return PairResult{}, err
	}

	key, err := randomKey()
	if err != nil {
		return PairResult{}, err
	}
	sum := sha256.Sum256([]byte(key))
	keyHash := hex.EncodeToString(sum[:])

	id, err := RandomID()
	if err != nil {
		return PairResult{}, err
	}

	now := m.now().UTC()
	dev := Device{
		ID:         id,
		Name:       deviceName,
		CreatedAt:  now,
		LastSeenAt: now,
		PushToken:  pushToken,
		KeyHash:    keyHash,
	}

	err = m.st.Update(func(tx *store.Tx) error {
		// The first phone to pair owns the host.
		first, err := tx.IsEmpty(store.BucketDevices)
		if err != nil {
			return err
		}
		if first {
			dev.Role = RoleAdmin
		} else {
			dev.Role = RoleOperator
		}
		if err := tx.Put(store.BucketDevices, dev.ID, dev); err != nil {
			return err
		}
		return tx.Put(store.BucketDeviceKeys, keyHash, dev.ID)
	})
	if err != nil {
		return PairResult{}, err
	}
	return PairResult{DeviceKey: key, Device: dev}, nil
}

func randomKey() (string, error) {
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw[:]), nil
}

// RandomID returns a short random identifier used for devices, registries,
// alerts and jobs.
func RandomID() (string, error) {
	var raw [12]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw[:]), nil
}

// Authenticate resolves a bearer device key to its device.
func (m *Manager) Authenticate(key string) (Device, error) {
	key = strings.TrimSpace(key)
	if key == "" || len(key) > 256 {
		return Device{}, ErrBadKey
	}
	sum := sha256.Sum256([]byte(key))
	keyHash := hex.EncodeToString(sum[:])

	var deviceID string
	if err := m.st.Get(store.BucketDeviceKeys, keyHash, &deviceID); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return Device{}, ErrBadKey
		}
		return Device{}, err
	}
	dev, err := m.Get(deviceID)
	if err != nil {
		return Device{}, ErrBadKey
	}
	// Belt and braces: the stored hash must still match, in constant time.
	if subtle.ConstantTimeCompare([]byte(dev.KeyHash), []byte(keyHash)) != 1 {
		return Device{}, ErrBadKey
	}
	return dev, nil
}

// TouchLastSeen records that a device just made a call. Failures are
// non-fatal for the request and are reported to the caller for logging.
func (m *Manager) TouchLastSeen(id string) error {
	dev, err := m.Get(id)
	if err != nil {
		return err
	}
	dev.LastSeenAt = m.now().UTC()
	return m.st.Put(store.BucketDevices, dev.ID, dev)
}

// Get returns one device.
func (m *Manager) Get(id string) (Device, error) {
	var dev Device
	if err := m.st.Get(store.BucketDevices, id, &dev); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return Device{}, ErrNoDevice
		}
		return Device{}, err
	}
	return dev, nil
}

// List returns every device ordered by creation time.
func (m *Manager) List() ([]Device, error) {
	var out []Device
	err := m.st.ForEach(store.BucketDevices, func(_ string, raw []byte) error {
		var d Device
		if err := json.Unmarshal(raw, &d); err != nil {
			return err
		}
		out = append(out, d)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sortDevices(out)
	return out, nil
}

func sortDevices(d []Device) {
	for i := 1; i < len(d); i++ {
		for j := i; j > 0 && d[j].CreatedAt.Before(d[j-1].CreatedAt); j-- {
			d[j], d[j-1] = d[j-1], d[j]
		}
	}
}

// Update changes a device's role or push token.
func (m *Manager) Update(id string, role *Role, pushToken *string) (Device, error) {
	dev, err := m.Get(id)
	if err != nil {
		return Device{}, err
	}
	if role != nil {
		if !ValidRole(*role) {
			return Device{}, fmt.Errorf("%w: role", ErrInvalidInput)
		}
		dev.Role = *role
	}
	if pushToken != nil {
		if len(*pushToken) > 512 || !printableASCII(*pushToken) {
			return Device{}, fmt.Errorf("%w: push_token", ErrInvalidInput)
		}
		dev.PushToken = *pushToken
	}
	if err := m.st.Put(store.BucketDevices, dev.ID, dev); err != nil {
		return Device{}, err
	}
	return dev, nil
}

// Delete revokes a device and its key.
func (m *Manager) Delete(id string) error {
	dev, err := m.Get(id)
	if err != nil {
		return err
	}
	return m.st.Update(func(tx *store.Tx) error {
		if err := tx.Delete(store.BucketDeviceKeys, dev.KeyHash); err != nil {
			return err
		}
		return tx.Delete(store.BucketDevices, dev.ID)
	})
}

// CountAdmins returns how many admin devices exist.
func (m *Manager) CountAdmins() (int, error) {
	devs, err := m.List()
	if err != nil {
		return 0, err
	}
	n := 0
	for _, d := range devs {
		if d.Role == RoleAdmin {
			n++
		}
	}
	return n, nil
}

func printableASCII(s string) bool {
	for _, r := range s {
		if r < 0x20 || r > 0x7e {
			return false
		}
	}
	return true
}
