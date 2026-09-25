package sse

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestFraming(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/stream", nil)

	w, err := NewWriter(rec, req)
	if err != nil {
		t.Fatal(err)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("content type = %q", ct)
	}
	if cc := rec.Header().Get("Cache-Control"); !strings.Contains(cc, "no-cache") {
		t.Fatalf("cache control = %q", cc)
	}

	if err := w.Send("stats", map[string]any{"cpu": 1.5}); err != nil {
		t.Fatal(err)
	}
	if err := w.Send("stats", map[string]any{"cpu": 2.5}); err != nil {
		t.Fatal(err)
	}
	if err := w.Comment("keep-alive"); err != nil {
		t.Fatal(err)
	}

	body := rec.Body.String()
	want := "id: 1\nevent: stats\ndata: {\"cpu\":1.5}\n\nid: 2\nevent: stats\ndata: {\"cpu\":2.5}\n\n: keep-alive\n\n"
	if body != want {
		t.Fatalf("body =\n%q\nwant\n%q", body, want)
	}
}

func TestMultilinePayloadIsSplitAcrossDataLines(t *testing.T) {
	rec := httptest.NewRecorder()
	w, err := NewWriter(rec, httptest.NewRequest("GET", "/stream", nil))
	if err != nil {
		t.Fatal(err)
	}
	if err := w.SendRaw("log", "first\nsecond"); err != nil {
		t.Fatal(err)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "data: first\ndata: second\n\n") {
		t.Fatalf("multiline payload was not split: %q", body)
	}
}

// nonFlusher cannot stream.
type nonFlusher struct{ http.ResponseWriter }

func TestUnsupportedWriter(t *testing.T) {
	rec := httptest.NewRecorder()
	_, err := NewWriter(nonFlusher{rec}, httptest.NewRequest("GET", "/s", nil))
	if err != ErrUnsupported {
		t.Fatalf("err = %v, want ErrUnsupported", err)
	}
}
