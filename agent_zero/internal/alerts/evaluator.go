package alerts

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"agent_zero/internal/dockerx"
)

// LogNotifier is the shipped Notifier: it writes the alert to the agent log.
// A future push relay client implements the same interface.
type LogNotifier struct{ Log *slog.Logger }

// Notify logs a fired alert.
func (n LogNotifier) Notify(a Alert) {
	if n.Log == nil {
		return
	}
	n.Log.Warn("alert fired",
		"rule", a.RuleID, "severity", a.Severity, "target", a.Target, "message", a.Message)
}

// containerSeen is the per-container history the evaluator keeps in memory.
type containerSeen struct {
	restartCount int
	restartMarks []time.Time
	cpuOverSince time.Time
	memOverSince time.Time
	lastExitAt   time.Time
	known        bool
}

// Evaluator runs the rule loop.
type Evaluator struct {
	Store    *Store
	Docker   dockerx.Client
	Notifier Notifier
	Log      *slog.Logger
	Period   time.Duration

	mu   sync.Mutex
	seen map[string]*containerSeen
	now  func() time.Time
}

// NewEvaluator builds an Evaluator.
func NewEvaluator(s *Store, d dockerx.Client, n Notifier, log *slog.Logger, period time.Duration) *Evaluator {
	if period <= 0 {
		period = 15 * time.Second
	}
	return &Evaluator{
		Store: s, Docker: d, Notifier: n, Log: log, Period: period,
		seen: map[string]*containerSeen{},
		now:  time.Now,
	}
}

// Run evaluates the rules until ctx is done.
func (e *Evaluator) Run(ctx context.Context) {
	t := time.NewTicker(e.Period)
	defer t.Stop()
	for {
		if err := e.EvaluateOnce(ctx); err != nil && ctx.Err() == nil && e.Log != nil {
			e.Log.Debug("alert evaluation failed", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// EvaluateOnce runs one pass. It is exported so tests can drive it directly.
func (e *Evaluator) EvaluateOnce(ctx context.Context) error {
	rules, err := e.Store.Rules()
	if err != nil {
		return err
	}
	byID := map[string]Rule{}
	for _, r := range rules {
		byID[r.ID] = r
	}

	containers, err := e.Docker.ContainerList(ctx, dockerx.ContainerListOptions{})
	if err != nil {
		return err
	}

	now := e.now().UTC()
	live := map[string]bool{}

	e.mu.Lock()
	defer e.mu.Unlock()

	for _, c := range containers {
		live[c.ID] = true
		st, ok := e.seen[c.ID]
		if !ok {
			st = &containerSeen{restartCount: c.RestartCount}
			e.seen[c.ID] = st
		}

		e.evalExit(byID[RuleUnexpectedExit], c, st, now)
		e.evalRestartLoop(byID[RuleRestartLoop], c, st, now)
		e.evalResources(ctx, byID[RuleCPUHigh], byID[RuleMemoryHigh], c, st, now)

		st.known = true
	}

	for id := range e.seen {
		if !live[id] {
			delete(e.seen, id)
		}
	}
	return nil
}

func (e *Evaluator) evalExit(r Rule, c dockerx.Container, st *containerSeen, now time.Time) {
	if !r.Enabled {
		return
	}
	exited := c.State == "exited" || c.State == "dead"
	if exited && c.ExitCode != 0 {
		// Only fire once per exit event.
		at := c.FinishedAt
		if at.IsZero() {
			at = now
		}
		if at.Equal(st.lastExitAt) {
			return
		}
		st.lastExitAt = at
		e.raise(r, c.ID, c.Name, fmt.Sprintf("%s exited with code %d", c.Name, c.ExitCode))
		return
	}
	if c.State == "running" {
		e.resolve(r.ID, c.ID)
	}
}

func (e *Evaluator) evalRestartLoop(r Rule, c dockerx.Container, st *containerSeen, now time.Time) {
	if !r.Enabled {
		return
	}
	window := time.Duration(r.WindowSeconds) * time.Second
	if window <= 0 {
		window = 10 * time.Minute
	}

	if st.known && c.RestartCount > st.restartCount {
		for i := 0; i < c.RestartCount-st.restartCount; i++ {
			st.restartMarks = append(st.restartMarks, now)
		}
	}
	st.restartCount = c.RestartCount

	cutoff := now.Add(-window)
	kept := st.restartMarks[:0]
	for _, m := range st.restartMarks {
		if m.After(cutoff) {
			kept = append(kept, m)
		}
	}
	st.restartMarks = kept

	threshold := int(r.Threshold)
	if threshold < 1 {
		threshold = 3
	}
	if len(st.restartMarks) >= threshold {
		e.raise(r, c.ID, c.Name, fmt.Sprintf("%s restarted %d times in %s", c.Name, len(st.restartMarks), window))
		return
	}
	if len(st.restartMarks) == 0 {
		e.resolve(r.ID, c.ID)
	}
}

func (e *Evaluator) evalResources(ctx context.Context, cpuRule, memRule Rule, c dockerx.Container, st *containerSeen, now time.Time) {
	if !cpuRule.Enabled && !memRule.Enabled {
		return
	}
	if c.State != "running" {
		st.cpuOverSince, st.memOverSince = time.Time{}, time.Time{}
		e.resolve(cpuRule.ID, c.ID)
		e.resolve(memRule.ID, c.ID)
		return
	}
	stats, err := e.Docker.ContainerStats(ctx, c.ID)
	if err != nil {
		return
	}

	if cpuRule.Enabled {
		e.evalSustained(cpuRule, c, &st.cpuOverSince, stats.CPUPercent, now,
			fmt.Sprintf("%s CPU above %.0f%%", c.Name, cpuRule.Threshold))
	}
	if memRule.Enabled {
		e.evalSustained(memRule, c, &st.memOverSince, stats.MemPercent, now,
			fmt.Sprintf("%s memory above %.0f%%", c.Name, memRule.Threshold))
	}
}

func (e *Evaluator) evalSustained(r Rule, c dockerx.Container, since *time.Time, value float64, now time.Time, message string) {
	window := time.Duration(r.WindowSeconds) * time.Second
	if value > r.Threshold {
		if since.IsZero() {
			*since = now
		}
		if now.Sub(*since) >= window {
			e.raise(r, c.ID, c.Name, fmt.Sprintf("%s for %s (now %.0f%%)", message, window, value))
		}
		return
	}
	*since = time.Time{}
	e.resolve(r.ID, c.ID)
}

func (e *Evaluator) raise(r Rule, targetID, target, message string) {
	a, isNew, err := e.Store.fire(r.ID, r.Severity, targetID, target, message)
	if err != nil {
		if e.Log != nil {
			e.Log.Error("could not record alert", "rule", r.ID, "error", err)
		}
		return
	}
	if isNew && e.Notifier != nil && a.State == StateActive {
		e.Notifier.Notify(a)
	}
}

func (e *Evaluator) resolve(ruleID, targetID string) {
	if ruleID == "" {
		return
	}
	if err := e.Store.clear(ruleID, targetID); err != nil && e.Log != nil {
		e.Log.Debug("could not resolve alert", "rule", ruleID, "error", err)
	}
}
