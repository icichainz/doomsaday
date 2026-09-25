package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"agent_zero/internal/audit"
	"agent_zero/internal/auth"
)

func TestHealthIsUnauthenticated(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/v1/health")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	body := decode[map[string]any](t, rec)
	if len(body) != 1 || body["ok"] != true {
		t.Fatalf("health body = %v, want exactly {\"ok\": true}", body)
	}
}

func TestPairExchangesTokenForKey(t *testing.T) {
	e := newEnv(t)
	token, _, err := e.auth.NewPairingToken()
	if err != nil {
		t.Fatal(err)
	}

	rec := e.do("POST", "/v1/pair", withJSON(map[string]any{
		"token": token, "device_name": "new phone", "push_token": "abc123",
	}))
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, body %s", rec.Code, rec.Body.String())
	}
	body := decode[pairResponse](t, rec)
	if body.DeviceKey == "" {
		t.Fatal("no device key returned")
	}
	if body.CertFingerprint != "AA:BB:CC" {
		t.Errorf("cert_fingerprint = %q", body.CertFingerprint)
	}
	// A device paired after the first one is an operator.
	if body.Role != string(auth.RoleOperator) {
		t.Errorf("role = %q, want operator", body.Role)
	}
	// The new key works.
	if rec := e.do("GET", "/v1/system", withKey(body.DeviceKey)); rec.Code != http.StatusOK {
		t.Fatalf("new key rejected: %d", rec.Code)
	}
}

func TestFirstDeviceBecomesAdmin(t *testing.T) {
	e := newEnv(t)
	// newEnv already paired three devices; check the first one is admin.
	devices, err := e.auth.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) == 0 {
		t.Fatal("no devices")
	}
	if devices[0].Role != auth.RoleAdmin {
		t.Fatalf("first device role = %q, want admin", devices[0].Role)
	}
}

func TestPairingTokenIsSingleUse(t *testing.T) {
	e := newEnv(t)
	token, _, err := e.auth.NewPairingToken()
	if err != nil {
		t.Fatal(err)
	}
	body := map[string]any{"token": token, "device_name": "phone"}

	if rec := e.do("POST", "/v1/pair", withJSON(body)); rec.Code != http.StatusCreated {
		t.Fatalf("first pair status = %d", rec.Code)
	}
	rec := e.do("POST", "/v1/pair", withJSON(body))
	if code := assertErrorEnvelope(t, rec, http.StatusUnauthorized); code != codePairingFailed {
		t.Fatalf("code = %q, want %q", code, codePairingFailed)
	}
}

func TestPairingTokenExpires(t *testing.T) {
	e := newEnv(t)
	now := time.Now()
	e.auth.SetClock(func() time.Time { return now })

	token, exp, err := e.auth.NewPairingToken()
	if err != nil {
		t.Fatal(err)
	}
	if !exp.After(now) {
		t.Fatal("token expiry is not in the future")
	}
	e.auth.SetClock(func() time.Time { return now.Add(16 * time.Minute) })

	rec := e.do("POST", "/v1/pair", withJSON(map[string]any{"token": token, "device_name": "late"}))
	if code := assertErrorEnvelope(t, rec, http.StatusUnauthorized); code != codePairingFailed {
		t.Fatalf("code = %q", code)
	}
}

func TestPairRejectsUnknownToken(t *testing.T) {
	e := newEnv(t)
	rec := e.do("POST", "/v1/pair", withJSON(map[string]any{
		"token": "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF", "device_name": "phone",
	}))
	assertErrorEnvelope(t, rec, http.StatusUnauthorized)
}

func TestPairIsRateLimited(t *testing.T) {
	e := newEnv(t)
	body := map[string]any{"token": "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF", "device_name": "phone"}

	sawLimit := false
	for i := 0; i < 12; i++ {
		rec := e.do("POST", "/v1/pair", withJSON(body))
		if rec.Code == http.StatusTooManyRequests {
			sawLimit = true
			if code := assertErrorEnvelope(t, rec, http.StatusTooManyRequests); code != codeRateLimited {
				t.Fatalf("code = %q", code)
			}
			if rec.Header().Get("Retry-After") == "" {
				t.Error("no Retry-After header")
			}
			break
		}
	}
	if !sawLimit {
		t.Fatal("the pairing endpoint was never rate limited")
	}
}

