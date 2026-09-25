package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"agent_zero/internal/audit"
	"agent_zero/internal/dockerx"
)

// ------------------------------------------------------------ role checks

func TestRoleEnforcement(t *testing.T) {
	e := newEnv(t)
	webID := e.fake.Containers[0].ID

	cases := []struct {
		name         string
		method, path string
		viewer       int
		operator     int
		admin        int
	}{
		{"start container", "POST", "/v1/containers/" + webID + "/start",
			http.StatusForbidden, http.StatusOK, http.StatusOK},
		{"stop container", "POST", "/v1/containers/" + webID + "/stop",
			http.StatusForbidden, http.StatusOK, http.StatusOK},
		{"remove container", "DELETE", "/v1/containers/" + webID,
			http.StatusForbidden, http.StatusForbidden, http.StatusNoContent},
		{"read env values", "GET", "/v1/containers/" + webID + "/env",
			http.StatusForbidden, http.StatusForbidden, http.StatusOK},
		{"list containers", "GET", "/v1/containers",
			http.StatusOK, http.StatusOK, http.StatusOK},
		{"patch settings", "PATCH", "/v1/settings",
			http.StatusForbidden, http.StatusForbidden, http.StatusOK},
		{"list registries", "GET", "/v1/registries",
			http.StatusOK, http.StatusOK, http.StatusOK},
	}

	for _, tc := range cases {
		for _, who := range []struct {
			role string
			key  string
			want int
		}{
			{"viewer", e.viewerKey, tc.viewer},
			{"operator", e.operatorKey, tc.operator},
			{"admin", e.adminKey, tc.admin},
		} {
			t.Run(fmt.Sprintf("%s/%s", tc.name, who.role), func(t *testing.T) {
				fresh := newEnv(t)
				key := map[string]string{
					"viewer": fresh.viewerKey, "operator": fresh.operatorKey, "admin": fresh.adminKey,
				}[who.role]

				opts := []reqOpt{withKey(key)}
				if tc.method == "PATCH" {
					opts = append(opts, withJSON(map[string]any{"require_biometric_for_risky": true}))
				}
				rec := fresh.do(tc.method, tc.path, opts...)
				if rec.Code != who.want {
					t.Fatalf("%s %s as %s = %d, want %d (%s)",
						tc.method, tc.path, who.role, rec.Code, who.want, rec.Body.String())
				}
				if who.want == http.StatusForbidden {
					if code := assertErrorEnvelope(t, rec, http.StatusForbidden); code != codeForbidden {
						t.Fatalf("code = %q", code)
					}
				}
			})
		}
	}
}

func TestForbiddenCallIsAudited(t *testing.T) {
	e := newEnv(t)
	webID := e.fake.Containers[0].ID

	rec := e.do("DELETE", "/v1/containers/"+webID, withKey(e.operatorKey))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d", rec.Code)
	}
	records, _, err := e.audit.List(audit.Filter{Limit: 20})
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, r := range records {
		if r.Result == audit.ResultDenied && strings.Contains(r.Action, "/v1/containers/") {
			found = true
		}
	}
	if !found {
		t.Fatalf("the refused call was not audited: %+v", records)
	}
}

// ------------------------------------------------------- confirmation rule

func TestRiskyActionNeedsConfirmationHeader(t *testing.T) {
	e := newEnv(t)
	if _, err := e.settings.Update(boolPtr(true), nil); err != nil {
		t.Fatal(err)
	}
	webID := e.fake.Containers[0].ID

	rec := e.do("POST", "/v1/containers/"+webID+"/stop", withKey(e.adminKey))
	code := assertErrorEnvelope(t, rec, http.StatusPreconditionRequired)
	if code != codeConfirmationRequired {
		t.Fatalf("code = %q, want %q", code, codeConfirmationRequired)
	}
	if e.fake.Called("ContainerStop") {
		t.Fatal("the container was stopped despite the missing confirmation")
	}

	rec = e.do("POST", "/v1/containers/"+webID+"/stop",
		withKey(e.adminKey), withHeader("X-Confirmed", "biometric"))
	if rec.Code != http.StatusOK {
		t.Fatalf("confirmed stop = %d (%s)", rec.Code, rec.Body.String())
	}
	if !e.fake.Called("ContainerStop") {
		t.Fatal("the confirmed stop did not reach Docker")
	}
}

// riskyCall is one endpoint the confirmation rule covers, with what a
// confirmed call answers in this environment.
type riskyCall struct {
	name   string
	method string
	path   func(e *env) string
	// want is the status of a confirmed call. Some of these never reach
	// Docker here (there is no compose file on disk), and then the handler's
	// own error still proves the confirmation middleware let the call past.
	want int
	// wantCode is the error code expected with want, empty on a success.
	wantCode string
	// docker is the fake method a confirmed call must reach synchronously,
	// empty for the calls that only queue a job.
	docker string
}

