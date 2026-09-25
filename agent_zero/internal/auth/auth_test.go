package auth

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agent_zero/internal/store"
)

func newManager(t *testing.T) *Manager {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "auth.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return NewManager(st, 15*time.Minute)
}

func TestRoleOrdering(t *testing.T) {
	if !RoleAdmin.AtLeast(RoleOperator) || !RoleAdmin.AtLeast(RoleViewer) || !RoleAdmin.AtLeast(RoleAdmin) {
		t.Fatal("admin does not satisfy every role")
	}
	if RoleOperator.AtLeast(RoleAdmin) {
		t.Fatal("operator satisfies admin")
	}
	if !RoleOperator.AtLeast(RoleViewer) {
		t.Fatal("operator does not satisfy viewer")
	}
	if RoleViewer.AtLeast(RoleOperator) {
		t.Fatal("viewer satisfies operator")
	}
	if Role("nonsense").AtLeast(RoleViewer) {
		t.Fatal("an unknown role satisfies viewer")
	}
}

func TestPairingTokenShape(t *testing.T) {
	m := newManager(t)
	token, _, err := m.NewPairingToken()
	if err != nil {
		t.Fatal(err)
	}
	if len(strings.Split(token, "-")) != 6 {
		t.Fatalf("token %q is not six groups", token)
	}
	if len(strings.ReplaceAll(token, "-", "")) != 24 {
		t.Fatalf("token %q does not carry 120 bits", token)
	}

	other, _, _ := m.NewPairingToken()
	if other == token {
		t.Fatal("two pairing tokens were identical")
	}
}

func TestPairIsSingleUse(t *testing.T) {
	m := newManager(t)
	token, _, _ := m.NewPairingToken()

	if _, err := m.Pair(token, "phone", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Pair(token, "phone again", ""); !errors.Is(err, ErrBadToken) {
		t.Fatalf("second use error = %v, want ErrBadToken", err)
	}
	if n := m.PendingTokens(); n != 0 {
		t.Fatalf("%d tokens are still pending", n)
	}
}

func TestPairTokenExpiry(t *testing.T) {
	m := newManager(t)
	base := time.Now()
	m.SetClock(func() time.Time { return base })

	token, exp, _ := m.NewPairingToken()
	if exp.Sub(base) != 15*time.Minute {
		t.Fatalf("ttl = %v", exp.Sub(base))
	}
	m.SetClock(func() time.Time { return base.Add(15*time.Minute + time.Second) })
	if _, err := m.Pair(token, "late", ""); !errors.Is(err, ErrBadToken) {
		t.Fatalf("expired token error = %v", err)
	}
}

func TestFirstDeviceIsAdminAndOthersAreOperators(t *testing.T) {
	m := newManager(t)

	t1, _, _ := m.NewPairingToken()
	first, err := m.Pair(t1, "one", "")
	if err != nil {
		t.Fatal(err)
	}
	if first.Device.Role != RoleAdmin {
		t.Fatalf("first role = %q", first.Device.Role)
	}

	t2, _, _ := m.NewPairingToken()
	second, err := m.Pair(t2, "two", "")
	if err != nil {
		t.Fatal(err)
	}
	if second.Device.Role != RoleOperator {
		t.Fatalf("second role = %q", second.Device.Role)
	}
	if second.DeviceKey == first.DeviceKey {
		t.Fatal("two devices got the same key")
	}
}

func TestDeviceKeyEntropyAndStorage(t *testing.T) {
	m := newManager(t)
	token, _, _ := m.NewPairingToken()
	res, err := m.Pair(token, "phone", "")
	if err != nil {
		t.Fatal(err)
	}
	// 32 random bytes, base64url without padding, is 43 characters.
	if len(res.DeviceKey) != 43 {
		t.Fatalf("device key is %d characters, want 43 (256 bits)", len(res.DeviceKey))
	}
	if strings.Contains(res.Device.KeyHash, res.DeviceKey) {
		t.Fatal("the stored hash contains the key")
	}
	if len(res.Device.KeyHash) != 64 {
		t.Fatalf("stored hash is %d characters, want a sha-256 hex digest", len(res.Device.KeyHash))
	}
}

func TestAuthenticate(t *testing.T) {
	m := newManager(t)
	token, _, _ := m.NewPairingToken()
	res, _ := m.Pair(token, "phone", "")

	dev, err := m.Authenticate(res.DeviceKey)
	if err != nil {
		t.Fatal(err)
	}
	if dev.ID != res.Device.ID {
		t.Fatalf("device = %+v", dev)
	}

	for _, bad := range []string{"", "  ", res.DeviceKey + "x", strings.Repeat("a", 300)} {
		if _, err := m.Authenticate(bad); !errors.Is(err, ErrBadKey) {
			t.Fatalf("key %q gave %v, want ErrBadKey", bad, err)
		}
	}
}

func TestDeleteRevokesTheKey(t *testing.T) {
	m := newManager(t)
	token, _, _ := m.NewPairingToken()
	res, _ := m.Pair(token, "phone", "")

	if err := m.Delete(res.Device.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Authenticate(res.DeviceKey); !errors.Is(err, ErrBadKey) {
		t.Fatalf("a revoked key still authenticates: %v", err)
	}
	if _, err := m.Get(res.Device.ID); !errors.Is(err, ErrNoDevice) {
		t.Fatalf("device still present: %v", err)
	}
	if err := m.Delete("nope"); !errors.Is(err, ErrNoDevice) {
		t.Fatalf("deleting a missing device gave %v", err)
	}
}

func TestPairValidatesInput(t *testing.T) {
	m := newManager(t)
	token, _, _ := m.NewPairingToken()
	if _, err := m.Pair(token, strings.Repeat("n", 100), ""); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("a 100 character device name gave %v", err)
	}
	token2, _, _ := m.NewPairingToken()
	if _, err := m.Pair(token2, "bad\nname", ""); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("a device name with a newline gave %v", err)
	}
}

