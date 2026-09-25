package alerts

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"agent_zero/internal/dockerx"
	"agent_zero/internal/dockerx/fakedocker"
	"agent_zero/internal/store"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "alerts.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	s, err := NewStore(st)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// recorder is a Notifier that keeps what it was given.
type recorder struct{ fired []Alert }

func (r *recorder) Notify(a Alert) { r.fired = append(r.fired, a) }

func TestDefaultRulesAreSeeded(t *testing.T) {
	s := newTestStore(t)
	rules, err := s.Rules()
	if err != nil {
		t.Fatal(err)
	}
	if len(rules) != 5 {
		t.Fatalf("got %d rules, want 5", len(rules))
	}
	byID := map[string]Rule{}
	for _, r := range rules {
		byID[r.ID] = r
	}
	if byID[RuleRestartLoop].Threshold != 3 || byID[RuleRestartLoop].WindowSeconds != 600 {
		t.Fatalf("restart loop rule = %+v", byID[RuleRestartLoop])
	}
	if byID[RuleCPUHigh].Threshold != 90 || byID[RuleCPUHigh].WindowSeconds != 300 {
		t.Fatalf("cpu rule = %+v", byID[RuleCPUHigh])
	}
	if byID[RuleAgentUnreachable].Local {
		t.Fatal("the agent unreachable rule must not claim to be evaluated locally")
	}
	if byID[RuleAgentUnreachable].Enabled {
		t.Fatal("the agent unreachable rule must ship disabled: the agent cannot evaluate it")
	}
}

func TestUpdateRuleValidates(t *testing.T) {
	s := newTestStore(t)
	bad := 900.0
	if _, err := s.UpdateRule(RuleCPUHigh, nil, &bad, nil); err == nil {
		t.Fatal("a CPU threshold of 900 percent was accepted")
	}
	window := 1000000
	if _, err := s.UpdateRule(RuleCPUHigh, nil, nil, &window); err == nil {
		t.Fatal("an absurd window was accepted")
	}
	good := 75.0
	r, err := s.UpdateRule(RuleCPUHigh, nil, &good, nil)
	if err != nil {
		t.Fatal(err)
	}
	if r.Threshold != 75 {
		t.Fatalf("threshold = %v", r.Threshold)
	}
	if _, err := s.UpdateRule("no-such-rule", nil, &good, nil); err == nil {
		t.Fatal("an unknown rule was updated")
	}
}

func TestUnexpectedExitFires(t *testing.T) {
	s := newTestStore(t)
	fake := fakedocker.New()
	notifier := &recorder{}
	e := NewEvaluator(s, fake, notifier, nil, time.Second)

	if err := e.EvaluateOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	active, err := s.List(StateActive)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, a := range active {
		if a.RuleID == RuleUnexpectedExit && a.Target == "agentzero-test-db" {
			found = true
			if a.Severity != "critical" {
				t.Errorf("severity = %q", a.Severity)
			}
		}
	}
	if !found {
		t.Fatalf("no unexpected_exit alert fired: %+v", active)
	}
	if len(notifier.fired) == 0 {
		t.Fatal("the notifier was never called")
	}
}

func TestUnexpectedExitResolvesWhenRunningAgain(t *testing.T) {
	s := newTestStore(t)
	fake := fakedocker.New()
	e := NewEvaluator(s, fake, &recorder{}, nil, time.Second)
	ctx := context.Background()

	if err := e.EvaluateOnce(ctx); err != nil {
		t.Fatal(err)
	}
	// The container comes back.
	fake.Containers[1].State = "running"
	fake.Containers[1].ExitCode = 0
	if err := e.EvaluateOnce(ctx); err != nil {
		t.Fatal(err)
	}

	resolved, err := s.List(StateResolved)
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range resolved {
		if a.RuleID == RuleUnexpectedExit {
			return
		}
	}
	t.Fatalf("the alert was not resolved: %+v", resolved)
}