// riskyCalls covers one endpoint of every class the rule protects.
func riskyCalls() []riskyCall {
	container := func(suffix string) func(*env) string {
		return func(e *env) string { return "/v1/containers/" + e.fake.Containers[0].ID + suffix }
	}
	fixed := func(p string) func(*env) string { return func(*env) string { return p } }
	return []riskyCall{
		{name: "container stop", method: "POST", path: container("/stop"),
			want: http.StatusOK, docker: "ContainerStop"},
		{name: "container remove", method: "DELETE", path: container(""),
			want: http.StatusNoContent, docker: "ContainerRemove"},
		{name: "image remove", method: "DELETE", path: fixed("/v1/images/sha256:img3"),
			want: http.StatusNoContent, docker: "ImageRemove"},
		{name: "image prune", method: "POST", path: fixed("/v1/images/prune"),
			want: http.StatusAccepted},
		{name: "volume prune", method: "POST", path: fixed("/v1/volumes/prune"),
			want: http.StatusAccepted},
		{name: "network prune", method: "POST", path: fixed("/v1/networks/prune"),
			want: http.StatusAccepted},
		// The demo stack is known only from container labels, so the handler
		// refuses it with 409. Reaching that refusal is the point.
		{name: "stack down", method: "POST", path: fixed("/v1/stacks/demo/down"),
			want: http.StatusConflict, wantCode: codeConflict},
		{name: "device revoke", method: "DELETE",
			path: func(e *env) string { return "/v1/devices/" + e.deviceIDFor(e.operatorKey) },
			want: http.StatusNoContent},
	}
}

// TestRiskyActionsAcceptEveryConfirmationMethod checks that both methods, in
// any case and with padding, satisfy the header on every covered endpoint.
func TestRiskyActionsAcceptEveryConfirmationMethod(t *testing.T) {
	values := []string{"biometric", "typed", "TYPED", "Biometric", "  typed  ", "\tBIOMETRIC "}
	for _, rc := range riskyCalls() {
		for _, value := range values {
			t.Run(fmt.Sprintf("%s/%q", rc.name, value), func(t *testing.T) {
				e := newEnv(t)
				if _, err := e.settings.Update(boolPtr(true), nil); err != nil {
					t.Fatal(err)
				}
				rec := e.do(rc.method, rc.path(e),
					withKey(e.adminKey), withHeader("X-Confirmed", value))
				if rec.Code != rc.want {
					t.Fatalf("%s with %q = %d, want %d (%s)",
						rc.name, value, rec.Code, rc.want, rec.Body.String())
				}
				if rc.wantCode != "" {
					if code := assertErrorEnvelope(t, rec, rc.want); code != rc.wantCode {
						t.Fatalf("code = %q, want %q", code, rc.wantCode)
					}
				}
				if rc.docker != "" && !e.fake.Called(rc.docker) {
					t.Fatalf("the confirmed call did not reach Docker (%s)", rc.docker)
				}
			})
		}
	}
}

// TestRiskyActionsRefuseOtherConfirmationValues checks that anything but the
// two accepted methods is still a 428 that never reaches Docker.
func TestRiskyActionsRefuseOtherConfirmationValues(t *testing.T) {
	cases := []struct {
		name string
		opt  reqOpt
	}{
		{"absent", func(*http.Request) {}},
		{"empty", withHeader("X-Confirmed", "")},
		{"blank", withHeader("X-Confirmed", "   ")},
		{"yes", withHeader("X-Confirmed", "yes")},
		{"typo", withHeader("X-Confirmed", "typedd")},
		{"both on one line", withHeader("X-Confirmed", "biometric, typed")},
		{"repeated header", withRepeatedHeader("X-Confirmed", "biometric", "typed")},
		{"repeated same value", withRepeatedHeader("X-Confirmed", "typed", "typed")},
	}
	for _, rc := range riskyCalls() {
		for _, tc := range cases {
			t.Run(rc.name+"/"+tc.name, func(t *testing.T) {
				e := newEnv(t)
				if _, err := e.settings.Update(boolPtr(true), nil); err != nil {
					t.Fatal(err)
				}
				rec := e.do(rc.method, rc.path(e), withKey(e.adminKey), tc.opt)
				if code := assertErrorEnvelope(t, rec, http.StatusPreconditionRequired); code != codeConfirmationRequired {
					t.Fatalf("code = %q, want %q", code, codeConfirmationRequired)
				}
				if len(e.fake.Calls()) > 0 {
					t.Fatalf("a refused call reached Docker: %+v", e.fake.Calls())
				}
			})
		}
	}
}

// TestConfirmationRequiredListsTheAcceptedMethods checks the 428 details, so a
// desktop client can discover that typing the name is allowed.
func TestConfirmationRequiredListsTheAcceptedMethods(t *testing.T) {
	e := newEnv(t)
	if _, err := e.settings.Update(boolPtr(true), nil); err != nil {
		t.Fatal(err)
	}
	rec := e.do("POST", "/v1/containers/"+e.fake.Containers[0].ID+"/stop", withKey(e.adminKey))
	if rec.Code != http.StatusPreconditionRequired {
		t.Fatalf("status = %d", rec.Code)
	}
	body := decode[struct {
		Error struct {
			Details struct {
				Header   string   `json:"header"`
				Accepted []string `json:"accepted"`
			} `json:"details"`
		} `json:"error"`
	}](t, rec)
	if body.Error.Details.Header != "X-Confirmed" {
		t.Errorf("details.header = %q", body.Error.Details.Header)
	}
	if got := body.Error.Details.Accepted; len(got) != 2 || got[0] != "biometric" || got[1] != "typed" {
		t.Errorf("details.accepted = %v, want [biometric typed]", got)
	}
}

