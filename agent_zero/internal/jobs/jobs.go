// Package jobs is the in-memory job manager behind every 202 response.
package jobs

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"
)

// Status is a job's lifecycle state.
type Status string

// Job statuses.
const (
	StatusQueued    Status = "queued"
	StatusRunning   Status = "running"
	StatusSucceeded Status = "succeeded"
	StatusFailed    Status = "failed"
	// StatusCancelled is the end of a job that was stopped before it
	// finished: by POST /v1/jobs/{id}/cancel, or by the agent shutting down.
	StatusCancelled Status = "cancelled"
)

// CodeCancelled is the error code a cancelled job carries.
const CodeCancelled = "job_cancelled"

// Errors returned by Manager.Cancel.
var (
	// ErrNotFound means no retained job has that id.
	ErrNotFound = errors.New("jobs: no such job")
	// ErrFinished means the job already reached a terminal status.
	ErrFinished = errors.New("jobs: the job has already finished")
)

// Finished reports whether st is a terminal status.
func (st Status) Finished() bool {
	return st == StatusSucceeded || st == StatusFailed || st == StatusCancelled
}

// Line is one progress line.
type Line struct {
	Time time.Time `json:"ts"`
	Text string    `json:"text"`
	// Percent is -1 when the step has no measurable progress.
	Percent float64 `json:"percent"`
}

// Error is the failure of a job, shaped like the API error envelope.
type Error struct {
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details,omitempty"`
}

// Job is a long-running operation.
type Job struct {
	ID         string         `json:"id"`
	Type       string         `json:"type"`
	Target     string         `json:"target,omitempty"`
	Status     Status         `json:"status"`
	CreatedAt  time.Time      `json:"created_at"`
	StartedAt  *time.Time     `json:"started_at,omitempty"`
	FinishedAt *time.Time     `json:"finished_at,omitempty"`
	Progress   []Line         `json:"progress"`
	Result     map[string]any `json:"result,omitempty"`
	Error      *Error         `json:"error,omitempty"`
	DeviceID   string         `json:"device_id,omitempty"`
	// CancelRequested is true once a cancel was asked for and the job has
	// not wound down yet, and stays true on the finished job.
	CancelRequested bool `json:"cancel_requested,omitempty"`
}

// clone returns a deep enough copy to hand to a caller without races.
func (j *Job) clone() Job {
	out := *j
	out.Progress = append([]Line(nil), j.Progress...)
	if j.Result != nil {
		out.Result = map[string]any{}
		for k, v := range j.Result {
			out.Result[k] = v
		}
	}
	if j.Error != nil {
		e := *j.Error
		out.Error = &e
	}
	return out
}

// Update is what an SSE subscriber receives.
type Update struct {
	Job  Job
	Line *Line
}

// Handle is the API a running job uses to report progress.
type Handle struct {
	m  *Manager
	id string
	// Ctx is done when the job is cancelled or the manager shuts down. Every
	// runner must pass it (or a context derived from it) to whatever blocks,
	// so a cancel actually stops the work.
	Ctx context.Context
}

// ID returns the job id.
func (h *Handle) ID() string { return h.id }

// Logf appends a progress line.
func (h *Handle) Logf(format string, args ...any) { h.m.appendLine(h.id, format, -1, args...) }

// Progressf appends a progress line with a percentage.
func (h *Handle) Progressf(percent float64, format string, args ...any) {
	h.m.appendLine(h.id, format, percent, args...)
}

// Fail marks the job failed with a code and message.
func (h *Handle) Fail(code, message string, details map[string]any) {
	h.m.finish(h.id, StatusFailed, nil, &Error{Code: code, Message: message, Details: details})
}

// Succeed marks the job done with an optional result document.
func (h *Handle) Succeed(result map[string]any) {
	h.m.finish(h.id, StatusSucceeded, result, nil)
}

// Options configure the manager.
type Options struct {
	// Retain is how many finished jobs to keep.
	Retain int
	// RetainFor is how long a finished job stays readable.
	RetainFor time.Duration
	// MaxProgress caps the progress lines kept per job.
	MaxProgress int
	// NewID mints job identifiers.
	NewID func() (string, error)
}

// Manager runs jobs and keeps their state in memory.
type Manager struct {
	opts Options

	mu     sync.RWMutex
	jobs   map[string]*Job
	cancel map[string]context.CancelFunc
	// done is closed when a job reaches its terminal status.
	done map[string]chan struct{}
	// cancelledBy holds the device that asked for a cancel, "" for none.
	cancelledBy map[string]string
	subs        map[string]map[chan Update]struct{}

	wg      sync.WaitGroup
	baseCtx context.Context
	stop    context.CancelFunc
	now     func() time.Time
}

