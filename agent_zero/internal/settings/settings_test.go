package settings

import (
	"errors"
	"path/filepath"
	"testing"

	"agent_zero/internal/store"
)

func newManager(t *testing.T, defaults Settings) (*Manager, *store.Store) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "settings.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	m, err := NewManager(st, defaults)
	if err != nil {
		t.Fatal(err)
	}
	return m, st
}

func TestDefaultsAreSeeded(t *testing.T) {
	dir := t.TempDir()
	m, _ := newManager(t, Settings{RequireBiometricForRisky: true, StacksDir: dir})
	got := m.Get()
	if !got.RequireBiometricForRisky {
		t.Fatal("the default was not seeded")
	}
	if got.StacksDir != dir {
		t.Fatalf("stacks dir = %q", got.StacksDir)
	}
	if got.PushRelayStatus != "not_configured" {
		t.Fatalf("push relay status = %q", got.PushRelayStatus)
	}
}

func TestUpdatePersists(t *testing.T) {
	dir := t.TempDir()
	m, st := newManager(t, Settings{RequireBiometricForRisky: true, StacksDir: dir})

	off := false
	if _, err := m.Update(&off, nil); err != nil {
		t.Fatal(err)
	}
	if m.Get().RequireBiometricForRisky {
		t.Fatal("the change was not applied")
	}

	reloaded, err := NewManager(st, Settings{})
	if err != nil {
		t.Fatal(err)
	}
	if reloaded.Get().RequireBiometricForRisky {
		t.Fatal("the change did not survive a reload")
	}
}

func TestStacksDirIsValidated(t *testing.T) {
	dir := t.TempDir()
	m, _ := newManager(t, Settings{StacksDir: dir})

	for _, bad := range []string{"relative/path", "/definitely/not/here/agentzero"} {
		v := bad
		if _, err := m.Update(nil, &v); !errors.Is(err, ErrInvalid) {
			t.Fatalf("stacks_dir %q gave %v, want ErrInvalid", bad, err)
		}
	}
	other := t.TempDir()
	if _, err := m.Update(nil, &other); err != nil {
		t.Fatal(err)
	}
	if m.Get().StacksDir != other {
		t.Fatalf("stacks dir = %q", m.Get().StacksDir)
	}
}
