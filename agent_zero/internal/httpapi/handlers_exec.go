package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/coder/websocket"

	"agent_zero/internal/audit"
	"agent_zero/internal/dockerx"
)

func contextWithTimeout(r *http.Request, d time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(r.Context(), d)
}

// execShells are the shells a client may ask for by name. It may only pick
// from this list: an arbitrary command would turn the endpoint into remote
// code execution with extra steps, which the exec session already is, but at
// least the audit record stays readable.
var execShells = []string{"/bin/bash", "/bin/sh", "/bin/ash"}

// defaultExecCommand is what runs when the client names no shell. It is a
// compile-time constant, never anything from the request: /bin/sh hands over
// to bash when the image has it, and stays itself when it does not, so one
// exec covers both instead of guessing and failing.
var defaultExecCommand = []string{
	"/bin/sh", "-c", "if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi",
}

// execFallbacks are tried, in order, when the default command cannot start,
// which is what happens in an image without /bin/sh.
var execFallbacks = [][]string{
	{"/bin/ash"},
	{"/bin/bash"},
	{"/bin/busybox", "sh"},
}

// execStartGrace is how long to wait before asking Docker whether the exec
// actually started. Docker accepts an exec for a binary that does not exist
// and only fails when it starts it, so a missing shell shows up here as an
// immediate 126 or 127 rather than as an error from the create call.
const execStartGrace = 200 * time.Millisecond

// execMessage is the client to server frame.
type execMessage struct {
	Type string `json:"type"` // "stdin", "resize" or "ping"
	Data string `json:"data,omitempty"`
	Cols uint   `json:"cols,omitempty"`
	Rows uint   `json:"rows,omitempty"`
}

// maxExecFrame caps one inbound frame.
const maxExecFrame = 64 * 1024

// execIdleTimeout closes a session that has produced nothing for this long.
const execSessionMax = 4 * time.Hour

// handleContainerExec is the one WebSocket in the contract. It is admin only
// and both the start and the end of the session are audited.
func (s *Server) handleContainerExec(w http.ResponseWriter, r *http.Request) {
	id, ok := s.containerID(w, r)
	if !ok {
		return
	}
	setAuditTarget(r, id)

	shell := r.URL.Query().Get("shell")
	if shell != "" {
		allowed := false
		for _, s := range execShells {
			if s == shell {
				allowed = true
			}
		}
		if !allowed {
			validationError(w, "shell", "shell must be one of /bin/bash, /bin/sh or /bin/ash")
			return
		}
	}
	cols, err := queryInt(r, "cols", 80, 10, 500)
	if err != nil {
		validationError(w, "cols", err.Error())
		return
	}
	rows, err := queryInt(r, "rows", 24, 5, 200)
	if err != nil {
		validationError(w, "rows", err.Error())
		return
	}

	det, err := s.Docker.ContainerInspect(r.Context(), id)
	if err != nil {
		s.fail(w, "container", err)
		return
	}
	if det.State != "running" {
		writeError(w, http.StatusConflict, codeConflict,
			"an interactive shell needs a running container", map[string]any{"state": det.State})
		return
	}

	dev, _ := deviceFrom(r)

	// An interactive shell outlives the server's read and write timeouts.
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Time{})
	_ = rc.SetWriteDeadline(time.Time{})

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// The agent is reached directly by the app, which sends no Origin.
		// Any browser origin is refused.
		OriginPatterns:     nil,
		InsecureSkipVerify: false,
		CompressionMode:    websocket.CompressionDisabled,
	})
	if err != nil {
		s.Log.Warn("exec websocket upgrade failed", "container", id, "error", err)
		// Accept already wrote a response.
		if a := actionFrom(r); a != nil {
			a.Skip = true
		}
		return
	}
	conn.SetReadLimit(maxExecFrame)

	// The upgrade took the connection over, so the audit middleware cannot
	// see a status: record the session explicitly instead.
	if a := actionFrom(r); a != nil {
		a.Skip = true
	}
	started := time.Now().UTC()
	s.Audit.Write(audit.Record{
		Time: started, DeviceID: dev.ID, DeviceName: dev.Name, Role: string(dev.Role),
		Action: "WS /v1/containers/{id}/exec", Target: det.Name, Result: audit.ResultStarted,
		RemoteIP: clientIP(r), Details: map[string]any{"container_id": det.ID, "shell": shell},
	})

	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), execSessionMax)
	defer cancel()

	result := audit.ResultOK
	detail := map[string]any{"container_id": det.ID}
	if err := s.runExec(ctx, conn, id, shell, uint(cols), uint(rows)); err != nil {
		result = audit.ResultError
		detail["error"] = err.Error()
	}
	detail["duration_seconds"] = int64(time.Since(started).Seconds())
	s.Audit.Write(audit.Record{
		Time: time.Now().UTC(), DeviceID: dev.ID, DeviceName: dev.Name, Role: string(dev.Role),
		Action: "WS /v1/containers/{id}/exec closed", Target: det.Name, Result: result,
		RemoteIP: clientIP(r), Details: detail,
	})
}

