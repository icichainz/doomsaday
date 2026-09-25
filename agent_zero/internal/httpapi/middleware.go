package httpapi

import (
	"context"
	"errors"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"agent_zero/internal/audit"
	"agent_zero/internal/auth"
)

type ctxKey int

const (
	ctxKeyDevice ctxKey = iota
	ctxKeyAction
)

// deviceFrom returns the authenticated device on a request.
func deviceFrom(r *http.Request) (auth.Device, bool) {
	d, ok := r.Context().Value(ctxKeyDevice).(auth.Device)
	return d, ok
}

// actionState carries what the audit middleware should record.
type actionState struct {
	Target  string
	Details map[string]any
	Skip    bool
}

func actionFrom(r *http.Request) *actionState {
	a, _ := r.Context().Value(ctxKeyAction).(*actionState)
	return a
}

// setAuditTarget records the target of the current mutating call.
func setAuditTarget(r *http.Request, target string) {
	if a := actionFrom(r); a != nil {
		a.Target = target
	}
}

// setAuditDetail adds one detail to the audit record for this call.
func setAuditDetail(r *http.Request, key string, value any) {
	if a := actionFrom(r); a != nil {
		if a.Details == nil {
			a.Details = map[string]any{}
		}
		a.Details[key] = value
	}
}

// statusRecorder captures the status code and whether anything was written.
type statusRecorder struct {
	http.ResponseWriter
	status  int
	written bool
}

func (s *statusRecorder) WriteHeader(code int) {
	if !s.written {
		s.status = code
		s.written = true
	}
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if !s.written {
		s.status = http.StatusOK
		s.written = true
	}
	return s.ResponseWriter.Write(b)
}

// Unwrap lets http.ResponseController reach the real writer, which is what
// keeps SSE flushing and deadline control working through the middleware.
func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }

// clientIP extracts the peer address. Proxy headers are ignored on purpose:
// the agent is meant to be reached directly, and trusting XFF here would let
// a caller bypass the rate limiter.
func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// recoverer turns a panic into a 500 in the contract's envelope.
func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			v := recover()
			if v == nil {
				return
			}
			if err, ok := v.(error); ok && errors.Is(err, http.ErrAbortHandler) {
				panic(v)
			}
			s.Log.Error("panic in handler", "path", r.URL.Path, "panic", v)
			defer func() { _ = recover() }()
			writeError(w, http.StatusInternalServerError, codeInternal,
				"the agent could not complete the request", nil)
		}()
		next.ServeHTTP(w, r)
	})
}

// limitBody caps the request body and applies the server read and write
// deadlines. Streaming handlers clear the write deadline themselves.
func (s *Server) limitBody(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil {
			r.Body = http.MaxBytesReader(w, r.Body, s.MaxBodyBytes)
		}
		next.ServeHTTP(w, r)
	})
}

// logRequests writes one structured line per request.
func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)

		lvl := s.Log.Info
		if rec.status >= 500 {
			lvl = s.Log.Error
		} else if rec.status >= 400 {
			lvl = s.Log.Warn
		}
		attrs := []any{
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"duration_ms", time.Since(start).Milliseconds(),
			"ip", clientIP(r),
		}
		if dev, ok := deviceFrom(r); ok {
			attrs = append(attrs, "device", dev.ID, "role", string(dev.Role))
		}
		lvl("request", attrs...)
	})
}

// authenticate requires a valid bearer device key.
func (s *Server) authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		header := r.Header.Get("Authorization")
		scheme, key, _ := strings.Cut(header, " ")
		if !strings.EqualFold(scheme, "Bearer") || strings.TrimSpace(key) == "" {
			s.denyAuth(w, ip, "a bearer device key is required")
			return
		}
		dev, err := s.Auth.Authenticate(strings.TrimSpace(key))
		if err != nil {
			s.denyAuth(w, ip, "the device key is not valid")
			return
		}
		if err := s.Auth.TouchLastSeen(dev.ID); err != nil {
			s.Log.Debug("could not update last seen", "device", dev.ID, "error", err)
		}
		ctx := context.WithValue(r.Context(), ctxKeyDevice, dev)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// denyAuth rejects a request and charges the failure to the caller's IP.
func (s *Server) denyAuth(w http.ResponseWriter, ip, message string) {
	if !s.AuthLimiter.Allow(ip) {
		retry := s.AuthLimiter.RetryAfter(ip)
		w.Header().Set("Retry-After", strconv.Itoa(int(retry.Seconds())+1))
		writeError(w, http.StatusTooManyRequests, codeRateLimited,
			"too many failed authentication attempts", nil)
		return
	}
	w.Header().Set("WWW-Authenticate", `Bearer realm="agent_zero"`)
	writeError(w, http.StatusUnauthorized, codeUnauthorized, message, nil)
}

