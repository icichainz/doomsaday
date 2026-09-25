package audit

import (
	"path/filepath"
	"testing"
	"time"

	"agent_zero/internal/store"
)

func newLogger(t *testing.T) *BoltLogger {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "audit.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return NewBoltLogger(st)
}

func TestWriteAndListNewestFirst(t *testing.T) {
	l := newLogger(t)
	base := time.Now().UTC()
	for i := 0; i < 5; i++ {
		l.Write(Record{
			Time:     base.Add(time.Duration(i) * time.Minute),
			DeviceID: "dev1", DeviceName: "phone", Role: "admin",
			Action: "POST /v1/containers/{id}/stop", Target: "c1", Result: ResultOK,
		})
	}
	records, next, err := l.List(Filter{Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 5 {
		t.Fatalf("got %d records", len(records))
	}
	if next != "" {
		t.Fatalf("next cursor = %q on a complete page", next)
	}
	for i := 1; i < len(records); i++ {
		if records[i].Time.After(records[i-1].Time) {
			t.Fatalf("records are not newest first: %v", records)
		}
	}
	for _, r := range records {
		if r.ID == "" {
			t.Fatal("a record has no id")
		}
	}
}

func TestListPaginates(t *testing.T) {
	l := newLogger(t)
	for i := 0; i < 7; i++ {
		l.Write(Record{Action: "a", Target: "t", Result: ResultOK})
	}
	seen := 0
	cursor := ""
	for page := 0; page < 10; page++ {
		records, next, err := l.List(Filter{Limit: 3, Cursor: cursor})
		if err != nil {
			t.Fatal(err)
		}
		seen += len(records)
		if next == "" {
			break
		}
		cursor = next
	}
	if seen != 7 {
		t.Fatalf("paged through %d records, want 7", seen)
	}
}

func TestFilterByActorAndSince(t *testing.T) {
	l := newLogger(t)
	base := time.Now().UTC()
	l.Write(Record{Time: base.Add(-time.Hour), DeviceID: "old", Action: "a", Result: ResultOK})
	l.Write(Record{Time: base, DeviceID: "new", Action: "a", Result: ResultOK})

	records, _, err := l.List(Filter{Actor: "new"})
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].DeviceID != "new" {
		t.Fatalf("actor filter returned %+v", records)
	}

	records, _, err = l.List(Filter{Since: base.Add(-time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 {
		t.Fatalf("since filter returned %d records", len(records))
	}
}

func TestNopLogger(t *testing.T) {
	var l Logger = Nop{}
	l.Write(Record{})
	records, next, err := l.List(Filter{})
	if err != nil || next != "" || len(records) != 0 {
		t.Fatalf("Nop returned %v %q %v", records, next, err)
	}
}
