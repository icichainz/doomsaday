// Package control is the local admin channel: a unix socket in the data dir,
// mode 0600, that only the user running the agent can reach. It exists so
// `agent_zero pair-token` can ask the running agent for a pairing token
// instead of trying to take the database lock away from it.
package control

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"time"
)

// SocketName is the socket file inside the data dir.
const SocketName = "control.sock"

// maxSocketPath is the portable limit on a unix socket path: sun_path is 104
// bytes on the BSDs and macOS, 108 on Linux, and the kernel refuses anything
// longer with a bare EINVAL. The default data dir is short, so this only
// bites when someone points --data-dir at a deeply nested directory.
const maxSocketPath = 100

// ErrPathTooLong means the socket path cannot fit in sun_path.
var ErrPathTooLong = errors.New("control: socket path is too long")

func checkPath(path string) error {
	if len(path) > maxSocketPath {
		return fmt.Errorf("%w: %s is %d bytes, the limit is %d; use a shorter --data-dir",
			ErrPathTooLong, path, len(path), maxSocketPath)
	}
	return nil
}

// Response is what the server answers.
type Response struct {
	Token     string    `json:"token,omitempty"`
	ExpiresAt time.Time `json:"expires_at,omitempty"`
	Error     string    `json:"error,omitempty"`
}

// Mint produces a new pairing token.
type Mint func() (string, time.Time, error)

// Serve listens on path until ctx is done.
func Serve(ctx context.Context, path string, mint Mint, log *slog.Logger) (func(), error) {
	if err := checkPath(path); err != nil {
		return nil, err
	}
	_ = os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("control: listen: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = ln.Close()
		return nil, fmt.Errorf("control: chmod: %w", err)
	}

	go func() {
		<-ctx.Done()
		_ = ln.Close()
		_ = os.Remove(path)
	}()

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
					return
				}
				log.Warn("control socket accept failed", "error", err)
				continue
			}
			go handle(conn, mint, log)
		}
	}()

	return func() { _ = ln.Close(); _ = os.Remove(path) }, nil
}

func handle(conn net.Conn, mint Mint, log *slog.Logger) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))

	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		return
	}
	var resp Response
	switch trim(line) {
	case "pair-token":
		token, exp, err := mint()
		if err != nil {
			resp.Error = err.Error()
		} else {
			resp.Token, resp.ExpiresAt = token, exp
			log.Info("pairing token issued through the control socket", "expires_at", exp.UTC().Format(time.RFC3339))
		}
	default:
		resp.Error = "unknown command"
	}
	_ = json.NewEncoder(conn).Encode(resp)
}

func trim(s string) string {
	for len(s) > 0 && (s[len(s)-1] == '\n' || s[len(s)-1] == '\r' || s[len(s)-1] == ' ') {
		s = s[:len(s)-1]
	}
	return s
}

// RequestPairToken asks a running agent for a pairing token.
func RequestPairToken(path string) (Response, error) {
	if err := checkPath(path); err != nil {
		return Response{}, err
	}
	conn, err := net.DialTimeout("unix", path, 3*time.Second)
	if err != nil {
		return Response{}, fmt.Errorf("control: could not reach a running agent at %s: %w", path, err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))

	if _, err := conn.Write([]byte("pair-token\n")); err != nil {
		return Response{}, err
	}
	var resp Response
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		return Response{}, err
	}
	if resp.Error != "" {
		return resp, errors.New(resp.Error)
	}
	return resp, nil
}