// TestAuditRecordsTheConfirmationMethod checks that the activity log says how
// the person answered: which method, or none when nothing was asked of them.
func TestAuditRecordsTheConfirmationMethod(t *testing.T) {
	cases := []struct {
		name    string
		setting bool
		opts    []reqOpt
		want    string
	}{
		{"biometric", true, []reqOpt{withHeader("X-Confirmed", "biometric")}, "biometric"},
		{"typed", true, []reqOpt{withHeader("X-Confirmed", "typed")}, "typed"},
		{"padded and upper case", true, []reqOpt{withHeader("X-Confirmed", " TYPED ")}, "typed"},
		{"setting off, no header", false, nil, "none"},
		{"setting off, header sent", false, []reqOpt{withHeader("X-Confirmed", "typed")}, "typed"},
		{"setting off, junk header", false, []reqOpt{withHeader("X-Confirmed", "yes")}, "none"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t)
			if _, err := e.settings.Update(boolPtr(tc.setting), nil); err != nil {
				t.Fatal(err)
			}
			opts := append([]reqOpt{withKey(e.adminKey)}, tc.opts...)
			rec := e.do("POST", "/v1/containers/"+e.fake.Containers[0].ID+"/stop", opts...)
			if rec.Code != http.StatusOK {
				t.Fatalf("stop = %d (%s)", rec.Code, rec.Body.String())
			}
			rr := e.auditRecordFor(t, "/stop")
			if rr.Result != audit.ResultOK {
				t.Fatalf("result = %q", rr.Result)
			}
			if got := rr.Details["confirmation"]; got != tc.want {
				t.Fatalf("details.confirmation = %v, want %q (details %v)", got, tc.want, rr.Details)
			}
		})
	}
}

// TestRefusedConfirmationIsStillAuditedAsDenied keeps the existing behaviour:
// a 428 is a denied record, and the call never reached the handler.
func TestRefusedConfirmationIsStillAuditedAsDenied(t *testing.T) {
	e := newEnv(t)
	if _, err := e.settings.Update(boolPtr(true), nil); err != nil {
		t.Fatal(err)
	}
	rec := e.do("POST", "/v1/containers/"+e.fake.Containers[0].ID+"/stop",
		withKey(e.adminKey), withHeader("X-Confirmed", "yes"))
	if rec.Code != http.StatusPreconditionRequired {
		t.Fatalf("status = %d", rec.Code)
	}
	rr := e.auditRecordFor(t, "/stop")
	if rr.Result != audit.ResultDenied {
		t.Fatalf("result = %q, want %q", rr.Result, audit.ResultDenied)
	}
	if rr.Status != http.StatusPreconditionRequired {
		t.Fatalf("status in the record = %d", rr.Status)
	}
	if _, ok := rr.Details["confirmation"]; ok {
		t.Fatalf("a refused call recorded a confirmation method: %v", rr.Details)
	}
}

// auditRecordFor returns the newest audit record whose action ends in suffix.
func (e *env) auditRecordFor(t *testing.T, suffix string) audit.Record {
	t.Helper()
	records, _, err := e.audit.List(audit.Filter{Limit: 100})
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range records {
		if strings.HasSuffix(r.Action, suffix) {
			return r
		}
	}
	t.Fatalf("no audit record for an action ending in %q: %+v", suffix, records)
	return audit.Record{}
}

func TestNonRiskyActionDoesNotNeedConfirmation(t *testing.T) {
	e := newEnv(t)
	if _, err := e.settings.Update(boolPtr(true), nil); err != nil {
		t.Fatal(err)
	}
	webID := e.fake.Containers[0].ID
	if rec := e.do("POST", "/v1/containers/"+webID+"/start", withKey(e.operatorKey)); rec.Code != http.StatusOK {
		t.Fatalf("start = %d (%s)", rec.Code, rec.Body.String())
	}
}

func TestConfirmationOffByDefaultInThisEnv(t *testing.T) {
	e := newEnv(t)
	webID := e.fake.Containers[0].ID
	if rec := e.do("POST", "/v1/containers/"+webID+"/stop", withKey(e.adminKey)); rec.Code != http.StatusOK {
		t.Fatalf("stop = %d", rec.Code)
	}
}

func boolPtr(b bool) *bool { return &b }

// ------------------------------------------------------------ error shape

func TestUnknownEndpointUsesTheErrorEnvelope(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/v1/does-not-exist", withKey(e.adminKey))
	if code := assertErrorEnvelope(t, rec, http.StatusNotFound); code != codeNotFound {
		t.Fatalf("code = %q", code)
	}
}

func TestDockerNotFoundBecomesResourceNotFound(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/v1/containers/deadbeefcafe", withKey(e.viewerKey))
	if code := assertErrorEnvelope(t, rec, http.StatusNotFound); code != "container_not_found" {
		t.Fatalf("code = %q, want container_not_found", code)
	}
}

