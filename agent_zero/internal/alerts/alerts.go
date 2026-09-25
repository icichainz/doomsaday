// Package alerts evaluates the built-in rules locally and keeps alert state.
package alerts

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"

	"agent_zero/internal/store"
)

// Errors returned by this package.
var (
	ErrNotFound = errors.New("alerts: not found")
	ErrInvalid  = errors.New("alerts: invalid input")
)

// Rule identifiers, fixed because the design names them.
const (
	RuleUnexpectedExit   = "unexpected_exit"
	RuleRestartLoop      = "restart_loop"
	RuleCPUHigh          = "cpu_high"
	RuleMemoryHigh       = "memory_high"
	RuleAgentUnreachable = "agent_unreachable"
)

// Rule is a built-in alert rule with an editable threshold.
type Rule struct {
	ID            string  `json:"id"`
	Name          string  `json:"name"`
	Description   string  `json:"description"`
	Enabled       bool    `json:"enabled"`
	Threshold     float64 `json:"threshold"`
	ThresholdUnit string  `json:"threshold_unit"`
	WindowSeconds int     `json:"window_seconds"`
	Severity      string  `json:"severity"`
	// Local is false for rules the agent cannot evaluate by itself.
	Local bool `json:"evaluated_locally"`
}

// DefaultRules are the built-in rules from the design.
func DefaultRules() []Rule {
	return []Rule{
		{
			ID:            RuleUnexpectedExit,
			Name:          "Container exits unexpectedly",
			Description:   "A container stopped with a non-zero exit code without being asked to.",
			Enabled:       true,
			Threshold:     0,
			ThresholdUnit: "exit_code",
			WindowSeconds: 0,
			Severity:      "critical",
			Local:         true,
		},
		{
			ID:            RuleRestartLoop,
			Name:          "Restart loop",
			Description:   "A container restarted 3 or more times within the window.",
			Enabled:       true,
			Threshold:     3,
			ThresholdUnit: "restarts",
			WindowSeconds: 600,
			Severity:      "critical",
			Local:         true,
		},
		{
			ID:            RuleCPUHigh,
			Name:          "CPU above threshold",
			Description:   "A container held CPU above the threshold for the whole window.",
			Enabled:       true,
			Threshold:     90,
			ThresholdUnit: "percent",
			WindowSeconds: 300,
			Severity:      "warning",
			Local:         true,
		},
		{
			ID:            RuleMemoryHigh,
			Name:          "Memory above threshold",
			Description:   "A container held memory above the threshold for the whole window.",
			Enabled:       true,
			Threshold:     90,
			ThresholdUnit: "percent",
			WindowSeconds: 300,
			Severity:      "warning",
			Local:         true,
		},
		{
			ID:            RuleAgentUnreachable,
			Name:          "Agent unreachable",
			Description:   "The agent stopped answering. This cannot be detected by the agent itself; it needs the push relay to watch a heartbeat.",
			Enabled:       false,
			Threshold:     0,
			ThresholdUnit: "seconds",
			WindowSeconds: 120,
			Severity:      "critical",
			Local:         false,
		},
	}
}

// Alert states.
const (
	StateActive   = "active"
	StateResolved = "resolved"
	StateMuted    = "muted"
)

// Alert is a fired rule.
type Alert struct {
	ID         string     `json:"id"`
	RuleID     string     `json:"rule_id"`
	Severity   string     `json:"severity"`
	Target     string     `json:"target"`
	TargetID   string     `json:"target_id,omitempty"`
	Message    string     `json:"message"`
	State      string     `json:"state"`
	FirstSeen  time.Time  `json:"first_seen"`
	LastSeen   time.Time  `json:"last_seen"`
	ResolvedAt *time.Time `json:"resolved_at,omitempty"`
	MutedUntil *time.Time `json:"muted_until,omitempty"`
	Count      int        `json:"count"`
}

// key is the stable identity of an alert: one rule per target.
func key(ruleID, targetID string) string { return ruleID + "|" + targetID }

// Notifier delivers a fired alert. Push delivery through a relay is out of
// scope for this agent; LogNotifier is the shipped implementation and the
// seam a future relay client plugs into.
type Notifier interface {
	Notify(a Alert)
}

// Store keeps alert state and rules.
type Store struct {
	st  *store.Store
	now func() time.Time
}

// NewStore builds an alert store, seeding the built-in rules when absent.
func NewStore(st *store.Store) (*Store, error) {
	s := &Store{st: st, now: time.Now}
	for _, r := range DefaultRules() {
		var existing Rule
		err := st.Get(store.BucketAlertRules, r.ID, &existing)
		if errors.Is(err, store.ErrNotFound) {
			if err := st.Put(store.BucketAlertRules, r.ID, r); err != nil {
				return nil, err
			}
			continue
		}
		if err != nil {
			return nil, err
		}
		// Keep user settings but refresh the descriptive fields.
		existing.Name, existing.Description = r.Name, r.Description
		existing.ThresholdUnit, existing.Severity, existing.Local = r.ThresholdUnit, r.Severity, r.Local
		if err := st.Put(store.BucketAlertRules, r.ID, existing); err != nil {
			return nil, err
		}
	}
	return s, nil
}

// Rules returns every rule in a stable order.
func (s *Store) Rules() ([]Rule, error) {
	order := map[string]int{}
	for i, r := range DefaultRules() {
		order[r.ID] = i
	}
	var out []Rule
	err := s.st.ForEach(store.BucketAlertRules, func(_ string, raw []byte) error {
		var r Rule
		if err := json.Unmarshal(raw, &r); err != nil {
			return err
		}
		out = append(out, r)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool { return order[out[i].ID] < order[out[j].ID] })
	return out, nil
}

// Rule returns one rule.
func (s *Store) Rule(id string) (Rule, error) {
	var r Rule
	if err := s.st.Get(store.BucketAlertRules, id, &r); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return Rule{}, ErrNotFound
		}
		return Rule{}, err
	}
	return r, nil
}