func TestExitFiresOnlyOncePerExit(t *testing.T) {
	s := newTestStore(t)
	fake := fakedocker.New()
	notifier := &recorder{}
	e := NewEvaluator(s, fake, notifier, nil, time.Second)
	ctx := context.Background()

	for i := 0; i < 3; i++ {
		if err := e.EvaluateOnce(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if len(notifier.fired) != 1 {
		t.Fatalf("the notifier fired %d times for one exit", len(notifier.fired))
	}
}

func TestRestartLoopFires(t *testing.T) {
	s := newTestStore(t)
	fake := fakedocker.New()
	// One running container with no restarts to begin with.
	fake.Containers = []dockerx.Container{{
		ID: "loop1", Name: "agentzero-test-loop", State: "running", RestartCount: 0,
	}}
	fake.StatsByID["loop1"] = dockerx.Stats{CPUPercent: 1, MemPercent: 1}

	notifier := &recorder{}
	e := NewEvaluator(s, fake, notifier, nil, time.Second)
	ctx := context.Background()

	if err := e.EvaluateOnce(ctx); err != nil {
		t.Fatal(err)
	}
	// Three restarts inside the window.
	for i := 1; i <= 3; i++ {
		fake.Containers[0].RestartCount = i
		if err := e.EvaluateOnce(ctx); err != nil {
			t.Fatal(err)
		}
	}
	active, err := s.List(StateActive)
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range active {
		if a.RuleID == RuleRestartLoop {
			return
		}
	}
	t.Fatalf("no restart loop alert: %+v", active)
}

func TestRestartLoopIgnoresRestartsOutsideTheWindow(t *testing.T) {
	s := newTestStore(t)
	fake := fakedocker.New()
	fake.Containers = []dockerx.Container{{
		ID: "loop2", Name: "agentzero-test-loop", State: "running", RestartCount: 0,
	}}
	e := NewEvaluator(s, fake, &recorder{}, nil, time.Second)

	base := time.Now().UTC()
	e.now = func() time.Time { return base }
	ctx := context.Background()
	_ = e.EvaluateOnce(ctx)

	fake.Containers[0].RestartCount = 2
	_ = e.EvaluateOnce(ctx)

	// 20 minutes later, one more restart. The window is 10 minutes.
	e.now = func() time.Time { return base.Add(20 * time.Minute) }
	fake.Containers[0].RestartCount = 3
	_ = e.EvaluateOnce(ctx)

	active, err := s.List(StateActive)
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range active {
		if a.RuleID == RuleRestartLoop {
			t.Fatalf("restart loop fired on restarts spread over 20 minutes: %+v", a)
		}
	}
}

func TestCPUHighNeedsTheWholeWindow(t *testing.T) {
	s := newTestStore(t)
	fake := fakedocker.New()
	fake.Containers = []dockerx.Container{{
		ID: "hot1", Name: "agentzero-test-hot", State: "running",
	}}
	fake.StatsByID["hot1"] = dockerx.Stats{CPUPercent: 99, MemPercent: 10}

	e := NewEvaluator(s, fake, &recorder{}, nil, time.Second)
	base := time.Now().UTC()
	e.now = func() time.Time { return base }
	ctx := context.Background()

	_ = e.EvaluateOnce(ctx)
	if got := activeRule(t, s, RuleCPUHigh); got {
		t.Fatal("cpu_high fired on the first sample, before the window elapsed")
	}

	// Four minutes in: still inside the five minute window.
	e.now = func() time.Time { return base.Add(4 * time.Minute) }
	_ = e.EvaluateOnce(ctx)
	if activeRule(t, s, RuleCPUHigh) {
		t.Fatal("cpu_high fired before the window elapsed")
	}

	e.now = func() time.Time { return base.Add(6 * time.Minute) }
	_ = e.EvaluateOnce(ctx)
	if !activeRule(t, s, RuleCPUHigh) {
		t.Fatal("cpu_high did not fire after the window elapsed")
	}

	// Cooling down resolves it.
	fake.StatsByID["hot1"] = dockerx.Stats{CPUPercent: 5}
	e.now = func() time.Time { return base.Add(7 * time.Minute) }
	_ = e.EvaluateOnce(ctx)
	if activeRule(t, s, RuleCPUHigh) {
		t.Fatal("cpu_high stayed active after the container cooled down")
	}
}

func TestMemoryHighUsesItsOwnThreshold(t *testing.T) {
	s := newTestStore(t)
	fake := fakedocker.New()
	fake.Containers = []dockerx.Container{{
		ID: "mem1", Name: "agentzero-test-mem", State: "running",
	}}
	fake.StatsByID["mem1"] = dockerx.Stats{CPUPercent: 1, MemPercent: 95}

	e := NewEvaluator(s, fake, &recorder{}, nil, time.Second)
	base := time.Now().UTC()
	e.now = func() time.Time { return base }
	ctx := context.Background()
	_ = e.EvaluateOnce(ctx)
	e.now = func() time.Time { return base.Add(6 * time.Minute) }
	_ = e.EvaluateOnce(ctx)

	if !activeRule(t, s, RuleMemoryHigh) {
		t.Fatal("memory_high did not fire")
	}
	if activeRule(t, s, RuleCPUHigh) {
		t.Fatal("cpu_high fired on a container with 1 percent CPU")
	}
}

func TestDisabledRuleDoesNotFire(t *testing.T) {
	s := newTestStore(t)
	off := false
	if _, err := s.UpdateRule(RuleUnexpectedExit, &off, nil, nil); err != nil {
		t.Fatal(err)
	}
	fake := fakedocker.New()
	e := NewEvaluator(s, fake, &recorder{}, nil, time.Second)
	_ = e.EvaluateOnce(context.Background())

	if activeRule(t, s, RuleUnexpectedExit) {
		t.Fatal("a disabled rule fired")
	}
}

func TestMuteAndResolve(t *testing.T) {
	s := newTestStore(t)
	fake := fakedocker.New()
	e := NewEvaluator(s, fake, &recorder{}, nil, time.Second)
	_ = e.EvaluateOnce(context.Background())

	active, err := s.List(StateActive)
	if err != nil {
		t.Fatal(err)
	}
	if len(active) == 0 {
		t.Fatal("no alert to mute")
	}
	id := active[0].ID

	if _, err := s.Mute(id, 0); err == nil {
		t.Fatal("a zero minute mute was accepted")
	}
	a, err := s.Mute(id, 30)
	if err != nil {
		t.Fatal(err)
	}
	if a.State != StateMuted || a.MutedUntil == nil {
		t.Fatalf("mute produced %+v", a)
	}

	// The mute lapses.
	base := time.Now()
	s.now = func() time.Time { return base.Add(31 * time.Minute) }
	again, err := s.Get(id)
	if err != nil {
		t.Fatal(err)
	}
	if again.State != StateActive {
		t.Fatalf("state after the mute lapsed = %q", again.State)
	}
	s.now = time.Now

	resolved, err := s.Resolve(id)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.State != StateResolved || resolved.ResolvedAt == nil {
		t.Fatalf("resolve produced %+v", resolved)
	}
}

func activeRule(t *testing.T, s *Store, ruleID string) bool {
	t.Helper()
	active, err := s.List(StateActive)
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range active {
		if a.RuleID == ruleID {
			return true
		}
	}
	return false
}
