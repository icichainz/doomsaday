package registry

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"agent_zero/internal/store"
)

func newTestManager(t *testing.T) (*Manager, *store.Store) {
	t.Helper()
	dir := t.TempDir()
	st, err := store.Open(filepath.Join(dir, "reg.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	sealer, err := LoadOrCreateKey(filepath.Join(dir, "secret.key"))
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	return NewManager(st, sealer, func() (string, error) {
		n++
		return string(rune('a'+n-1)) + "000", nil
	}), st
}

func TestKeyFileIsCreated0600(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "secret.key")
	if _, err := LoadOrCreateKey(path); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("key file mode = %o, want 600", info.Mode().Perm())
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) != 32 {
		t.Fatalf("key is %d bytes, want 32", len(raw))
	}
}

func TestLooseKeyFileIsRefused(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "secret.key")
	if err := os.WriteFile(path, make([]byte, 32), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreateKey(path); err == nil {
		t.Fatal("a world readable key file was accepted")
	}
}

func TestSealOpenRoundTrip(t *testing.T) {
	sealer, err := LoadOrCreateKey(filepath.Join(t.TempDir(), "k"))
	if err != nil {
		t.Fatal(err)
	}
	sealed, err := sealer.Seal("id-1", "hunter2")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(sealed, "hunter2") {
		t.Fatal("the ciphertext contains the plaintext")
	}
	got, err := sealer.Open("id-1", sealed)
	if err != nil || got != "hunter2" {
		t.Fatalf("open = %q, %v", got, err)
	}
	// The id is authenticated data, so a swapped id must not decrypt.
	if _, err := sealer.Open("id-2", sealed); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("a ciphertext decrypted under the wrong id: %v", err)
	}
	if _, err := sealer.Open("id-1", "not base64 at all !!"); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("garbage decrypted: %v", err)
	}
	// Two seals of the same value differ, so the nonce is fresh.
	again, _ := sealer.Seal("id-1", "hunter2")
	if again == sealed {
		t.Fatal("two seals of the same value were identical")
	}
}

func TestSecretIsStrippedFromPublicViews(t *testing.T) {
	m, _ := newTestManager(t)
	reg, err := m.Create("registry.example.test", "robot", "s3cret")
	if err != nil {
		t.Fatal(err)
	}
	if reg.Sealed != "" {
		t.Fatal("Create returned the sealed secret")
	}
	got, err := m.Get(reg.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Sealed != "" {
		t.Fatal("Get returned the sealed secret")
	}
	list, err := m.List()
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range list {
		if r.Sealed != "" {
			t.Fatal("List returned a sealed secret")
		}
	}
	cred, err := m.Credential(reg.ID)
	if err != nil {
		t.Fatal(err)
	}
	if cred.Secret != "s3cret" {
		t.Fatalf("credential = %+v", cred)
	}
}

func TestNormalizeHost(t *testing.T) {
	for _, tc := range []struct {
		in, want string
		ok       bool
	}{
		{"https://registry.example.test/", "registry.example.test", true},
		{"REGISTRY.EXAMPLE.TEST", "registry.example.test", true},
		{"ghcr.io", "ghcr.io", true},
		{"localhost:5000", "localhost:5000", true},
		{"", "", false},
		{"has space", "", false},
		{"bad/path", "", false},
		{"a..b", "", false},
		{strings.Repeat("a", 300), "", false},
	} {
		got, err := NormalizeHost(tc.in)
		if tc.ok && (err != nil || got != tc.want) {
			t.Errorf("NormalizeHost(%q) = %q, %v; want %q", tc.in, got, err, tc.want)
		}
		if !tc.ok && err == nil {
			t.Errorf("NormalizeHost(%q) accepted the value", tc.in)
		}
	}
}

func TestRegistryHostOf(t *testing.T) {
	for in, want := range map[string]string{
		"alpine:3.20":                         "docker.io",
		"library/alpine":                      "docker.io",
		"ghcr.io/org/app:1.0":                 "ghcr.io",
		"registry.example.test:5000/team/app": "registry.example.test:5000",
		"localhost:5000/app":                  "localhost:5000",
	} {
		if got := RegistryHostOf(in); got != want {
			t.Errorf("RegistryHostOf(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCredentialForRef(t *testing.T) {
	m, _ := newTestManager(t)
	if _, err := m.Create("ghcr.io", "robot", "token-1"); err != nil {
		t.Fatal(err)
	}
	cred, ok := m.CredentialForRef("ghcr.io/org/app:1.0")
	if !ok || cred.Secret != "token-1" {
		t.Fatalf("credential = %+v, ok %v", cred, ok)
	}
	if _, ok := m.CredentialForRef("alpine:3.20"); ok {
		t.Fatal("a credential was found for Docker Hub, which has none stored")
	}
}

func TestCreateValidates(t *testing.T) {
	m, _ := newTestManager(t)
	for _, tc := range [][3]string{
		{"", "u", "s"},
		{"ok.test", "", "s"},
		{"ok.test", "u", ""},
		{"ok.test", "bad user", "s"},
		{"ok.test", "u", strings.Repeat("x", 9000)},
	} {
		if _, err := m.Create(tc[0], tc[1], tc[2]); !errors.Is(err, ErrInvalid) {
			t.Errorf("Create%v gave %v, want ErrInvalid", tc, err)
		}
	}
}

func TestUpdateRotatesTheSecret(t *testing.T) {
	m, _ := newTestManager(t)
	reg, err := m.Create("ghcr.io", "robot", "old")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.SetStatus(reg.ID, StatusOK, ""); err != nil {
		t.Fatal(err)
	}
	newSecret := "new"
	updated, err := m.Update(reg.ID, nil, &newSecret)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Status != StatusUnknown {
		t.Fatalf("rotating the secret left the status at %q", updated.Status)
	}
	cred, _ := m.Credential(reg.ID)
	if cred.Secret != "new" {
		t.Fatalf("secret = %q", cred.Secret)
	}
}

func TestMissingRegistry(t *testing.T) {
	m, _ := newTestManager(t)
	if _, err := m.Get("nope"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Get = %v", err)
	}
	if err := m.Delete("nope"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Delete = %v", err)
	}
}
