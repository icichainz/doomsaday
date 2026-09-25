package auth

import (
	"sync"
	"time"
)

// RateLimiter is a per-key token bucket, used to throttle /v1/pair and failed
// authentication attempts per client IP.
type RateLimiter struct {
	burst  float64
	refill float64 // tokens per second
	ttl    time.Duration

	mu      sync.Mutex
	buckets map[string]*bucket
	now     func() time.Time
}

type bucket struct {
	tokens float64
	last   time.Time
}

// NewRateLimiter allows burst events, refilling at rate per second.
func NewRateLimiter(burst int, per time.Duration) *RateLimiter {
	if burst < 1 {
		burst = 1
	}
	if per <= 0 {
		per = time.Second
	}
	return &RateLimiter{
		burst:   float64(burst),
		refill:  1 / per.Seconds(),
		ttl:     10 * time.Minute,
		buckets: map[string]*bucket{},
		now:     time.Now,
	}
}

// SetClock replaces the time source; used by tests.
func (l *RateLimiter) SetClock(f func() time.Time) { l.now = f }

// Allow consumes one token for key, reporting whether the call may proceed.
func (l *RateLimiter) Allow(key string) bool {
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()

	if len(l.buckets) > 4096 {
		l.gcLocked(now)
	}
	b, ok := l.buckets[key]
	if !ok {
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	}
	elapsed := now.Sub(b.last).Seconds()
	if elapsed > 0 {
		b.tokens += elapsed * l.refill
		if b.tokens > l.burst {
			b.tokens = l.burst
		}
		b.last = now
	}
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// RetryAfter reports roughly how long until key gets another token.
func (l *RateLimiter) RetryAfter(key string) time.Duration {
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.buckets[key]
	if !ok || b.tokens >= 1 {
		return 0
	}
	need := 1 - b.tokens
	return time.Duration(need/l.refill*float64(time.Second)) + time.Second
}

func (l *RateLimiter) gcLocked(now time.Time) {
	for k, b := range l.buckets {
		if now.Sub(b.last) > l.ttl {
			delete(l.buckets, k)
		}
	}
}
