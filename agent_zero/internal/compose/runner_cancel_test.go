//go:build unix

package compose

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeCompose writes a stand-in for the docker binary: it prints a line, then
// leaves a child process behind that holds stdout open, the way the compose
// CLI plugin outlives a killed `docker` parent.
func fakeCompose(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "docker")
	script := "#!/bin/sh\necho started\nsleep 30 &\nsleep 30\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin
}

func TestRunStopsPromptlyWhenCancelled(t *testing.T) {
	bin := fakeCompose(t)
	r := &Runner{Bin: bin, StopGrace: time.Second}
	p := Project{Name: "demo", ConfigFiles: []string{"compose.yaml"}, WorkingDir: t.TempDir()}

	ctx, cancel := context.WithCancel(context.Background())
	var mu sync.Mutex
	var lines []string
	started := make(chan struct{})
	var once sync.Once
	onLine := func(l string) {
		mu.Lock()
		lines = append(lines, l)
		mu.Unlock()
		if l == "started" {
			once.Do(func() { close(started) })
		}
	}

	errc := make(chan error, 1)
	go func() { errc <- r.Run(ctx, p, ActionUp, onLine) }()

	select {
	case <-started:
	case err := <-errc:
		t.Fatalf("Run returned before it was cancelled: %v", err)
	case <-time.After(20 * time.Second):
		t.Fatal("the fake compose never started")
	}
	begin := time.Now()
	cancel()

	select {
	case err := <-errc:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("err = %v, want context.Canceled", err)
		}
		d := time.Since(begin)
		t.Logf("stopped %v after the cancel", d)
		if d > 5*time.Second {
			t.Fatalf("stopping took %v", d)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Run did not return after its context was cancelled")
	}

	mu.Lock()
	defer mu.Unlock()
	if len(lines) < 2 || !strings.HasPrefix(lines[0], "$ ") {
		t.Fatalf("lines = %q", lines)
	}
}