func TestDaemonUnavailableBecomes502(t *testing.T) {
	e := newEnv(t)
	e.fake.Errs["ContainerList"] = fmt.Errorf("%w: dial unix", dockerx.ErrUnavailable)

	rec := e.do("GET", "/v1/containers", withKey(e.viewerKey))
	if code := assertErrorEnvelope(t, rec, http.StatusBadGateway); code != codeDockerUnavailable {
		t.Fatalf("code = %q", code)
	}
}

func TestSwarmEndpointsReturnNotAManager(t *testing.T) {
	e := newEnv(t)
	for _, path := range []string{"/v1/services", "/v1/services/abc/tasks"} {
		rec := e.do("GET", path, withKey(e.viewerKey))
		if code := assertErrorEnvelope(t, rec, http.StatusConflict); code != codeNotAManager {
			t.Fatalf("%s: code = %q, want not_a_manager", path, code)
		}
	}
	rec := e.do("POST", "/v1/services/abc/scale", withKey(e.operatorKey),
		withJSON(map[string]any{"replicas": 3}))
	if code := assertErrorEnvelope(t, rec, http.StatusConflict); code != codeNotAManager {
		t.Fatalf("scale: code = %q", code)
	}
}

func TestSwarmInfoWorksOnANonManager(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/v1/swarm", withKey(e.viewerKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	body := decode[map[string]any](t, rec)
	if body["is_manager"] != false {
		t.Fatalf("is_manager = %v", body["is_manager"])
	}
}

// ------------------------------------------------------------ pagination

func TestPaginationWalksTheWholeList(t *testing.T) {
	e := newEnv(t)
	// 7 volumes, pages of 3.
	e.fake.Volumes = nil
	for i := 0; i < 7; i++ {
		e.fake.Volumes = append(e.fake.Volumes, dockerx.Volume{Name: fmt.Sprintf("vol-%02d", i), Driver: "local"})
	}

	seen := []string{}
	cursor := ""
	for page := 0; page < 10; page++ {
		path := "/v1/volumes?limit=3"
		if cursor != "" {
			path += "&cursor=" + cursor
		}
		rec := e.do("GET", path, withKey(e.viewerKey))
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d (%s)", rec.Code, rec.Body.String())
		}
		var body struct {
			Items      []volumeDTO `json:"items"`
			NextCursor string      `json:"next_cursor"`
			Total      int         `json:"total"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		if body.Total != 7 {
			t.Fatalf("total = %d, want 7", body.Total)
		}
		for _, v := range body.Items {
			seen = append(seen, v.Name)
		}
		if body.NextCursor == "" {
			break
		}
		if len(body.Items) != 3 {
			t.Fatalf("a non-final page had %d items", len(body.Items))
		}
		cursor = body.NextCursor
	}
	if len(seen) != 7 {
		t.Fatalf("walked %d volumes, want 7: %v", len(seen), seen)
	}
	for i, name := range seen {
		if want := fmt.Sprintf("vol-%02d", i); name != want {
			t.Fatalf("item %d = %q, want %q", i, name, want)
		}
	}
}

func TestPaginationRejectsBadInput(t *testing.T) {
	e := newEnv(t)
	for _, q := range []string{"?limit=0", "?limit=100000", "?limit=abc", "?cursor=not-base64!"} {
		rec := e.do("GET", "/v1/volumes"+q, withKey(e.viewerKey))
		if code := assertErrorEnvelope(t, rec, http.StatusUnprocessableEntity); code != codeValidationFailed {
			t.Fatalf("%s: code = %q status %d", q, code, rec.Code)
		}
	}
}

func TestCursorRoundTrip(t *testing.T) {
	for _, n := range []int{0, 1, 50, 999999} {
		got, err := decodeCursor(encodeCursor(n))
		if err != nil || got != n {
			t.Fatalf("cursor round trip for %d: got %d, err %v", n, got, err)
		}
	}
	if _, err := decodeCursor("Zm9v"); err == nil {
		t.Fatal("a cursor without the o: prefix was accepted")
	}
}

// --------------------------------------------------------- container flow

func TestContainerListCarriesTheRowFigures(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/v1/containers", withKey(e.viewerKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	var body struct {
		Items []containerDTO `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Items) != 2 {
		t.Fatalf("got %d containers", len(body.Items))
	}
	web := body.Items[0]
	if web.Name != "agentzero-test-web" || web.Health != "healthy" || web.CPUPercent == 0 {
		t.Fatalf("web row = %+v", web)
	}
	if web.UptimeSeconds <= 0 {
		t.Errorf("uptime_seconds = %d", web.UptimeSeconds)
	}
	db := body.Items[1]
	if db.RestartCount != 4 || db.ExitCode != 1 {
		t.Fatalf("db row = %+v", db)
	}
	if db.FinishedAt == nil {
		t.Error("an exited container must carry finished_at")
	}
	if web.FinishedAt != nil {
		t.Errorf("a running container must not carry finished_at, got %v", web.FinishedAt)
	}
}