func TestUpdateValidatesRole(t *testing.T) {
	m := newManager(t)
	token, _, _ := m.NewPairingToken()
	res, _ := m.Pair(token, "phone", "")

	bogus := Role("root")
	if _, err := m.Update(res.Device.ID, &bogus, nil); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("an unknown role was accepted: %v", err)
	}
	viewer := RoleViewer
	dev, err := m.Update(res.Device.ID, &viewer, nil)
	if err != nil {
		t.Fatal(err)
	}
	if dev.Role != RoleViewer {
		t.Fatalf("role = %q", dev.Role)
	}
}

func TestCountAdmins(t *testing.T) {
	m := newManager(t)
	for i := 0; i < 3; i++ {
		token, _, _ := m.NewPairingToken()
		if _, err := m.Pair(token, "phone", ""); err != nil {
			t.Fatal(err)
		}
	}
	n, err := m.CountAdmins()
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("admins = %d, want 1", n)
	}
}

func TestRateLimiter(t *testing.T) {
	base := time.Now()
	l := NewRateLimiter(3, time.Second)
	l.SetClock(func() time.Time { return base })

	for i := 0; i < 3; i++ {
		if !l.Allow("1.2.3.4") {
			t.Fatalf("call %d was refused inside the burst", i)
		}
	}
	if l.Allow("1.2.3.4") {
		t.Fatal("the fourth call inside the burst was allowed")
	}
	if !l.Allow("5.6.7.8") {
		t.Fatal("a different key was throttled")
	}
	if l.RetryAfter("1.2.3.4") <= 0 {
		t.Fatal("RetryAfter reported no wait")
	}

	// A second later a token is back.
	l.SetClock(func() time.Time { return base.Add(time.Second) })
	if !l.Allow("1.2.3.4") {
		t.Fatal("no token was refilled after a second")
	}
}