// New builds a Manager.
func New(opts Options) *Manager {
	if opts.Retain <= 0 {
		opts.Retain = 200
	}
	if opts.RetainFor <= 0 {
		opts.RetainFor = time.Hour
	}
	if opts.MaxProgress <= 0 {
		opts.MaxProgress = 2000
	}
	if opts.NewID == nil {
		opts.NewID = defaultID
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Manager{
		opts:        opts,
		jobs:        map[string]*Job{},
		cancel:      map[string]context.CancelFunc{},
		done:        map[string]chan struct{}{},
		cancelledBy: map[string]string{},
		subs:        map[string]map[chan Update]struct{}{},
		baseCtx:     ctx,
		stop:        cancel,
		now:         time.Now,
	}
}

// Shutdown cancels every running job and waits for them, bounded by ctx.
func (m *Manager) Shutdown(ctx context.Context) {
	m.stop()
	done := make(chan struct{})
	go func() { m.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-ctx.Done():
	}
}

// Run starts fn as a job and returns the job in its queued state.
func (m *Manager) Run(typ, target, deviceID string, fn func(*Handle) error) (Job, error) {
	id, err := m.opts.NewID()
	if err != nil {
		return Job{}, err
	}
	now := m.now().UTC()
	j := &Job{
		ID:        id,
		Type:      typ,
		Target:    target,
		Status:    StatusQueued,
		CreatedAt: now,
		Progress:  []Line{},
		DeviceID:  deviceID,
	}

	ctx, cancel := context.WithCancel(m.baseCtx)

	m.mu.Lock()
	m.jobs[id] = j
	m.cancel[id] = cancel
	m.done[id] = make(chan struct{})
	m.gcLocked()
	snapshot := j.clone()
	m.mu.Unlock()

	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		defer cancel()

		m.mu.Lock()
		if cur, ok := m.jobs[id]; ok {
			started := m.now().UTC()
			cur.Status = StatusRunning
			cur.StartedAt = &started
		}
		m.mu.Unlock()
		m.publish(id, nil)

		err := fn(&Handle{m: m, id: id, Ctx: ctx})

		m.mu.RLock()
		cur, ok := m.jobs[id]
		finished := ok && cur.FinishedAt != nil
		m.mu.RUnlock()
		if finished {
			return
		}
		switch {
		case ctx.Err() != nil:
			// The runner returned without reporting after its context ended:
			// finish rewrites this as cancelled.
			msg := "the job stopped without reporting a result"
			if err != nil {
				msg = err.Error()
			}
			m.finish(id, StatusFailed, nil, &Error{Code: "job_failed", Message: msg})
		case err != nil:
			m.finish(id, StatusFailed, nil, &Error{Code: "job_failed", Message: err.Error()})
		default:
			m.finish(id, StatusSucceeded, nil, nil)
		}
	}()

	return snapshot, nil
}

func (m *Manager) appendLine(id, format string, percent float64, args ...any) {
	line := Line{Time: m.now().UTC(), Text: sprintf(format, args...), Percent: percent}
	m.mu.Lock()
	j, ok := m.jobs[id]
	if ok {
		j.Progress = append(j.Progress, line)
		if len(j.Progress) > m.opts.MaxProgress {
			j.Progress = j.Progress[len(j.Progress)-m.opts.MaxProgress:]
		}
	}
	m.mu.Unlock()
	if ok {
		m.publish(id, &line)
	}
}

func (m *Manager) finish(id string, st Status, result map[string]any, jerr *Error) {
	m.mu.Lock()
	j, ok := m.jobs[id]
	changed := false
	if ok && j.FinishedAt == nil {
		// A job whose context was cancelled ends as cancelled, whatever the
		// runner reported: a pull that failed with "context canceled" was
		// stopped, it did not fail. Only a runner that finished its work
		// before it noticed the cancel keeps its success.
		if st != StatusSucceeded && m.cancelledLocked(id) {
			st, result, jerr = StatusCancelled, m.cancelResultLocked(id), &Error{
				Code:    CodeCancelled,
				Message: "the job was cancelled before it finished",
				Details: map[string]any{},
			}
		}
		t := m.now().UTC()
		j.Status = st
		j.FinishedAt = &t
		j.Result = result
		j.Error = jerr
		if done, ok := m.done[id]; ok {
			close(done)
		}
		changed = true
	}
	m.mu.Unlock()
	if changed {
		m.publish(id, nil)
	}
}

// cancelledLocked reports whether the job was asked to stop, by a caller or by
// Shutdown. m.mu must be held.
func (m *Manager) cancelledLocked(id string) bool {
	if _, asked := m.cancelledBy[id]; asked {
		return true
	}
	return m.baseCtx.Err() != nil
}

