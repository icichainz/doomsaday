package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"agent_zero/internal/audit"
	"agent_zero/internal/jobs"
)

// holdFake makes the fake daemon block in method until the call's context
// ends or the returned release function runs.
func holdFake(t *testing.T, e *env, methods ...string) (entered chan string, release func()) {
	t.Helper()
	entered = make(chan string, len(methods))
	ch := make(chan struct{})
	e.fake.Hold = map[string]chan struct{}{}
	for _, m := range methods {
		e.fake.Hold[m] = ch
	}
	e.fake.Entered = entered
	released := false
	release = func() {
		if !released {
			released = true
			close(ch)
		}
	}
	t.Cleanup(release)
	return entered, release
}

// startJobOver POSTs to a job endpoint and returns the new job id.
func startJobOver(t *testing.T, e *env, path, key string, opts ...reqOpt) string {
	t.Helper()
	rec := e.do("POST", path, append([]reqOpt{withKey(key)}, opts...)...)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("POST %s = %d (%s)", path, rec.Code, rec.Body.String())
	}
	id, _ := decode[map[string]any](t, rec)["job_id"].(string)
	if id == "" {
		t.Fatalf("no job_id from %s", path)
	}
	return id
}

func waitEntered(t *testing.T, entered chan string, want string) {
	t.Helper()
	select {
	case got := <-entered:
		if got != want {
			t.Fatalf("entered %q, want %q", got, want)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("%s never started", want)
	}
}

type cancelResponse struct {
	JobID string   `json:"job_id"`
	Job   jobs.Job `json:"job"`
}

func TestCancelARunningPull(t *testing.T) {
	e := newEnv(t)
	entered, _ := holdFake(t, e, "ImagePull")

	id := startJobOver(t, e, "/v1/images/pull", e.operatorKey,
		withJSON(map[string]any{"ref": "alpine:3.20"}))
	waitEntered(t, entered, "ImagePull")

	stream, closeStream := openStream(t, e, "/v1/jobs/"+id+"/events", e.viewerKey)
	defer closeStream()

	rec := e.do("POST", "/v1/jobs/"+id+"/cancel", withKey(e.operatorKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("cancel = %d (%s)", rec.Code, rec.Body.String())
	}
	body := decode[cancelResponse](t, rec)
	if body.JobID != id || body.Job.Status != jobs.StatusCancelled {
		t.Fatalf("cancel body = %+v", body)
	}
	if body.Job.Result["cancelled"] != true || !body.Job.CancelRequested {
		t.Fatalf("result = %v, cancel_requested = %v", body.Job.Result, body.Job.CancelRequested)
	}
	if by := body.Job.Result["cancelled_by"]; by != e.deviceIDFor(e.operatorKey) {
		t.Errorf("cancelled_by = %v", by)
	}
	if body.Job.Error == nil || body.Job.Error.Code != jobs.CodeCancelled {
		t.Errorf("error = %+v", body.Job.Error)
	}

	// The stream ends with a done event that carries the cancelled flag.
	frames := readSSE(t, stream, 50, 5*time.Second)
	if len(frames) == 0 {
		t.Fatal("no frames")
	}
	last := frames[len(frames)-1]
	if last.Event != "done" {
		t.Fatalf("last frame = %q (%+v)", last.Event, frames)
	}
	var done map[string]any
	if err := json.Unmarshal([]byte(last.Data), &done); err != nil {
		t.Fatal(err)
	}
	result, _ := done["result"].(map[string]any)
	if done["status"] != "cancelled" || result["cancelled"] != true {
		t.Fatalf("done event = %s", last.Data)
	}

	// GET /v1/jobs/{id} says the same.
	rec = e.do("GET", "/v1/jobs/"+id, withKey(e.viewerKey))
	got := decode[map[string]any](t, rec)
	if got["status"] != "cancelled" {
		t.Fatalf("GET job = %v", got)
	}

	rr := e.auditRecordFor(t, "/cancel")
	if rr.Action != "POST /v1/jobs/{id}/cancel" || rr.Target != id {
		t.Fatalf("audit = %+v", rr)
	}
	if rr.Result != audit.ResultOK || rr.Status != http.StatusOK {
		t.Fatalf("audit result = %q status %d", rr.Result, rr.Status)
	}
	if rr.Details["job_type"] != "image_pull" || rr.Details["job_status"] != "cancelled" {
		t.Fatalf("audit details = %v", rr.Details)
	}
	if rr.DeviceID != e.deviceIDFor(e.operatorKey) {
		t.Errorf("audit device = %q", rr.DeviceID)
	}
}

func TestCancelAFinishedJobIsAConflict(t *testing.T) {
	e := newEnv(t)
	id := startJobOver(t, e, "/v1/images/pull", e.operatorKey,
		withJSON(map[string]any{"ref": "alpine:3.20"}))
	if job := waitForJob(t, e, id); job.Status != jobs.StatusSucceeded {
		t.Fatalf("job = %+v", job)
	}

	rec := e.do("POST", "/v1/jobs/"+id+"/cancel", withKey(e.adminKey))
	if code := assertErrorEnvelope(t, rec, http.StatusConflict); code != "conflict" {
		t.Fatalf("code = %q", code)
	}
	var env struct {
		Error struct {
			Details map[string]any `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil {
		t.Fatal(err)
	}
	if env.Error.Details["status"] != "succeeded" {
		t.Fatalf("details = %v", env.Error.Details)
	}
	if job, _ := e.server.Jobs.Get(id); job.Status != jobs.StatusSucceeded {
		t.Fatalf("a refused cancel changed the job to %q", job.Status)
	}
	rr := e.auditRecordFor(t, "/cancel")
	if rr.Result != audit.ResultError || rr.Status != http.StatusConflict {
		t.Fatalf("audit = %+v", rr)
	}
}

func TestViewerCannotCancel(t *testing.T) {
	e := newEnv(t)
	entered, release := holdFake(t, e, "ImagePull")
	id := startJobOver(t, e, "/v1/images/pull", e.operatorKey,
		withJSON(map[string]any{"ref": "alpine:3.20"}))
	waitEntered(t, entered, "ImagePull")

	rec := e.do("POST", "/v1/jobs/"+id+"/cancel", withKey(e.viewerKey))
	if code := assertErrorEnvelope(t, rec, http.StatusForbidden); code != "forbidden" {
		t.Fatalf("code = %q", code)
	}
	if job, _ := e.server.Jobs.Get(id); job.FinishedAt != nil || job.CancelRequested {
		t.Fatalf("a viewer's cancel reached the job: %+v", job)
	}
	rr := e.auditRecordFor(t, "/cancel")
	if rr.Result != audit.ResultDenied || rr.Status != http.StatusForbidden {
		t.Fatalf("audit = %+v", rr)
	}

	release()
	if job := waitForJob(t, e, id); job.Status != jobs.StatusSucceeded {
		t.Fatalf("job = %+v", job)
	}
}

func TestCancelUnknownJob(t *testing.T) {
	e := newEnv(t)
	rec := e.do("POST", "/v1/jobs/abc123/cancel", withKey(e.operatorKey))
	if code := assertErrorEnvelope(t, rec, http.StatusNotFound); code != "job_not_found" {
		t.Fatalf("code = %q", code)
	}
	rec = e.do("POST", "/v1/jobs/..%2f/cancel", withKey(e.operatorKey))
	if rec.Code == http.StatusOK || rec.Code == http.StatusAccepted {
		t.Fatalf("a malformed id was accepted: %d", rec.Code)
	}
}

// A runner that takes longer than CancelWait to wind down gets a 202 with the
// job still running and cancel_requested set; it still ends cancelled.
func TestSlowCancelAnswers202(t *testing.T) {
	e := newEnv(t)
	e.server.CancelWait = 20 * time.Millisecond
	started := make(chan struct{})
	job, err := e.server.Jobs.Run("test", "t", "", func(h *jobs.Handle) error {
		close(started)
		<-h.Ctx.Done()
		time.Sleep(200 * time.Millisecond)
		return h.Ctx.Err()
	})
	if err != nil {
		t.Fatal(err)
	}
	<-started

	rec := e.do("POST", "/v1/jobs/"+job.ID+"/cancel", withKey(e.operatorKey))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("cancel = %d (%s)", rec.Code, rec.Body.String())
	}
	body := decode[cancelResponse](t, rec)
	if body.Job.FinishedAt != nil || !body.Job.CancelRequested {
		t.Fatalf("job = %+v", body.Job)
	}
	if final := waitForJob(t, e, job.ID); final.Status != jobs.StatusCancelled {
		t.Fatalf("final = %+v", final)
	}
	if rr := e.auditRecordFor(t, "/cancel"); rr.Result != audit.ResultStarted {
		t.Fatalf("audit = %+v", rr)
	}
}

// Every job whose work goes through the Docker daemon stops when cancelled.
// (Stack jobs run the compose binary; compose's own tests cover those.)
func TestEveryDockerJobHonoursCancel(t *testing.T) {
	cases := []struct {
		method, path string
		key          func(*env) string
		opts         []reqOpt
	}{
		{"ImagePull", "/v1/images/pull", func(e *env) string { return e.operatorKey },
			[]reqOpt{withJSON(map[string]any{"ref": "alpine:3.20"})}},
		{"ImagePrune", "/v1/images/prune", func(e *env) string { return e.adminKey }, nil},
		{"VolumePrune", "/v1/volumes/prune", func(e *env) string { return e.adminKey }, nil},
		{"NetworkPrune", "/v1/networks/prune", func(e *env) string { return e.adminKey }, nil},
		{"ServiceUpdate", "/v1/services/svc1/update", func(e *env) string { return e.operatorKey },
			[]reqOpt{withJSON(map[string]any{"force": true})}},
		{"ServiceRollback", "/v1/services/svc1/rollback", func(e *env) string { return e.operatorKey }, nil},
	}
	for _, c := range cases {
		t.Run(c.method, func(t *testing.T) {
			e := newEnv(t)
			e.fake.Swarm.Manager = true
			entered, _ := holdFake(t, e, c.method)
			id := startJobOver(t, e, c.path, c.key(e), c.opts...)
			waitEntered(t, entered, c.method)

			rec := e.do("POST", "/v1/jobs/"+id+"/cancel", withKey(e.operatorKey))
			if rec.Code != http.StatusOK {
				t.Fatalf("cancel = %d (%s)", rec.Code, rec.Body.String())
			}
			if st := decode[cancelResponse](t, rec).Job.Status; st != jobs.StatusCancelled {
				t.Fatalf("status = %q", st)
			}
		})
	}
}
