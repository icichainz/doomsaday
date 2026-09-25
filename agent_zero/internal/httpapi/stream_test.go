package httpapi

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"agent_zero/internal/dockerx"
	"agent_zero/internal/jobs"
)

// waitForJob polls a job until it finishes.
func waitForJob(t *testing.T, e *env, id string) jobs.Job {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		job, ok := e.server.Jobs.Get(id)
		if !ok {
			t.Fatalf("job %s disappeared", id)
		}
		if job.FinishedAt != nil {
			return job
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("job %s never finished", id)
	return jobs.Job{}
}

// sseEvent is one parsed frame.
type sseEvent struct {
	ID    string
	Event string
	Data  string
}

// readSSE reads frames from an open stream until want frames are seen or the
// context expires. It also checks the framing: every frame must carry an id,
// an event name and at least one data line, ended by a blank line.
func readSSE(t *testing.T, body *bufio.Reader, want int, deadline time.Duration) []sseEvent {
	t.Helper()
	done := make(chan []sseEvent, 1)
	go func() {
		var out []sseEvent
		cur := sseEvent{}
		var data []string
		for {
			line, err := body.ReadString('\n')
			if err != nil {
				done <- out
				return
			}
			line = strings.TrimRight(line, "\r\n")
			switch {
			case line == "":
				if cur.Event != "" || len(data) > 0 {
					cur.Data = strings.Join(data, "\n")
					out = append(out, cur)
					cur, data = sseEvent{}, nil
					if len(out) >= want {
						done <- out
						return
					}
				}
			case strings.HasPrefix(line, ":"):
				// keep-alive comment
			case strings.HasPrefix(line, "id: "):
				cur.ID = strings.TrimPrefix(line, "id: ")
			case strings.HasPrefix(line, "event: "):
				cur.Event = strings.TrimPrefix(line, "event: ")
			case strings.HasPrefix(line, "data: "):
				data = append(data, strings.TrimPrefix(line, "data: "))
			}
		}
	}()
	select {
	case out := <-done:
		return out
	case <-time.After(deadline):
		t.Fatal("timed out waiting for SSE frames")
		return nil
	}
}

// openStream starts a real server and opens an SSE request against it.
func openStream(t *testing.T, e *env, path, key string) (*bufio.Reader, func()) {
	t.Helper()
	ts := httptest.NewServer(e.handler)

	ctx, cancel := context.WithCancel(context.Background())
	req, err := http.NewRequestWithContext(ctx, "GET", ts.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+key)

	resp, err := ts.Client().Do(req)
	if err != nil {
		cancel()
		ts.Close()
		t.Fatalf("open stream: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		cancel()
		ts.Close()
		t.Fatalf("stream status = %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Errorf("content type = %q, want text/event-stream", ct)
	}
	if cc := resp.Header.Get("Cache-Control"); !strings.Contains(cc, "no-cache") {
		t.Errorf("cache control = %q", cc)
	}
	return bufio.NewReader(resp.Body), func() {
		cancel()
		_ = resp.Body.Close()
		ts.Close()
	}
}

func TestSystemStatsStreamFraming(t *testing.T) {
	e := newEnv(t)
	e.server.StatsInterval = 20 * time.Millisecond

	body, closeStream := openStream(t, e, "/v1/system/stats/stream", e.viewerKey)
	defer closeStream()

	frames := readSSE(t, body, 2, 5*time.Second)
	if len(frames) < 2 {
		t.Fatalf("got %d frames", len(frames))
	}
	for i, f := range frames {
		if f.Event != "stats" {
			t.Fatalf("frame %d event = %q", i, f.Event)
		}
		if f.ID == "" {
			t.Fatalf("frame %d has no id", i)
		}
		var st systemStats
		if err := json.Unmarshal([]byte(f.Data), &st); err != nil {
			t.Fatalf("frame %d data: %v (%s)", i, err, f.Data)
		}
		if st.Containers.Total != 2 {
			t.Fatalf("containers.total = %d", st.Containers.Total)
		}
	}
}

func TestDockerEventsStream(t *testing.T) {
	e := newEnv(t)
	e.fake.EventsQueue = []dockerx.Event{
		{Time: time.Now().UTC(), Type: "container", Action: "start", ActorID: "c1", ActorName: "agentzero-test-web"},
		{Time: time.Now().UTC(), Type: "container", Action: "die", ActorID: "c2", ActorName: "agentzero-test-db"},
	}
	body, closeStream := openStream(t, e, "/v1/events/stream", e.viewerKey)
	defer closeStream()

	frames := readSSE(t, body, 2, 5*time.Second)
	if len(frames) < 2 {
		t.Fatalf("got %d frames", len(frames))
	}
	if frames[0].Event != "docker_event" {
		t.Fatalf("event = %q", frames[0].Event)
	}
	var ev dockerx.Event
	if err := json.Unmarshal([]byte(frames[0].Data), &ev); err != nil {
		t.Fatal(err)
	}
	if ev.Action != "start" {
		t.Fatalf("action = %q", ev.Action)
	}
}

func TestContainerLogsStream(t *testing.T) {
	e := newEnv(t)
	webID := e.fake.Containers[0].ID

	body, closeStream := openStream(t, e, "/v1/containers/"+webID+"/logs/stream", e.viewerKey)
	defer closeStream()

	frames := readSSE(t, body, 2, 5*time.Second)
	if len(frames) < 2 {
		t.Fatalf("got %d frames", len(frames))
	}
	for _, f := range frames {
		if f.Event != "log" {
			t.Fatalf("event = %q", f.Event)
		}
		var line struct {
			TS     string `json:"ts"`
			Stream string `json:"stream"`
			Line   string `json:"line"`
		}
		if err := json.Unmarshal([]byte(f.Data), &line); err != nil {
			t.Fatal(err)
		}
		if line.TS == "" || line.Stream == "" || line.Line == "" {
			t.Fatalf("log frame is missing fields: %+v", line)
		}
	}
}

func TestContainerStatsStream(t *testing.T) {
	e := newEnv(t)
	webID := e.fake.Containers[0].ID

	body, closeStream := openStream(t, e, "/v1/containers/"+webID+"/stats/stream", e.viewerKey)
	defer closeStream()

	frames := readSSE(t, body, 1, 5*time.Second)
	if len(frames) < 1 {
		t.Fatal("no stats frames")
	}
	if frames[0].Event != "stats" {
		t.Fatalf("event = %q", frames[0].Event)
	}
}

// ------------------------------------------------------------ job stream

func TestJobLifecycleAndEventStream(t *testing.T) {
	e := newEnv(t)
	e.fake.PullProgress = []dockerx.PullProgress{
		{ID: "layer1", Status: "Downloading", Current: 50, Total: 100},
		{ID: "layer1", Status: "Download complete", Current: 100, Total: 100},
	}

	rec := e.do("POST", "/v1/images/pull", withKey(e.operatorKey),
		withJSON(map[string]any{"ref": "alpine:3.20"}))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status = %d (%s)", rec.Code, rec.Body.String())
	}
	body := decode[map[string]any](t, rec)
	jobID, _ := body["job_id"].(string)
	if jobID == "" {
		t.Fatalf("no job_id in %v", body)
	}

	job := waitForJob(t, e, jobID)
	if job.Status != jobs.StatusSucceeded {
		t.Fatalf("job status = %s, error %+v", job.Status, job.Error)
	}
	if job.Type != "image_pull" || job.Target != "alpine:3.20" {
		t.Fatalf("job = %+v", job)
	}
	if len(job.Progress) == 0 {
		t.Fatal("the job recorded no progress lines")
	}

	// GET /v1/jobs/{id}
	rec = e.do("GET", "/v1/jobs/"+jobID, withKey(e.viewerKey))
	if rec.Code != http.StatusOK {
		t.Fatalf("job get = %d", rec.Code)
	}

	// The event stream replays a finished job and closes.
	body2, closeStream := openStream(t, e, "/v1/jobs/"+jobID+"/events", e.viewerKey)
	defer closeStream()
	frames := readSSE(t, body2, 3, 5*time.Second)
	if len(frames) < 2 {
		t.Fatalf("got %d frames", len(frames))
	}
	if frames[0].Event != "status" {
		t.Fatalf("first frame = %q", frames[0].Event)
	}
	last := frames[len(frames)-1]
	if last.Event != "done" && last.Event != "progress" {
		t.Fatalf("last frame = %q", last.Event)
	}
}

func TestJobEventsStreamFollowsARunningJob(t *testing.T) {
	e := newEnv(t)
	release := make(chan struct{})
	job, err := e.server.Jobs.Run("test", "target", "", func(h *jobs.Handle) error {
		h.Logf("first line")
		<-release
		h.Logf("second line")
		h.Succeed(map[string]any{"ok": true})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	body, closeStream := openStream(t, e, "/v1/jobs/"+job.ID+"/events", e.viewerKey)
	defer closeStream()

	go func() {
		time.Sleep(100 * time.Millisecond)
		close(release)
	}()

	frames := readSSE(t, body, 4, 5*time.Second)
	sawDone := false
	for _, f := range frames {
		if f.Event == "done" {
			sawDone = true
		}
	}
	if !sawDone {
		t.Fatalf("the stream never sent done: %+v", frames)
	}
}

func TestUnknownJobIs404(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/v1/jobs/abc123", withKey(e.viewerKey))
	if code := assertErrorEnvelope(t, rec, http.StatusNotFound); code != "job_not_found" {
		t.Fatalf("code = %q", code)
	}
}
