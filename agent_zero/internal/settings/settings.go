// Package settings holds the agent settings the Server settings screen edits.
package settings

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"agent_zero/internal/store"
)

// ErrInvalid is returned for a rejected value.
var ErrInvalid = errors.New("settings: invalid value")

const key = "agent"

// Settings is the editable agent configuration.
type Settings struct {
	RequireBiometricForRisky bool   `json:"require_biometric_for_risky"`
	StacksDir                string `json:"stacks_dir"`
	// PushRelayStatus is always "not_configured": push delivery needs a
	// relay holding the Firebase and APNs keys, which is out of scope here.
	PushRelayStatus string `json:"push_relay_status"`
	PushRelayURL    string `json:"push_relay_url,omitempty"`
}

// Manager persists Settings.
type Manager struct {
	st *store.Store

	mu      sync.RWMutex
	current Settings
}

// NewManager loads the settings, seeding them from the defaults on first run.
func NewManager(st *store.Store, defaults Settings) (*Manager, error) {
	m := &Manager{st: st}
	var s Settings
	err := st.Get(store.BucketSettings, key, &s)
	switch {
	case errors.Is(err, store.ErrNotFound):
		s = defaults
		s.PushRelayStatus = "not_configured"
		if err := st.Put(store.BucketSettings, key, s); err != nil {
			return nil, err
		}
	case err != nil:
		return nil, err
	}
	s.PushRelayStatus = "not_configured"
	if s.StacksDir == "" {
		s.StacksDir = defaults.StacksDir
	}
	m.current = s
	return m, nil
}

// Get returns the current settings.
func (m *Manager) Get() Settings {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.current
}

// Update applies a partial change.
func (m *Manager) Update(requireBiometric *bool, stacksDir *string) (Settings, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	next := m.current
	if requireBiometric != nil {
		next.RequireBiometricForRisky = *requireBiometric
	}
	if stacksDir != nil {
		dir := *stacksDir
		if dir != "" {
			if !filepath.IsAbs(dir) {
				return Settings{}, fmt.Errorf("%w: stacks_dir must be an absolute path", ErrInvalid)
			}
			if len(dir) > 4096 {
				return Settings{}, fmt.Errorf("%w: stacks_dir is too long", ErrInvalid)
			}
			if st, err := os.Stat(dir); err != nil || !st.IsDir() {
				return Settings{}, fmt.Errorf("%w: stacks_dir must be an existing directory", ErrInvalid)
			}
		}
		next.StacksDir = dir
	}
	if err := m.st.Put(store.BucketSettings, key, next); err != nil {
		return Settings{}, err
	}
	m.current = next
	return next, nil
}