func TestFailedAuthIsRateLimited(t *testing.T) {
	e := newEnv(t)
	sawLimit := false
	for i := 0; i < 40; i++ {
		rec := e.do("GET", "/v1/system", withKey("not-a-real-key"))
		if rec.Code == http.StatusTooManyRequests {
			sawLimit = true
			break
		}
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("status = %d", rec.Code)
		}
	}
	if !sawLimit {
		t.Fatal("repeated bad keys were never rate limited")
	}
}

func TestMissingAndBadKeysAreRejected(t *testing.T) {
	e := newEnv(t)
	for _, tc := range []struct {
		name string
		opts []reqOpt
	}{
		{"no header", nil},
		{"wrong scheme", []reqOpt{withHeader("Authorization", "Basic "+e.adminKey)}},
		{"empty bearer", []reqOpt{withHeader("Authorization", "Bearer ")}},
		{"unknown key", []reqOpt{withKey("zzzz")}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rec := e.do("GET", "/v1/containers", tc.opts...)
			code := assertErrorEnvelope(t, rec, http.StatusUnauthorized)
			if code != codeUnauthorized {
				t.Fatalf("code = %q", code)
			}
		})
	}
}

func TestDeviceKeyIsNeverStoredInTheClear(t *testing.T) {
	e := newEnv(t)
	devices, err := e.auth.List()
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range devices {
		if strings.Contains(e.adminKey, d.KeyHash) || d.KeyHash == e.adminKey {
			t.Fatal("the stored hash equals the device key")
		}
		if len(d.KeyHash) != 64 {
			t.Fatalf("key hash is not a sha-256 hex digest: %q", d.KeyHash)
		}
	}
}

