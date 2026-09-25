package control

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// shortDir returns a directory short enough for a unix socket path. t.TempDir
// can be deep enough to blow the sun_path limit on macOS.
func shortDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "az")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

func TestServeAndRequest(t *testing.T) {
	path := filepath.Join(shortDir(t), SocketName)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	want := time.Now().Add(time.Minute).UTC().Truncate(time.Second)
	closeFn, err := Serve(ctx, path, func() (string, time.Time, error) {
		return "AAAA-BBBB", want, nil
	}, discardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer closeFn()

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode = %o, want 600", info.Mode().Perm())
	}

	resp, err := RequestPairToken(path)
	if err != nil {
		t.Fatal(err)
	}
	if resp.Token != "AAAA-BBBB" {
		t.Fatalf("token = %q", resp.Token)
	}
	if !resp.ExpiresAt.Equal(want) {
		t.Fatalf("expiry = %v, want %v", resp.ExpiresAt, want)
	}
}

func TestMintErrorIsReported(t *testing.T) {
	path := filepath.Join(shortDir(t), SocketName)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	closeFn, err := Serve(ctx, path, func() (string, time.Time, error) {
		return "", time.Time{}, errors.New("the store is broken")
	}, discardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer closeFn()

	if _, err := RequestPairToken(path); err == nil || !strings.Contains(err.Error(), "broken") {
		t.Fatalf("err = %v", err)
	}
}

func TestPathTooLong(t *testing.T) {
	long := "/tmp/" + strings.Repeat("a/", 60) + SocketName
	if _, err := Serve(context.Background(), long, nil, discardLogger()); !errors.Is(err, ErrPathTooLong) {
		t.Fatalf("Serve = %v, want ErrPathTooLong", err)
	}
	if _, err := RequestPairToken(long); !errors.Is(err, ErrPathTooLong) {
		t.Fatalf("RequestPairToken = %v, want ErrPathTooLong", err)
	}
}

func TestRequestWithoutAServer(t *testing.T) {
	path := filepath.Join(shortDir(t), SocketName)
	if _, err := RequestPairToken(path); err == nil {
		t.Fatal("a request without a running agent succeeded")
	}
}

func TestSocketIsRemovedOnShutdown(t *testing.T) {
	path := filepath.Join(shortDir(t), SocketName)
	ctx, cancel := context.WithCancel(context.Background())

	if _, err := Serve(ctx, path, func() (string, time.Time, error) {
		return "x", time.Now(), nil
	}, discardLogger()); err != nil {
		t.Fatal(err)
	}
	cancel()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); os.IsNotExist(err) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the socket file was left behind")
}