func TestContainerListFilters(t *testing.T) {
	e := newEnv(t)
	for _, tc := range []struct {
		query string
		want  int
	}{
		{"?state=running", 1},
		{"?state=exited", 1},
		{"?stack=demo", 2},
		{"?q=web", 1},
		{"?q=nothing-matches", 0},
	} {
		rec := e.do("GET", "/v1/containers"+tc.query, withKey(e.viewerKey))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status %d", tc.query, rec.Code)
		}
		var body struct {
			Items []containerDTO `json:"items"`
		}
		_ = json.Unmarshal(rec.Body.Bytes(), &body)
		if len(body.Items) != tc.want {
			t.Fatalf("%s: got %d rows, want %d", tc.query, len(body.Items), tc.want)
		}
	}
	rec := e.do("GET", "/v1/containers?state=bogus", withKey(e.viewerKey))
	assertErrorEnvelope(t, rec, http.StatusUnprocessableEntity)
}

func TestContainerDetailExposesEnvNamesOnly(t *testing.T) {
	e := newEnv(t)
	webID := e.fake.Containers[0].ID

	rec := e.do("GET", "/v1/containers/"+webID, withKey(e.viewerKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "super-secret") {
		t.Fatalf("the detail endpoint leaked an environment value: %s", rec.Body.String())
	}
	var body struct {
		EnvNames []string `json:"env_names"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	want := []string{"DB_PASSWORD", "NGINX_HOST", "PATH"}
	if strings.Join(body.EnvNames, ",") != strings.Join(want, ",") {
		t.Fatalf("env_names = %v, want %v", body.EnvNames, want)
	}
}

func TestEnvValuesAreAdminOnlyAndAudited(t *testing.T) {
	e := newEnv(t)
	webID := e.fake.Containers[0].ID

	if rec := e.do("GET", "/v1/containers/"+webID+"/env", withKey(e.operatorKey)); rec.Code != http.StatusForbidden {
		t.Fatalf("operator got %d", rec.Code)
	}
	rec := e.do("GET", "/v1/containers/"+webID+"/env", withKey(e.adminKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("admin got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "super-secret") {
		t.Fatal("the admin env endpoint did not return values")
	}

	records, _, err := e.audit.List(audit.Filter{Limit: 50})
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, r := range records {
		if strings.Contains(r.Action, "/env") && r.Result == audit.ResultOK {
			found = true
		}
	}
	if !found {
		t.Fatal("reading environment values was not audited")
	}
}

func TestContainerActionsReachDocker(t *testing.T) {
	for _, tc := range []struct {
		path   string
		method string
	}{
		{"/start", "ContainerStart"},
		{"/restart", "ContainerRestart"},
		{"/pause", "ContainerPause"},
		{"/unpause", "ContainerUnpause"},
	} {
		t.Run(tc.path, func(t *testing.T) {
			e := newEnv(t)
			webID := e.fake.Containers[0].ID
			rec := e.do("POST", "/v1/containers/"+webID+tc.path, withKey(e.operatorKey))
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d (%s)", rec.Code, rec.Body.String())
			}
			if !e.fake.Called(tc.method) {
				t.Fatalf("%s was not called", tc.method)
			}
		})
	}
}

func TestStopTimeoutIsValidatedAndPassedThrough(t *testing.T) {
	e := newEnv(t)
	webID := e.fake.Containers[0].ID

	rec := e.do("POST", "/v1/containers/"+webID+"/stop?timeout=notanumber", withKey(e.adminKey))
	assertErrorEnvelope(t, rec, http.StatusUnprocessableEntity)

	rec = e.do("POST", "/v1/containers/"+webID+"/stop?timeout=99999", withKey(e.adminKey))
	assertErrorEnvelope(t, rec, http.StatusUnprocessableEntity)

	rec = e.do("POST", "/v1/containers/"+webID+"/stop?timeout=25", withKey(e.adminKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	for _, c := range e.fake.Calls() {
		if c.Method == "ContainerStop" {
			if c.Args[1] != 25 {
				t.Fatalf("timeout reached Docker as %v, want 25", c.Args[1])
			}
			return
		}
	}
	t.Fatal("ContainerStop was not called")
}

func TestContainerImpact(t *testing.T) {
	e := newEnv(t)
	webID := e.fake.Containers[0].ID
	rec := e.do("GET", "/v1/containers/"+webID+"/impact", withKey(e.viewerKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	body := decode[map[string]any](t, rec)
	ports, ok := body["published_ports"].([]any)
	if !ok || len(ports) != 1 {
		t.Fatalf("published_ports = %v", body["published_ports"])
	}
	same, ok := body["same_stack"].([]any)
	if !ok || len(same) != 1 {
		t.Fatalf("same_stack = %v", body["same_stack"])
	}
}

func TestContainerLogs(t *testing.T) {
	e := newEnv(t)
	webID := e.fake.Containers[0].ID

	rec := e.do("GET", "/v1/containers/"+webID+"/logs?tail=50", withKey(e.viewerKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d (%s)", rec.Code, rec.Body.String())
	}
	var body struct {
		Lines []dockerx.LogLine `json:"lines"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Lines) != 2 {
		t.Fatalf("got %d lines", len(body.Lines))
	}

	rec = e.do("GET", "/v1/containers/"+webID+"/logs?stream=stderr", withKey(e.viewerKey))
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if len(body.Lines) != 1 || body.Lines[0].Stream != "stderr" {
		t.Fatalf("stderr filter returned %+v", body.Lines)
	}

	rec = e.do("GET", "/v1/containers/"+webID+"/logs?q=upstream", withKey(e.viewerKey))
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if len(body.Lines) != 1 {
		t.Fatalf("q filter returned %d lines", len(body.Lines))
	}

	for _, q := range []string{"?tail=0", "?tail=abc", "?stream=both", "?since=yesterday"} {
		rec := e.do("GET", "/v1/containers/"+webID+"/logs"+q, withKey(e.viewerKey))
		assertErrorEnvelope(t, rec, http.StatusUnprocessableEntity)
	}
}

// ------------------------------------------------------- input validation

func TestInputValidation(t *testing.T) {
	e := newEnv(t)

	t.Run("bad container id", func(t *testing.T) {
		rec := e.do("GET", "/v1/containers/..%2Fetc%2Fpasswd", withKey(e.viewerKey))
		if rec.Code != http.StatusUnprocessableEntity && rec.Code != http.StatusNotFound {
			t.Fatalf("status = %d (%s)", rec.Code, rec.Body.String())
		}
	})

	t.Run("volume name", func(t *testing.T) {
		for _, name := range []string{"", "has space", "-leading-dash", strings.Repeat("a", 200), "../escape"} {
			rec := e.do("POST", "/v1/volumes", withKey(e.adminKey), withJSON(map[string]any{"name": name}))
			if code := assertErrorEnvelope(t, rec, http.StatusUnprocessableEntity); code != codeValidationFailed {
				t.Fatalf("name %q accepted with code %q", name, code)
			}
		}
		rec := e.do("POST", "/v1/volumes", withKey(e.adminKey),
			withJSON(map[string]any{"name": "agentzero-test-vol", "driver": "local"}))
		if rec.Code != http.StatusCreated {
			t.Fatalf("valid volume rejected: %d (%s)", rec.Code, rec.Body.String())
		}
	})

	t.Run("network subnet", func(t *testing.T) {
		rec := e.do("POST", "/v1/networks", withKey(e.adminKey),
			withJSON(map[string]any{"name": "agentzero-test-net", "subnet": "not-a-subnet"}))
		assertErrorEnvelope(t, rec, http.StatusUnprocessableEntity)

		rec = e.do("POST", "/v1/networks", withKey(e.adminKey),
			withJSON(map[string]any{"name": "agentzero-test-net", "subnet": "10.77.0.0/24", "driver": "bridge"}))
		if rec.Code != http.StatusCreated {
			t.Fatalf("valid network rejected: %d (%s)", rec.Code, rec.Body.String())
		}
	})

	t.Run("image ref", func(t *testing.T) {
		for _, ref := range []string{"", "--privileged", "foo bar", "a/../b", strings.Repeat("x", 300)} {
			rec := e.do("POST", "/v1/images/pull", withKey(e.operatorKey), withJSON(map[string]any{"ref": ref}))
			if rec.Code != http.StatusUnprocessableEntity {
				t.Fatalf("ref %q accepted: %d", ref, rec.Code)
			}
		}
	})

	t.Run("malformed json", func(t *testing.T) {
		rec := e.do("POST", "/v1/volumes", withKey(e.adminKey), withRawBody("{nope"))
		if code := assertErrorEnvelope(t, rec, http.StatusBadRequest); code != codeBadRequest {
			t.Fatalf("code = %q", code)
		}
	})

	t.Run("unknown field", func(t *testing.T) {
		rec := e.do("POST", "/v1/volumes", withKey(e.adminKey),
			withRawBody(`{"name":"ok","surprise":true}`))
		assertErrorEnvelope(t, rec, http.StatusBadRequest)
	})

	t.Run("oversize body", func(t *testing.T) {
		big := `{"name":"` + strings.Repeat("a", int(e.server.MaxBodyBytes)+100) + `"}`
		rec := e.do("POST", "/v1/volumes", withKey(e.adminKey), withRawBody(big))
		if rec.Code != http.StatusRequestEntityTooLarge && rec.Code != http.StatusBadRequest {
			t.Fatalf("status = %d", rec.Code)
		}
	})

	t.Run("wrong content type", func(t *testing.T) {
		rec := e.do("POST", "/v1/volumes", withKey(e.adminKey),
			withRawBody(`{"name":"ok"}`), withHeader("Content-Type", "text/plain"))
		assertErrorEnvelope(t, rec, http.StatusUnsupportedMediaType)
	})

	t.Run("scale replicas", func(t *testing.T) {
		for _, body := range []map[string]any{{}, {"replicas": -1}, {"replicas": 10000}} {
			rec := e.do("POST", "/v1/services/abc/scale", withKey(e.operatorKey), withJSON(body))
			assertErrorEnvelope(t, rec, http.StatusUnprocessableEntity)
		}
	})

	t.Run("alert rule bounds", func(t *testing.T) {
		rec := e.do("PATCH", "/v1/alert-rules/cpu_high", withKey(e.adminKey),
			withJSON(map[string]any{"threshold": 900}))
		assertErrorEnvelope(t, rec, http.StatusUnprocessableEntity)

		rec = e.do("PATCH", "/v1/alert-rules/cpu_high", withKey(e.adminKey),
			withJSON(map[string]any{"window_seconds": 1000000}))
		assertErrorEnvelope(t, rec, http.StatusUnprocessableEntity)
	})
}

func TestDefaultNetworkCannotBeRemoved(t *testing.T) {
	e := newEnv(t)
	rec := e.do("DELETE", "/v1/networks/n0", withKey(e.adminKey))
	if code := assertErrorEnvelope(t, rec, http.StatusConflict); code != codeConflict {
		t.Fatalf("code = %q", code)
	}
	if e.fake.Called("NetworkRemove") {
		t.Fatal("the default network was removed anyway")
	}
}

func TestAttachedNetworkCannotBeRemoved(t *testing.T) {
	e := newEnv(t)
	rec := e.do("DELETE", "/v1/networks/n1", withKey(e.adminKey))
	assertErrorEnvelope(t, rec, http.StatusConflict)
}

// ---------------------------------------------------------- image summary

func TestImageListCarriesSummaryAndInUse(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/v1/images", withKey(e.viewerKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	var body struct {
		Items   []imageDTO    `json:"items"`
		Summary imagesSummary `json:"summary"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Summary.TotalBytes == 0 || body.Summary.ReclaimableBytes == 0 {
		t.Fatalf("summary = %+v", body.Summary)
	}
	for _, img := range body.Items {
		if img.ID == "sha256:img1" {
			if len(img.InUseBy) != 1 || img.InUseBy[0] != "agentzero-test-web" {
				t.Fatalf("in_use_by = %v", img.InUseBy)
			}
		}
	}
}

// ------------------------------------------------- volume and network summaries

// volumeListBody is GET /v1/volumes with its summary block.
type volumeListBody struct {
	Items      []volumeDTO    `json:"items"`
	NextCursor string         `json:"next_cursor"`
	Total      int            `json:"total"`
	Summary    volumesSummary `json:"summary"`
}

func (e *env) volumeList(path string) volumeListBody {
	e.t.Helper()
	rec := e.do("GET", path, withKey(e.viewerKey))
	if rec.Code != http.StatusOK {
		e.t.Fatalf("GET %s = %d (%s)", path, rec.Code, rec.Body.String())
	}
	var body volumeListBody
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		e.t.Fatal(err)
	}
	return body
}

func TestVolumeListCarriesSummary(t *testing.T) {
	e := newEnv(t)
	// agentzero-test-data is mounted by the web container; the other three
	// are not, and one of them is on a driver that reports no size.
	e.fake.Volumes = append(e.fake.Volumes,
		dockerx.Volume{Name: "spare-a", Driver: "local", Size: 1000},
		dockerx.Volume{Name: "spare-b", Driver: "local", Size: 2000},
		dockerx.Volume{Name: "nfs-share", Driver: "nfs", Size: 0},
	)

	body := e.volumeList("/v1/volumes")
	if body.Summary.Count != 4 || body.Total != 4 {
		t.Fatalf("summary = %+v, total = %d", body.Summary, body.Total)
	}
	if want := int64(4096 + 1000 + 2000); body.Summary.TotalBytes != want {
		t.Errorf("total_bytes = %d, want %d", body.Summary.TotalBytes, want)
	}
	if body.Summary.Unmounted != 3 {
		t.Errorf("unmounted = %d, want 3", body.Summary.Unmounted)
	}
	// The mounted one really is the one that is not counted.
	for _, v := range body.Items {
		if v.Name == "agentzero-test-data" && len(v.MountedBy) == 0 {
			t.Errorf("%s should be mounted by a container", v.Name)
		}
	}
}

func TestVolumeSummaryCoversTheHostNotThePage(t *testing.T) {
	e := newEnv(t)
	e.fake.Volumes = nil
	for i := 0; i < 6; i++ {
		e.fake.Volumes = append(e.fake.Volumes,
			dockerx.Volume{Name: fmt.Sprintf("vol-%02d", i), Driver: "local", Size: 100})
	}

	first := e.volumeList("/v1/volumes?limit=2")
	if len(first.Items) != 2 {
		t.Fatalf("page holds %d items", len(first.Items))
	}
	if first.Summary.Count != 6 || first.Summary.Unmounted != 6 || first.Summary.TotalBytes != 600 {
		t.Fatalf("summary follows the page: %+v", first.Summary)
	}

	// The last page reports the same figures.
	last := e.volumeList("/v1/volumes?limit=2&cursor=" + first.NextCursor)
	if last.Summary != first.Summary {
		t.Fatalf("summary changed between pages: %+v then %+v", first.Summary, last.Summary)
	}

	// With a filter it covers everything the filter kept, not the page.
	filtered := e.volumeList("/v1/volumes?q=vol-0&limit=1")
	if filtered.Summary.Count != 6 || filtered.Summary.TotalBytes != 600 {
		t.Fatalf("filtered summary = %+v", filtered.Summary)
	}
	narrow := e.volumeList("/v1/volumes?q=vol-03")
	if narrow.Summary.Count != 1 || narrow.Total != 1 || narrow.Summary.TotalBytes != 100 {
		t.Fatalf("narrow summary = %+v, total = %d", narrow.Summary, narrow.Total)
	}
}

// networkListBody is GET /v1/networks with its summary block.
type networkListBody struct {
	Items      []dockerx.Network `json:"items"`
	NextCursor string            `json:"next_cursor"`
	Total      int               `json:"total"`
	Summary    networksSummary   `json:"summary"`
}

func (e *env) networkList(path string) networkListBody {
	e.t.Helper()
	rec := e.do("GET", path, withKey(e.viewerKey))
	if rec.Code != http.StatusOK {
		e.t.Fatalf("GET %s = %d (%s)", path, rec.Code, rec.Body.String())
	}
	var body networkListBody
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		e.t.Fatal(err)
	}
	return body
}

func TestNetworkListCarriesSummary(t *testing.T) {
	e := newEnv(t)
	// bridge is a default network with nothing attached, demo_default has 2.
	body := e.networkList("/v1/networks")
	if body.Summary.Count != 2 || body.Total != 2 {
		t.Fatalf("summary = %+v, total = %d", body.Summary, body.Total)
	}
	if body.Summary.Unused != 1 {
		t.Fatalf("unused = %d, want 1 (default networks are counted too)", body.Summary.Unused)
	}
}

func TestNetworkSummaryCoversTheHostNotThePage(t *testing.T) {
	e := newEnv(t)
	for i := 0; i < 5; i++ {
		e.fake.Networks = append(e.fake.Networks, dockerx.Network{
			ID: fmt.Sprintf("nx%d", i), Name: fmt.Sprintf("spare-%d", i), Driver: "bridge",
		})
	}

	first := e.networkList("/v1/networks?limit=3")
	if len(first.Items) != 3 {
		t.Fatalf("page holds %d items", len(first.Items))
	}
	if first.Summary.Count != 7 || first.Summary.Unused != 6 {
		t.Fatalf("summary follows the page: %+v", first.Summary)
	}
	last := e.networkList("/v1/networks?limit=3&cursor=" + first.NextCursor)
	if last.Summary != first.Summary {
		t.Fatalf("summary changed between pages: %+v then %+v", first.Summary, last.Summary)
	}

	filtered := e.networkList("/v1/networks?q=spare&limit=2")
	if filtered.Summary.Count != 5 || filtered.Summary.Unused != 5 || filtered.Total != 5 {
		t.Fatalf("filtered summary = %+v, total = %d", filtered.Summary, filtered.Total)
	}
	attached := e.networkList("/v1/networks?q=demo_default")
	if attached.Summary.Count != 1 || attached.Summary.Unused != 0 {
		t.Fatalf("attached summary = %+v", attached.Summary)
	}
}

// ---------------------------------------------------------------- stacks

func TestStackListCarriesPerServiceCounts(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/v1/stacks", withKey(e.viewerKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d (%s)", rec.Code, rec.Body.String())
	}
	var body struct {
		Items []struct {
			Name     string `json:"name"`
			Services []struct {
				Name    string `json:"name"`
				Running int    `json:"running"`
				Total   int    `json:"total"`
			} `json:"services"`
			ServicesRunning int `json:"services_running"`
			ServicesTotal   int `json:"services_total"`
		} `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Items) != 1 || body.Items[0].Name != "demo" {
		t.Fatalf("items = %+v", body.Items)
	}
	demo := body.Items[0]
	if len(demo.Services) != 2 {
		t.Fatalf("services = %+v", demo.Services)
	}
	// db is exited, web is running.
	for _, svc := range demo.Services {
		wantRunning := 0
		if svc.Name == "web" {
			wantRunning = 1
		}
		if svc.Total != 1 || svc.Running != wantRunning {
			t.Errorf("service %s = %d/%d, want %d/1", svc.Name, svc.Running, svc.Total, wantRunning)
		}
	}
	if demo.ServicesRunning != 1 || demo.ServicesTotal != 2 {
		t.Errorf("aggregate = %d/%d, want 1/2", demo.ServicesRunning, demo.ServicesTotal)
	}
}