func (s *Server) runExec(ctx context.Context, conn *websocket.Conn, id, shell string, cols, rows uint) error {
	candidates := [][]string{defaultExecCommand}
	candidates = append(candidates, execFallbacks...)
	if shell != "" {
		candidates = [][]string{{shell}}
	}

	var session dockerx.ExecSession
	var lastErr error
	for i, cmd := range candidates {
		sess, err := s.Docker.ContainerExec(ctx, id, dockerx.ExecOptions{
			Cmd: cmd, TTY: true, Width: cols, Height: rows,
		})
		if err != nil {
			lastErr = err
			continue
		}
		// Docker only reports a missing binary once it starts the process.
		if i < len(candidates)-1 && execDiedImmediately(ctx, sess) {
			_ = sess.Close()
			lastErr = fmt.Errorf("%v could not be started", cmd)
			continue
		}
		session = sess
		break
	}
	if session == nil {
		msg := "no usable shell was found in this container"
		if lastErr != nil {
			msg = lastErr.Error()
		}
		_ = conn.Close(websocket.StatusInternalError, truncateReason(msg))
		return errors.New(msg)
	}
	defer session.Close()

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Container output towards the phone.
	outDone := make(chan error, 1)
	go func() {
		buf := make([]byte, 8192)
		for {
			n, err := session.Read(buf)
			if n > 0 {
				if wErr := conn.Write(ctx, websocket.MessageBinary, buf[:n]); wErr != nil {
					outDone <- wErr
					return
				}
			}
			if err != nil {
				if errors.Is(err, io.EOF) {
					outDone <- nil
				} else {
					outDone <- err
				}
				return
			}
		}
	}()

	// Phone input towards the container.
	inDone := make(chan error, 1)
	go func() {
		for {
			typ, data, err := conn.Read(ctx)
			if err != nil {
				inDone <- err
				return
			}
			if typ == websocket.MessageBinary {
				if _, err := session.Write(data); err != nil {
					inDone <- err
					return
				}
				continue
			}
			var msg execMessage
			if err := json.Unmarshal(data, &msg); err != nil {
				continue
			}
			switch msg.Type {
			case "stdin":
				if _, err := session.Write([]byte(msg.Data)); err != nil {
					inDone <- err
					return
				}
			case "resize":
				if msg.Cols >= 10 && msg.Cols <= 500 && msg.Rows >= 5 && msg.Rows <= 200 {
					_ = session.Resize(msg.Cols, msg.Rows)
				}
			case "ping":
			}
		}
	}()

	var err error
	select {
	case err = <-outDone:
	case err = <-inDone:
	case <-ctx.Done():
		err = ctx.Err()
	}
	// Close the exec first, but leave the WebSocket alone: cancelling the
	// context the reader is blocked on would tear the connection down before
	// the app could see the exit frame.
	_ = session.Close()

	if code, running, ecErr := session.ExitCode(); ecErr == nil && !running {
		payload, _ := json.Marshal(map[string]any{"type": "exit", "code": code})
		writeCtx, writeCancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = conn.Write(writeCtx, websocket.MessageText, payload)
		writeCancel()
	}
	cancel()
	_ = conn.Close(websocket.StatusNormalClosure, "session ended")

	if err != nil && websocket.CloseStatus(err) != -1 {
		return nil
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

// execDiedImmediately reports whether the exec process was gone within the
// grace period with a shell-not-found status.
func execDiedImmediately(ctx context.Context, sess dockerx.ExecSession) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(execStartGrace):
	}
	code, running, err := sess.ExitCode()
	if err != nil || running {
		return false
	}
	// 126 is "found but not executable", 127 is "not found".
	return code == 126 || code == 127
}

func truncateReason(s string) string {
	if len(s) > 100 {
		return s[:100]
	}
	return s
}