// UpdateRule changes a rule's enabled flag, threshold or window.
func (s *Store) UpdateRule(id string, enabled *bool, threshold *float64, window *int) (Rule, error) {
	r, err := s.Rule(id)
	if err != nil {
		return Rule{}, err
	}
	if enabled != nil {
		r.Enabled = *enabled
	}
	if threshold != nil {
		if *threshold < 0 || *threshold > 1e12 {
			return Rule{}, fmt.Errorf("%w: threshold out of range", ErrInvalid)
		}
		if r.ThresholdUnit == "percent" && *threshold > 100 {
			return Rule{}, fmt.Errorf("%w: threshold must be 0 to 100 percent", ErrInvalid)
		}
		r.Threshold = *threshold
	}
	if window != nil {
		if *window < 0 || *window > 86400 {
			return Rule{}, fmt.Errorf("%w: window_seconds must be 0 to 86400", ErrInvalid)
		}
		r.WindowSeconds = *window
	}
	if err := s.st.Put(store.BucketAlertRules, r.ID, r); err != nil {
		return Rule{}, err
	}
	return r, nil
}

// List returns alerts, optionally filtered by state.
func (s *Store) List(state string) ([]Alert, error) {
	var out []Alert
	err := s.st.ForEach(store.BucketAlerts, func(_ string, raw []byte) error {
		var a Alert
		if err := json.Unmarshal(raw, &a); err != nil {
			return err
		}
		out = append(out, s.withMuteApplied(a))
		return nil
	})
	if err != nil {
		return nil, err
	}
	if state != "" {
		filtered := out[:0]
		for _, a := range out {
			if a.State == state {
				filtered = append(filtered, a)
			}
		}
		out = filtered
	}
	sort.Slice(out, func(i, j int) bool { return out[i].LastSeen.After(out[j].LastSeen) })
	return out, nil
}

func (s *Store) withMuteApplied(a Alert) Alert {
	if a.State == StateMuted && a.MutedUntil != nil && s.now().After(*a.MutedUntil) {
		a.State = StateActive
	}
	return a
}

// Get returns one alert.
func (s *Store) Get(id string) (Alert, error) {
	var a Alert
	if err := s.st.Get(store.BucketAlerts, id, &a); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return Alert{}, ErrNotFound
		}
		return Alert{}, err
	}
	return s.withMuteApplied(a), nil
}

// Mute silences an alert for the given number of minutes.
func (s *Store) Mute(id string, minutes int) (Alert, error) {
	if minutes <= 0 || minutes > 60*24*30 {
		return Alert{}, fmt.Errorf("%w: minutes must be 1 to 43200", ErrInvalid)
	}
	a, err := s.Get(id)
	if err != nil {
		return Alert{}, err
	}
	until := s.now().UTC().Add(time.Duration(minutes) * time.Minute)
	a.State = StateMuted
	a.MutedUntil = &until
	if err := s.st.Put(store.BucketAlerts, a.ID, a); err != nil {
		return Alert{}, err
	}
	return a, nil
}

// Resolve closes an alert by hand.
func (s *Store) Resolve(id string) (Alert, error) {
	a, err := s.Get(id)
	if err != nil {
		return Alert{}, err
	}
	now := s.now().UTC()
	a.State = StateResolved
	a.ResolvedAt = &now
	a.MutedUntil = nil
	if err := s.st.Put(store.BucketAlerts, a.ID, a); err != nil {
		return Alert{}, err
	}
	return a, nil
}

// fire raises or refreshes an alert. It returns the alert and whether it was
// newly raised, which is what decides if a notification goes out.
func (s *Store) fire(ruleID, severity, targetID, target, message string) (Alert, bool, error) {
	id := key(ruleID, targetID)
	now := s.now().UTC()

	var a Alert
	err := s.st.Get(store.BucketAlerts, id, &a)
	switch {
	case errors.Is(err, store.ErrNotFound):
		a = Alert{
			ID:        id,
			RuleID:    ruleID,
			Severity:  severity,
			Target:    target,
			TargetID:  targetID,
			Message:   message,
			State:     StateActive,
			FirstSeen: now,
			LastSeen:  now,
			Count:     1,
		}
		if err := s.st.Put(store.BucketAlerts, a.ID, a); err != nil {
			return Alert{}, false, err
		}
		return a, true, nil
	case err != nil:
		return Alert{}, false, err
	}

	a = s.withMuteApplied(a)
	wasClosed := a.State == StateResolved
	a.LastSeen = now
	a.Message = message
	a.Count++
	if wasClosed {
		a.State = StateActive
		a.FirstSeen = now
		a.ResolvedAt = nil
	}
	if err := s.st.Put(store.BucketAlerts, a.ID, a); err != nil {
		return Alert{}, false, err
	}
	return a, wasClosed, nil
}

// clear resolves an alert that is no longer firing.
func (s *Store) clear(ruleID, targetID string) error {
	id := key(ruleID, targetID)
	var a Alert
	err := s.st.Get(store.BucketAlerts, id, &a)
	if errors.Is(err, store.ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if a.State == StateResolved {
		return nil
	}
	now := s.now().UTC()
	a.State = StateResolved
	a.ResolvedAt = &now
	return s.st.Put(store.BucketAlerts, a.ID, a)
}