// -------------------------------------------------------------- settings

func TestSettingsRoundTrip(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/v1/settings", withKey(e.viewerKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	body := decode[map[string]any](t, rec)
	if body["push_relay_status"] != "not_configured" {
		t.Fatalf("push_relay_status = %v", body["push_relay_status"])
	}

	rec = e.do("PATCH", "/v1/settings", withKey(e.adminKey),
		withJSON(map[string]any{"require_biometric_for_risky": true}))
	if rec.Code != http.StatusOK {
		t.Fatalf("patch status = %d", rec.Code)
	}
	if !e.settings.Get().RequireBiometricForRisky {
		t.Fatal("the setting was not persisted")
	}
}

func TestAgentUpdate(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/v1/agent/update", withKey(e.viewerKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	body := decode[map[string]any](t, rec)
	if body["current_version"] != "test" || body["latest_version"] != "unknown" {
		t.Fatalf("body = %v", body)
	}

	rec = e.do("POST", "/v1/agent/update", withKey(e.adminKey))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("post status = %d (%s)", rec.Code, rec.Body.String())
	}
	jobID := decode[map[string]any](t, rec)["job_id"].(string)
	job := waitForJob(t, e, jobID)
	if job.Status != "failed" {
		t.Fatalf("job status = %s", job.Status)
	}
	if job.Error == nil || job.Error.Code != codeNotConfigured {
		t.Fatalf("job error = %+v", job.Error)
	}
}