// requireRole enforces a minimum role.
func (s *Server) requireRole(min auth.Role, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		dev, ok := deviceFrom(r)
		if !ok {
			writeError(w, http.StatusUnauthorized, codeUnauthorized, "authentication is required", nil)
			return
		}
		if !dev.Role.AtLeast(min) {
			s.auditNow(r, dev, audit.ResultDenied, http.StatusForbidden, map[string]any{"required_role": string(min)})
			writeError(w, http.StatusForbidden, codeForbidden,
				"this device's role does not allow that action",
				map[string]any{"role": string(dev.Role), "required_role": string(min)})
			return
		}
		next.ServeHTTP(w, r)
	})
}

// confirmHeader is the header a client uses to confirm a risky action.
const confirmHeader = "X-Confirmed"

// confirmationMethods are the only values confirmHeader may carry, and the
// single place they are written down. A phone confirms with Touch ID or Face
// ID and sends "biometric"; the macOS app, on the many Macs without Touch ID,
// has the user type the target's name instead and sends "typed". Both are a
// deliberate act by the person at the keyboard, which is what the rule is for.
// It is an array so that handing it to a caller cannot change it.
var confirmationMethods = [...]string{"biometric", "typed"}

// confirmationNone is recorded when nothing confirmed a risky call, which can
// only happen while require_biometric_for_risky is off.
const confirmationNone = "none"

// confirmationMethod returns the method named by the request's confirmation
// header, or "" when the header is absent, empty, repeated, or carries
// anything else. Case and surrounding whitespace are ignored; several header
// lines are refused rather than resolved, so a client cannot smuggle an
// accepted value past a proxy that added one of its own.
func confirmationMethod(r *http.Request) string {
	values := r.Header.Values(confirmHeader)
	if len(values) != 1 {
		return ""
	}
	got := strings.TrimSpace(values[0])
	for _, m := range confirmationMethods {
		if strings.EqualFold(got, m) {
			return m
		}
	}
	return ""
}

// requireConfirmation implements the X-Confirmed rule and records which method
// confirmed the call, so the audit log says how the person answered.
func (s *Server) requireConfirmation(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method := confirmationMethod(r)
		if method == "" && s.Settings.Get().RequireBiometricForRisky {
			if dev, ok := deviceFrom(r); ok {
				s.auditNow(r, dev, audit.ResultDenied, http.StatusPreconditionRequired, nil)
			}
			writeError(w, http.StatusPreconditionRequired, codeConfirmationRequired,
				"this action needs a biometric or typed confirmation",
				map[string]any{"header": confirmHeader, "accepted": confirmationMethods})
			return
		}
		if method == "" {
			method = confirmationNone
		}
		setAuditDetail(r, "confirmation", method)
		next.ServeHTTP(w, r)
	})
}

// audited records a mutating call once the handler has run.
func (s *Server) audited(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		state := &actionState{}
		r = r.WithContext(context.WithValue(r.Context(), ctxKeyAction, state))

		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)

		if state.Skip {
			return
		}
		dev, _ := deviceFrom(r)
		result := audit.ResultOK
		switch {
		case rec.status == http.StatusForbidden || rec.status == http.StatusPreconditionRequired:
			// Already written by the middleware that refused the call.
			return
		case rec.status == http.StatusAccepted:
			result = audit.ResultStarted
		case rec.status >= 400:
			result = audit.ResultError
		}
		s.auditNow(r, dev, result, rec.status, state.Details)
	})
}

func (s *Server) auditNow(r *http.Request, dev auth.Device, result string, status int, details map[string]any) {
	target := ""
	if st := actionFrom(r); st != nil {
		target = st.Target
	}
	if target == "" {
		target = pathTarget(r)
	}
	s.Audit.Write(audit.Record{
		Time:       time.Now().UTC(),
		DeviceID:   dev.ID,
		DeviceName: dev.Name,
		Role:       string(dev.Role),
		Action:     actionName(r),
		Target:     target,
		Result:     result,
		Status:     status,
		RemoteIP:   clientIP(r),
		Details:    details,
	})
}

// actionName is the route pattern, which is stable and free of identifiers.
func actionName(r *http.Request) string {
	if r.Pattern != "" {
		return r.Pattern
	}
	return r.Method + " " + r.URL.Path
}

// pathTarget picks the identifier out of the matched route.
func pathTarget(r *http.Request) string {
	for _, k := range []string{"id", "name"} {
		if v := r.PathValue(k); v != "" {
			return v
		}
	}
	return r.URL.Path
}
