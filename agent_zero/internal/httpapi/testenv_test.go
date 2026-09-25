package httpapi

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"agent_zero/internal/alerts"
	"agent_zero/internal/audit"
	"agent_zero/internal/auth"
	"agent_zero/internal/compose"
	"agent_zero/internal/dockerx/fakedocker"
	"agent_zero/internal/jobs"
	"agent_zero/internal/registry"
	"agent_zero/internal/settings"
	"agent_zero/internal/store"
)

type env struct {
	t        *testing.T
	server   *Server
	handler  http.Handler
	fake     *fakedocker.Fake
	auth     *auth.Manager
	audit    *audit.BoltLogger
	store    *store.Store
	settings *settings.Manager
	alerts   *alerts.Store
	regs     *registry.Manager

	adminKey    string
	operatorKey string
	viewerKey   string
}

func newEnv(t *testing.T) *env {
	t.Helper()
	dir := t.TempDir()

	st, err := store.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	sealer, err := registry.LoadOrCreateKey(filepath.Join(dir, "secret.key"))
	if err != nil {
		t.Fatalf("sealer: %v", err)
	}

	authMgr := auth.NewManager(st, 15*time.Minute)
	auditLog := audit.NewBoltLogger(st)
	regs := registry.NewManager(st, sealer, auth.RandomID)
	settingsMgr, err := settings.NewManager(st, settings.Settings{
		RequireBiometricForRisky: false,
		StacksDir:                filepath.Join(dir, "stacks"),
	})
	if err != nil {
		t.Fatalf("settings: %v", err)
	}
	alertStore, err := alerts.NewStore(st)
	if err != nil {
		t.Fatalf("alerts: %v", err)
	}

	fake := fakedocker.New()
	e := &env{
		t: t, fake: fake, auth: authMgr, audit: auditLog, store: st,
		settings: settingsMgr, alerts: alertStore, regs: regs,
	}

	e.server = NewServer(Deps{
		Log:             slog.New(slog.NewTextHandler(io.Discard, nil)),
		Docker:          fake,
		Auth:            authMgr,
		Audit:           auditLog,
		Jobs:            jobs.New(jobs.Options{}),
		Alerts:          alertStore,
		Registries:      regs,
		Settings:        settingsMgr,
		Compose:         &compose.Discoverer{StacksDir: filepath.Join(dir, "stacks"), Docker: fake},
		ComposeRunner:   &compose.Runner{Bin: "docker"},
		Version:         "test",
		StartedAt:       time.Now(),
		CertFingerprint: "AA:BB:CC",
	})
	e.handler = e.server.Handler()

	e.adminKey = e.pairDevice("admin phone", auth.RoleAdmin)
	e.operatorKey = e.pairDevice("operator phone", auth.RoleOperator)
	e.viewerKey = e.pairDevice("viewer phone", auth.RoleViewer)
	return e
}

// pairDevice pairs a device and forces its role.
func (e *env) pairDevice(name string, role auth.Role) string {
	e.t.Helper()
	token, _, err := e.auth.NewPairingToken()
	if err != nil {
		e.t.Fatalf("mint token: %v", err)
	}
	res, err := e.auth.Pair(token, name, "")
	if err != nil {
		e.t.Fatalf("pair: %v", err)
	}
	if res.Device.Role != role {
		if _, err := e.auth.Update(res.Device.ID, &role, nil); err != nil {
			e.t.Fatalf("set role: %v", err)
		}
	}
	return res.DeviceKey
}

// deviceIDFor returns the id of the device holding key.
func (e *env) deviceIDFor(key string) string {
	e.t.Helper()
	dev, err := e.auth.Authenticate(key)
	if err != nil {
		e.t.Fatalf("authenticate: %v", err)
	}
	return dev.ID
}

type reqOpt func(*http.Request)

func withKey(key string) reqOpt {
	return func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+key) }
}

func withHeader(k, v string) reqOpt {
	return func(r *http.Request) { r.Header.Set(k, v) }
}

// withRepeatedHeader sends the same header more than once, which is not the
// same request as one header line holding both values.
func withRepeatedHeader(k string, values ...string) reqOpt {
	return func(r *http.Request) {
		r.Header.Del(k)
		for _, v := range values {
			r.Header.Add(k, v)
		}
	}
}

func withJSON(body any) reqOpt {
	return func(r *http.Request) {
		raw, err := json.Marshal(body)
		if err != nil {
			panic(err)
		}
		r.Body = io.NopCloser(bytes.NewReader(raw))
		r.ContentLength = int64(len(raw))
		r.Header.Set("Content-Type", "application/json")
	}
}

func withRawBody(raw string) reqOpt {
	return func(r *http.Request) {
		r.Body = io.NopCloser(bytes.NewReader([]byte(raw)))
		r.ContentLength = int64(len(raw))
		r.Header.Set("Content-Type", "application/json")
	}
}

func (e *env) do(method, path string, opts ...reqOpt) *httptest.ResponseRecorder {
	e.t.Helper()
	req := httptest.NewRequest(method, path, nil)
	req.RemoteAddr = "192.0.2.10:54321"
	for _, o := range opts {
		o(req)
	}
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	return rec
}

// decode unmarshals a JSON response body.
func decode[T any](t *testing.T, rec *httptest.ResponseRecorder) T {
	t.Helper()
	var v T
	if err := json.Unmarshal(rec.Body.Bytes(), &v); err != nil {
		t.Fatalf("decode response %q: %v", rec.Body.String(), err)
	}
	return v
}

// assertErrorEnvelope checks the contract's error shape and returns the code.
func assertErrorEnvelope(t *testing.T, rec *httptest.ResponseRecorder, wantStatus int) string {
	t.Helper()
	if rec.Code != wantStatus {
		t.Fatalf("status = %d, want %d (body %s)", rec.Code, wantStatus, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json; charset=utf-8" {
		t.Errorf("content type = %q", ct)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("body is not JSON: %v (%s)", err, rec.Body.String())
	}
	if len(raw) != 1 {
		t.Fatalf("error body must hold only \"error\", got %v", keysOf(raw))
	}
	inner, ok := raw["error"]
	if !ok {
		t.Fatalf("body has no \"error\" key: %s", rec.Body.String())
	}
	var detail struct {
		Code    *string         `json:"code"`
		Message *string         `json:"message"`
		Details *map[string]any `json:"details"`
	}
	if err := json.Unmarshal(inner, &detail); err != nil {
		t.Fatalf("error object: %v", err)
	}
	if detail.Code == nil || *detail.Code == "" {
		t.Error("error.code is missing")
	}
	if detail.Message == nil || *detail.Message == "" {
		t.Error("error.message is missing")
	}
	if detail.Details == nil {
		t.Error("error.details is missing")
	}
	if detail.Code == nil {
		return ""
	}
	return *detail.Code
}

func keysOf[T any](m map[string]T) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
