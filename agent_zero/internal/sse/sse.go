// Package sse writes Server-Sent Events streams.
package sse

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// ErrUnsupported is returned when the response writer cannot stream.
var ErrUnsupported = errors.New("sse: streaming unsupported")

// Writer emits SSE frames on an http.ResponseWriter.
type Writer struct {
	w  http.ResponseWriter
	rc *http.ResponseController
	id uint64
}

// NewWriter sets the SSE headers, clears the write deadline so the stream can
// stay open, and flushes the response head.
func NewWriter(w http.ResponseWriter, r *http.Request) (*Writer, error) {
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache, no-store")
	h.Set("Connection", "keep-alive")
	h.Set("X-Accel-Buffering", "no")

	rc := http.NewResponseController(w)
	// Streaming endpoints must not be cut short by the server write timeout.
	_ = rc.SetWriteDeadline(time.Time{})
	_ = rc.SetReadDeadline(time.Time{})

	w.WriteHeader(http.StatusOK)
	if err := rc.Flush(); err != nil {
		return nil, ErrUnsupported
	}
	_ = r
	return &Writer{w: w, rc: rc}, nil
}

// Send writes one event with a JSON payload.
func (s *Writer) Send(event string, payload any) error {
	raw, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	return s.SendRaw(event, string(raw))
}

// SendRaw writes one event with an already encoded payload.
func (s *Writer) SendRaw(event, data string) error {
	s.id++
	var b strings.Builder
	fmt.Fprintf(&b, "id: %d\n", s.id)
	if event != "" {
		fmt.Fprintf(&b, "event: %s\n", event)
	}
	for _, line := range strings.Split(data, "\n") {
		fmt.Fprintf(&b, "data: %s\n", line)
	}
	b.WriteString("\n")

	if _, err := s.w.Write([]byte(b.String())); err != nil {
		return err
	}
	return s.rc.Flush()
}

// Comment writes a keep-alive comment frame.
func (s *Writer) Comment(text string) error {
	if _, err := fmt.Fprintf(s.w, ": %s\n\n", text); err != nil {
		return err
	}
	return s.rc.Flush()
}