// cancelResultLocked is the result document of a cancelled job.
func (m *Manager) cancelResultLocked(id string) map[string]any {
	out := map[string]any{"cancelled": true}
	if by, asked := m.cancelledBy[id]; asked {
		if by != "" {
			out["cancelled_by"] = by
		}
	} else {
		out["reason"] = "agent_shutdown"
	}
	return out
}

// Cancel asks a queued or running job to stop: its context is cancelled, and
// when the runner returns the job ends as StatusCancelled with
// result.cancelled set. by is the device that asked, recorded in the result.
// It returns the job as it is right after the request, ErrNotFound for an
// unknown id, and ErrFinished (with the finished job) when there is nothing
// left to cancel. Asking twice is harmless.
func (m *Manager) Cancel(id, by string) (Job, error) {
	m.mu.Lock()
	j, ok := m.jobs[id]
	if !ok {
		m.mu.Unlock()
		return Job{}, ErrNotFound
	}
	if j.FinishedAt != nil {
		snap := j.clone()
		m.mu.Unlock()
		return snap, ErrFinished
	}
	if _, asked := m.cancelledBy[id]; !asked {
		m.cancelledBy[id] = by
	}
	j.CancelRequested = true
	cancel := m.cancel[id]
	snap := j.clone()
	m.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	m.publish(id, nil)
	return snap, nil
}

// Wait blocks until the job finishes or ctx ends, and returns the job as it is
// then. The bool is false for an unknown id.
func (m *Manager) Wait(ctx context.Context, id string) (Job, bool) {
	m.mu.RLock()
	done, ok := m.done[id]
	m.mu.RUnlock()
	if !ok {
		return Job{}, false
	}
	select {
	case <-done:
	case <-ctx.Done():
	}
	return m.Get(id)
}

// Get returns a snapshot of one job.
func (m *Manager) Get(id string) (Job, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	j, ok := m.jobs[id]
	if !ok {
		return Job{}, false
	}
	return j.clone(), true
}

// List returns snapshots of every retained job, newest first.
func (m *Manager) List() []Job {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]Job, 0, len(m.jobs))
	for _, j := range m.jobs {
		out = append(out, j.clone())
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	return out
}

// Subscribe returns a channel of updates for one job plus an unsubscribe
// function. The channel is buffered; a slow reader loses intermediate lines
// but always sees the terminal state because the job snapshot is carried on
// every update.
func (m *Manager) Subscribe(id string) (<-chan Update, func()) {
	ch := make(chan Update, 64)
	m.mu.Lock()
	if m.subs[id] == nil {
		m.subs[id] = map[chan Update]struct{}{}
	}
	m.subs[id][ch] = struct{}{}
	m.mu.Unlock()

	return ch, func() {
		m.mu.Lock()
		if set, ok := m.subs[id]; ok {
			if _, ok := set[ch]; ok {
				delete(set, ch)
				close(ch)
			}
			if len(set) == 0 {
				delete(m.subs, id)
			}
		}
		m.mu.Unlock()
	}
}

func (m *Manager) publish(id string, line *Line) {
	m.mu.RLock()
	j, ok := m.jobs[id]
	var snap Job
	if ok {
		snap = j.clone()
	}
	subs := make([]chan Update, 0, len(m.subs[id]))
	for ch := range m.subs[id] {
		subs = append(subs, ch)
	}
	m.mu.RUnlock()
	if !ok {
		return
	}
	for _, ch := range subs {
		select {
		case ch <- Update{Job: snap, Line: line}:
		default:
		}
	}
}

// gcLocked drops finished jobs beyond the retention policy.
func (m *Manager) gcLocked() {
	cutoff := m.now().Add(-m.opts.RetainFor)
	type fin struct {
		id string
		at time.Time
	}
	var done []fin
	for id, j := range m.jobs {
		if j.FinishedAt == nil {
			continue
		}
		if j.FinishedAt.Before(cutoff) {
			m.forgetLocked(id)
			continue
		}
		done = append(done, fin{id, *j.FinishedAt})
	}
	if len(done) <= m.opts.Retain {
		return
	}
	sort.Slice(done, func(i, j int) bool { return done[i].at.Before(done[j].at) })
	for _, f := range done[:len(done)-m.opts.Retain] {
		m.forgetLocked(f.id)
	}
}

// forgetLocked drops every trace of a finished job. m.mu must be held.
func (m *Manager) forgetLocked(id string) {
	delete(m.jobs, id)
	delete(m.cancel, id)
	delete(m.done, id)
	delete(m.cancelledBy, id)
}
