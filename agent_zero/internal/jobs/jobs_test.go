package jobs

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func TestJobRunsToSuccess(t *testing.T) {
	m := New(Options{})
	defer m.Shutdown(context.Background())

	done := make(chan struct{})
	job, err := m.Run("test", "target", "dev1", func(h *Handle) error {
		h.Logf("step %d", 1)
		h.Progressf(50, "halfway")
		h.Succeed(map[string]any{"bytes": 10})
		close(done)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if job.Status != StatusQueued {
		t.Fatalf("initial status = %q", job.Status)
	}
	<-done

	final := waitFinished(t, m, job.ID)
	if final.Status != StatusSucceeded {
		t.Fatalf("status = %q", final.Status)
	}
	if final.Result["bytes"] != float64(10) && final.Result["bytes"] != 10 {
		t.Fatalf("result = %v", final.Result)
	}
	if len(final.Progress) != 2 {
		t.Fatalf("progress = %+v", final.Progress)
	}
	if final.Progress[0].Percent != -1 {
		t.Errorf("a plain log line should have percent -1, got %v", final.Progress[0].Percent)
	}
	if final.Progress[1].Percent != 50 {
		t.Errorf("percent = %v", final.Progress[1].Percent)
	}
	if final.StartedAt == nil || final.FinishedAt == nil {
		t.Fatal("timestamps are missing")
	}
	if final.DeviceID != "dev1" {
		t.Errorf("device = %q", final.DeviceID)
	}
}

func TestJobFailure(t *testing.T) {
	m := New(Options{})
	defer m.Shutdown(context.Background())

	job, _ := m.Run("test", "t", "", func(h *Handle) error {
		h.Fail("boom_code", "it went wrong", map[string]any{"why": "testing"})
		return nil
	})
	final := waitFinished(t, m, job.ID)
	if final.Status != StatusFailed {
		t.Fatalf("status = %q", final.Status)
	}
	if final.Error == nil || final.Error.Code != "boom_code" {
		t.Fatalf("error = %+v", final.Error)
	}
	if final.Error.Details["why"] != "testing" {
		t.Fatalf("details = %v", final.Error.Details)
	}
}

func TestJobReturningAnErrorFails(t *testing.T) {
	m := New(Options{})
	defer m.Shutdown(context.Background())

	job, _ := m.Run("test", "t", "", func(*Handle) error { return errors.New("plain failure") })
	final := waitFinished(t, m, job.ID)
	if final.Status != StatusFailed || final.Error == nil {
		t.Fatalf("job = %+v", final)
	}
	if final.Error.Message != "plain failure" {
		t.Fatalf("message = %q", final.Error.Message)
	}
}

func TestJobCancel(t *testing.T) {
	m := New(Options{})
	defer m.Shutdown(context.Background())

	started := make(chan struct{})
	job, _ := m.Run("test", "t", "", func(h *Handle) error {
		close(started)
		<-h.Ctx.Done()
		return h.Ctx.Err()
	})
	<-started
	if !m.Cancel(job.ID) {
		t.Fatal("cancel returned false")
	}
	final := waitFinished(t, m, job.ID)
	if final.Status != StatusCanceled {
		t.Fatalf("status = %q", final.Status)
	}
}

func TestSubscribeSeesProgressAndCompletion(t *testing.T) {
	m := New(Options{})
	defer m.Shutdown(context.Background())

	release := make(chan struct{})
	job, _ := m.Run("test", "t", "", func(h *Handle) error {
		<-release
		h.Logf("a line")
		h.Succeed(nil)
		return nil
	})

	updates, unsubscribe := m.Subscribe(job.ID)
	defer unsubscribe()
	close(release)

	sawLine, sawFinish := false, false
	deadline := time.After(3 * time.Second)
	for !sawLine || !sawFinish {
		select {
		case u := <-updates:
			if u.Line != nil && u.Line.Text == "a line" {
				sawLine = true
			}
			if u.Job.FinishedAt != nil {
				sawFinish = true
			}
		case <-deadline:
			t.Fatalf("timed out; line %v finish %v", sawLine, sawFinish)
		}
	}
}

func TestUnsubscribeIsIdempotent(t *testing.T) {
	m := New(Options{})
	defer m.Shutdown(context.Background())
	_, unsubscribe := m.Subscribe("nope")
	unsubscribe()
	unsubscribe()
}

func TestProgressIsCapped(t *testing.T) {
	m := New(Options{MaxProgress: 10})
	defer m.Shutdown(context.Background())

	job, _ := m.Run("test", "t", "", func(h *Handle) error {
		for i := 0; i < 100; i++ {
			h.Logf("line %d", i)
		}
		h.Succeed(nil)
		return nil
	})
	final := waitFinished(t, m, job.ID)
	if len(final.Progress) != 10 {
		t.Fatalf("kept %d progress lines, want 10", len(final.Progress))
	}
	if final.Progress[9].Text != "line 99" {
		t.Fatalf("the newest line was dropped: %q", final.Progress[9].Text)
	}
}

func TestRetentionDropsOldJobs(t *testing.T) {
	m := New(Options{Retain: 3})
	defer m.Shutdown(context.Background())

	for i := 0; i < 10; i++ {
		job, _ := m.Run("test", "t", "", func(h *Handle) error { h.Succeed(nil); return nil })
		waitFinished(t, m, job.ID)
	}
	// One more Run triggers the sweep.
	job, _ := m.Run("test", "t", "", func(h *Handle) error { h.Succeed(nil); return nil })
	waitFinished(t, m, job.ID)

	if n := len(m.List()); n > 5 {
		t.Fatalf("kept %d jobs with Retain=3", n)
	}
}

func TestSnapshotsAreCopies(t *testing.T) {
	m := New(Options{})
	defer m.Shutdown(context.Background())

	job, _ := m.Run("test", "t", "", func(h *Handle) error {
		h.Logf("one")
		h.Succeed(map[string]any{"k": "v"})
		return nil
	})
	final := waitFinished(t, m, job.ID)
	final.Progress[0].Text = "mutated"
	final.Result["k"] = "mutated"

	again, _ := m.Get(job.ID)
	if again.Progress[0].Text != "one" || again.Result["k"] != "v" {
		t.Fatal("Get returned a shared structure that a caller could mutate")
	}
}

func TestShutdownWaitsForRunningJobs(t *testing.T) {
	m := New(Options{})
	var finished atomic.Bool
	started := make(chan struct{})
	m.Run("test", "t", "", func(h *Handle) error {
		close(started)
		<-h.Ctx.Done()
		finished.Store(true)
		h.Succeed(nil)
		return nil
	})
	<-started

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	m.Shutdown(ctx)
	if !finished.Load() {
		t.Fatal("shutdown did not wait for the running job")
	}
}

func waitFinished(t *testing.T, m *Manager, id string) Job {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		j, ok := m.Get(id)
		if ok && j.FinishedAt != nil {
			return j
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("job %s never finished", id)
	return Job{}
}
