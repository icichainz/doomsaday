// Package audit records every mutating call: who, what, on which target,
// with what result.
package audit

import (
	"encoding/json"
	"strconv"
	"sync"
	"time"

	"agent_zero/internal/store"
)

// MaxRecords caps the audit bucket so the database cannot grow without bound.
const MaxRecords = 20000

// Record is one audit entry.
type Record struct {
	ID         string         `json:"id"`
	Time       time.Time      `json:"time"`
	DeviceID   string         `json:"device_id"`
	DeviceName string         `json:"device_name"`
	Role       string         `json:"role"`
	Action     string         `json:"action"`
	Target     string         `json:"target"`
	Result     string         `json:"result"`
	Status     int            `json:"status,omitempty"`
	RemoteIP   string         `json:"remote_ip,omitempty"`
	Details    map[string]any `json:"details,omitempty"`
}

// Results used across the agent.
const (
	ResultOK      = "ok"
	ResultDenied  = "denied"
	ResultError   = "error"
	ResultStarted = "started"
)

// Logger writes and reads audit records.
type Logger interface {
	Write(Record)
	List(filter Filter) ([]Record, string, error)
}

// Filter narrows an audit query.
type Filter struct {
	Actor  string
	Since  time.Time
	Limit  int
	Cursor string
}

// BoltLogger persists audit records in the store.
type BoltLogger struct {
	st *store.Store

	mu    sync.Mutex
	count int
}

// NewBoltLogger builds a Logger over st.
func NewBoltLogger(st *store.Store) *BoltLogger { return &BoltLogger{st: st} }

// Write appends a record. Errors are swallowed on purpose: an audit write
// must never fail the request it describes, and the caller has already
// logged through slog.
func (l *BoltLogger) Write(r Record) {
	if r.Time.IsZero() {
		r.Time = time.Now().UTC()
	}
	r.Time = r.Time.UTC()
	// The record ID is the bucket sequence, filled in on read.
	if _, err := l.st.Append(store.BucketAudit, r); err != nil {
		return
	}
	l.mu.Lock()
	l.count++
	trim := l.count%512 == 0
	l.mu.Unlock()
	if trim {
		_ = l.st.TrimOldest(store.BucketAudit, MaxRecords)
	}
}

// List returns records newest first, applying the filter, and the cursor for
// the next page when there is more.
func (l *BoltLogger) List(f Filter) ([]Record, string, error) {
	limit := f.Limit
	if limit <= 0 {
		limit = 50
	}
	var start uint64
	if f.Cursor != "" {
		n, err := strconv.ParseUint(f.Cursor, 10, 64)
		if err != nil {
			return nil, "", err
		}
		start = n
	}

	out := make([]Record, 0, limit)
	var next string
	err := l.st.WalkDesc(store.BucketAudit, start, func(seq uint64, raw []byte) bool {
		var r Record
		if err := json.Unmarshal(raw, &r); err != nil {
			return true
		}
		if r.ID == "" {
			r.ID = strconv.FormatUint(seq, 10)
		}
		if f.Actor != "" && r.DeviceID != f.Actor && r.DeviceName != f.Actor {
			return true
		}
		if !f.Since.IsZero() && r.Time.Before(f.Since) {
			// Records are walked newest first, so everything below is older.
			return false
		}
		if len(out) == limit {
			next = strconv.FormatUint(seq+1, 10)
			return false
		}
		out = append(out, r)
		return true
	})
	if err != nil {
		return nil, "", err
	}
	return out, next, nil
}

// Nop is a Logger that discards everything; used by tests.
type Nop struct{}

// Write discards the record.
func (Nop) Write(Record) {}

// List returns nothing.
func (Nop) List(Filter) ([]Record, string, error) { return nil, "", nil }