func TestDeviceListNeverLeaksKeyMaterial(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/v1/devices", withKey(e.viewerKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	body := rec.Body.String()
	for _, needle := range []string{"key_hash", `"push_token"`, e.adminKey, e.viewerKey} {
		if strings.Contains(body, needle) {
			t.Fatalf("device list leaked %q: %s", needle, body)
		}
	}
	var page struct {
		Items []deviceDTO `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 3 {
		t.Fatalf("got %d devices, want 3", len(page.Items))
	}
}

func TestLastAdminCannotBeDemotedOrRevoked(t *testing.T) {
	e := newEnv(t)
	adminID := e.deviceIDFor(e.adminKey)

	rec := e.do("PATCH", "/v1/devices/"+adminID, withKey(e.adminKey),
		withJSON(map[string]any{"role": "viewer"}))
	if code := assertErrorEnvelope(t, rec, http.StatusConflict); code != codeConflict {
		t.Fatalf("code = %q", code)
	}

	rec = e.do("DELETE", "/v1/devices/"+e.deviceIDFor(e.operatorKey), withKey(e.adminKey))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("revoking an operator failed: %d %s", rec.Code, rec.Body.String())
	}
}

// ------------------------------------------------------------------- /me

func TestMeAnswersForEveryRole(t *testing.T) {
	e := newEnv(t)
	for _, tc := range []struct {
		role, key, name string
	}{
		{"admin", e.adminKey, "admin phone"},
		{"operator", e.operatorKey, "operator phone"},
		{"viewer", e.viewerKey, "viewer phone"},
	} {
		t.Run(tc.role, func(t *testing.T) {
			rec := e.do("GET", "/v1/me", withKey(tc.key))
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d (%s)", rec.Code, rec.Body.String())
			}
			me := decode[meResponse](t, rec)
			if me.DeviceID != e.deviceIDFor(tc.key) {
				t.Errorf("device_id = %q", me.DeviceID)
			}
			if me.DeviceName != tc.name {
				t.Errorf("device_name = %q, want %q", me.DeviceName, tc.name)
			}
			if me.Role != tc.role {
				t.Errorf("role = %q, want %q", me.Role, tc.role)
			}
			if me.AgentVersion != "test" {
				t.Errorf("agent_version = %q", me.AgentVersion)
			}
			if me.PairedDevices != 3 {
				t.Errorf("paired_devices = %d, want 3", me.PairedDevices)
			}
		})
	}
}

func TestMeReturnsThePinnedFingerprint(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/v1/me", withKey(e.viewerKey))
	me := decode[meResponse](t, rec)
	if me.CertFingerprint != e.server.CertFingerprint || me.CertFingerprint == "" {
		t.Fatalf("cert_fingerprint = %q, want %q", me.CertFingerprint, e.server.CertFingerprint)
	}

	// The same string POST /v1/pair hands out, so the app can compare them.
	token, _, err := e.auth.NewPairingToken()
	if err != nil {
		t.Fatal(err)
	}
	rec = e.do("POST", "/v1/pair", withJSON(map[string]any{"token": token, "device_name": "another"}))
	if rec.Code != http.StatusCreated {
		t.Fatalf("pair status = %d (%s)", rec.Code, rec.Body.String())
	}
	if paired := decode[pairResponse](t, rec); paired.CertFingerprint != me.CertFingerprint {
		t.Fatalf("pair fingerprint %q != /me fingerprint %q", paired.CertFingerprint, me.CertFingerprint)
	}
}

func TestMeNeedsAuthentication(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/v1/me")
	if code := assertErrorEnvelope(t, rec, http.StatusUnauthorized); code != codeUnauthorized {
		t.Fatalf("code = %q", code)
	}
	rec = e.do("GET", "/v1/me", withKey("not-a-key"))
	assertErrorEnvelope(t, rec, http.StatusUnauthorized)
}

func TestMeReflectsARoleChangeAndARevoke(t *testing.T) {
	e := newEnv(t)
	operatorID := e.deviceIDFor(e.operatorKey)

	rec := e.do("PATCH", "/v1/devices/"+operatorID, withKey(e.adminKey),
		withJSON(map[string]any{"role": "viewer"}))
	if rec.Code != http.StatusOK {
		t.Fatalf("patch status = %d (%s)", rec.Code, rec.Body.String())
	}
	if me := decode[meResponse](t, e.do("GET", "/v1/me", withKey(e.operatorKey))); me.Role != "viewer" {
		t.Fatalf("role after the change = %q, want viewer", me.Role)
	}

	// Revoking a device drops it from the count the next caller sees.
	if rec := e.do("DELETE", "/v1/devices/"+operatorID, withKey(e.adminKey)); rec.Code != http.StatusNoContent {
		t.Fatalf("revoke status = %d (%s)", rec.Code, rec.Body.String())
	}
	if me := decode[meResponse](t, e.do("GET", "/v1/me", withKey(e.viewerKey))); me.PairedDevices != 2 {
		t.Fatalf("paired_devices after a revoke = %d, want 2", me.PairedDevices)
	}
}

func TestMeIsNotAudited(t *testing.T) {
	e := newEnv(t)
	if rec := e.do("GET", "/v1/me", withKey(e.adminKey)); rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	records, _, err := e.audit.List(audit.Filter{Limit: 50})
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range records {
		if strings.Contains(r.Action, "/v1/me") {
			t.Fatalf("a read was audited: %+v", r)
		}
	}
}

func TestUnpairSelfIsAllowed(t *testing.T) {
	e := newEnv(t)
	id := e.deviceIDFor(e.operatorKey)
	rec := e.do("DELETE", "/v1/devices/"+id, withKey(e.adminKey))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d", rec.Code)
	}
	if rec := e.do("GET", "/v1/system", withKey(e.operatorKey)); rec.Code != http.StatusUnauthorized {
		t.Fatalf("a revoked key still works: %d", rec.Code)
	}
}
