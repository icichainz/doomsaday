// Package httpapi is the REST surface described in docs/agent-api.md. The
// router is an explicit allow-list: anything not registered here returns 404,
// and the raw Docker API is never proxied.
package httpapi

import (
	"log/slog"
	"net/http"
	"time"

	"agent_zero/internal/alerts"
	"agent_zero/internal/audit"
	"agent_zero/internal/auth"
	"agent_zero/internal/compose"
	"agent_zero/internal/dockerx"
	"agent_zero/internal/jobs"
	"agent_zero/internal/registry"
	"agent_zero/internal/settings"
)

// Deps are everything the handlers need. They are all interfaces or small
// managers so the whole API can be exercised with fakes.
type Deps struct {
	Log             *slog.Logger
	Docker          dockerx.Client
	Auth            *auth.Manager
	Audit           audit.Logger
	Jobs            *jobs.Manager
	Alerts          *alerts.Store
	Registries      *registry.Manager
	Settings        *settings.Manager
	Compose         *compose.Discoverer
	ComposeRunner   *compose.Runner
	Version         string
	StartedAt       time.Time
	CertFingerprint string
	StacksDir       string
}

// Server holds the dependencies and the tuning knobs.
type Server struct {
	Deps

	PairLimiter  *auth.RateLimiter
	AuthLimiter  *auth.RateLimiter
	MaxBodyBytes int64

	// StatsInterval is how often the system stats stream emits.
	StatsInterval time.Duration
	// KeepAlive is how often an idle SSE stream emits a comment frame.
	KeepAlive time.Duration
	// CancelWait bounds how long POST /v1/jobs/{id}/cancel waits for the
	// job to wind down before it answers 202 instead of 200.
	CancelWait time.Duration
}

// NewServer builds a Server with sane defaults.
func NewServer(d Deps) *Server {
	if d.Log == nil {
		d.Log = slog.Default()
	}
	if d.StartedAt.IsZero() {
		d.StartedAt = time.Now()
	}
	return &Server{
		Deps:          d,
		PairLimiter:   auth.NewRateLimiter(5, 30*time.Second),
		AuthLimiter:   auth.NewRateLimiter(20, 3*time.Second),
		MaxBodyBytes:  1 << 20,
		StatsInterval: 3 * time.Second,
		KeepAlive:     20 * time.Second,
		CancelWait:    5 * time.Second,
	}
}

// Handler returns the fully wrapped HTTP handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	s.routes(mux)
	return s.recoverer(s.logRequests(s.limitBody(mux)))
}

// viewer wraps a read-only handler.
func (s *Server) viewer(h http.HandlerFunc) http.Handler {
	return s.authenticate(s.requireRole(auth.RoleViewer, h))
}

// operator wraps a mutating handler an operator may call.
func (s *Server) operator(h http.HandlerFunc) http.Handler {
	return s.authenticate(s.audited(s.requireRole(auth.RoleOperator, h)))
}

// admin wraps a mutating handler only an admin may call.
func (s *Server) admin(h http.HandlerFunc) http.Handler {
	return s.authenticate(s.audited(s.requireRole(auth.RoleAdmin, h)))
}

// adminRead wraps a read handler that is admin-only and audited, which is
// what the contract asks for on the environment values endpoint.
func (s *Server) adminRead(h http.HandlerFunc) http.Handler {
	return s.authenticate(s.audited(s.requireRole(auth.RoleAdmin, h)))
}

// riskyOperator is an operator action that also needs confirmation.
func (s *Server) riskyOperator(h http.HandlerFunc) http.Handler {
	return s.authenticate(s.audited(s.requireRole(auth.RoleOperator, s.requireConfirmation(h))))
}

// riskyAdmin is an admin action that also needs confirmation.
func (s *Server) riskyAdmin(h http.HandlerFunc) http.Handler {
	return s.authenticate(s.audited(s.requireRole(auth.RoleAdmin, s.requireConfirmation(h))))
}

func (s *Server) routes(mux *http.ServeMux) {
	// Anything not listed below is a 404 in the contract's envelope.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, codeNotFound, "no such endpoint", nil)
	})

	// Unauthenticated.
	mux.HandleFunc("GET /v1/health", s.handleHealth)
	mux.HandleFunc("POST /v1/pair", s.handlePair)

	// Devices.
	mux.Handle("GET /v1/me", s.viewer(s.handleMe))
	mux.Handle("GET /v1/devices", s.viewer(s.handleDeviceList))
	mux.Handle("PATCH /v1/devices/{id}", s.admin(s.handleDevicePatch))
	mux.Handle("DELETE /v1/devices/{id}", s.riskyAdmin(s.handleDeviceDelete))

	// Server overview.
	mux.Handle("GET /v1/system", s.viewer(s.handleSystem))
	mux.Handle("GET /v1/system/stats", s.viewer(s.handleSystemStats))
	mux.Handle("GET /v1/system/stats/stream", s.viewer(s.handleSystemStatsStream))
	mux.Handle("GET /v1/activity", s.viewer(s.handleActivity))
	mux.Handle("GET /v1/events/stream", s.viewer(s.handleEventsStream))

	// Containers.
	mux.Handle("GET /v1/containers", s.viewer(s.handleContainerList))
	mux.Handle("GET /v1/containers/{id}", s.viewer(s.handleContainerGet))
	mux.Handle("GET /v1/containers/{id}/env", s.adminRead(s.handleContainerEnv))
	mux.Handle("GET /v1/containers/{id}/stats/stream", s.viewer(s.handleContainerStatsStream))
	mux.Handle("GET /v1/containers/{id}/impact", s.viewer(s.handleContainerImpact))
	mux.Handle("GET /v1/containers/{id}/logs", s.viewer(s.handleContainerLogs))
	mux.Handle("GET /v1/containers/{id}/logs/stream", s.viewer(s.handleContainerLogsStream))
	mux.Handle("POST /v1/containers/{id}/start", s.operator(s.handleContainerStart))
	mux.Handle("POST /v1/containers/{id}/stop", s.riskyOperator(s.handleContainerStop))
	mux.Handle("POST /v1/containers/{id}/restart", s.operator(s.handleContainerRestart))
	mux.Handle("POST /v1/containers/{id}/pause", s.operator(s.handleContainerPause))
	mux.Handle("POST /v1/containers/{id}/unpause", s.operator(s.handleContainerUnpause))
	mux.Handle("DELETE /v1/containers/{id}", s.riskyAdmin(s.handleContainerRemove))
	mux.Handle("GET /v1/containers/{id}/exec", s.admin(s.handleContainerExec))

	// Compose stacks.
	mux.Handle("GET /v1/stacks", s.viewer(s.handleStackList))
	mux.Handle("GET /v1/stacks/{name}", s.viewer(s.handleStackGet))
	mux.Handle("POST /v1/stacks/{name}/up", s.operator(s.handleStackUp))
	mux.Handle("POST /v1/stacks/{name}/redeploy", s.operator(s.handleStackRedeploy))
	mux.Handle("POST /v1/stacks/{name}/restart", s.operator(s.handleStackRestart))
	mux.Handle("POST /v1/stacks/{name}/down", s.riskyAdmin(s.handleStackDown))

	// Swarm.
	mux.Handle("GET /v1/swarm", s.viewer(s.handleSwarm))
	mux.Handle("GET /v1/services", s.viewer(s.handleServiceList))
	mux.Handle("GET /v1/services/{id}/tasks", s.viewer(s.handleServiceTasks))
	mux.Handle("POST /v1/services/{id}/scale", s.operator(s.handleServiceScale))
	mux.Handle("POST /v1/services/{id}/update", s.operator(s.handleServiceUpdate))
	mux.Handle("POST /v1/services/{id}/rollback", s.operator(s.handleServiceRollback))

	// Images.
	mux.Handle("GET /v1/images", s.viewer(s.handleImageList))
	mux.Handle("POST /v1/images/pull", s.operator(s.handleImagePull))
	mux.Handle("POST /v1/images/prune", s.riskyAdmin(s.handleImagePrune))
	mux.Handle("DELETE /v1/images/{id}", s.riskyAdmin(s.handleImageRemove))

	// Volumes.
	mux.Handle("GET /v1/volumes", s.viewer(s.handleVolumeList))
	mux.Handle("POST /v1/volumes", s.admin(s.handleVolumeCreate))
	mux.Handle("POST /v1/volumes/prune", s.riskyAdmin(s.handleVolumePrune))
	mux.Handle("DELETE /v1/volumes/{name}", s.riskyAdmin(s.handleVolumeRemove))

	// Networks.
	mux.Handle("GET /v1/networks", s.viewer(s.handleNetworkList))
	mux.Handle("POST /v1/networks", s.admin(s.handleNetworkCreate))
	mux.Handle("POST /v1/networks/prune", s.riskyAdmin(s.handleNetworkPrune))
	mux.Handle("DELETE /v1/networks/{id}", s.riskyAdmin(s.handleNetworkRemove))

	// Alerts.
	mux.Handle("GET /v1/alerts", s.viewer(s.handleAlertList))
	mux.Handle("POST /v1/alerts/{id}/mute", s.operator(s.handleAlertMute))
	mux.Handle("POST /v1/alerts/{id}/resolve", s.operator(s.handleAlertResolve))
	mux.Handle("GET /v1/alert-rules", s.viewer(s.handleAlertRuleList))
	mux.Handle("PATCH /v1/alert-rules/{id}", s.admin(s.handleAlertRulePatch))

	// Registries.
	mux.Handle("GET /v1/registries", s.viewer(s.handleRegistryList))
	mux.Handle("POST /v1/registries", s.admin(s.handleRegistryCreate))
	mux.Handle("PATCH /v1/registries/{id}", s.admin(s.handleRegistryPatch))
	mux.Handle("POST /v1/registries/{id}/test", s.admin(s.handleRegistryTest))
	mux.Handle("DELETE /v1/registries/{id}", s.admin(s.handleRegistryDelete))

	// Settings and agent update.
	mux.Handle("GET /v1/settings", s.viewer(s.handleSettingsGet))
	mux.Handle("PATCH /v1/settings", s.admin(s.handleSettingsPatch))
	mux.Handle("GET /v1/agent/update", s.viewer(s.handleAgentUpdateGet))
	mux.Handle("POST /v1/agent/update", s.admin(s.handleAgentUpdatePost))

	// Jobs.
	mux.Handle("GET /v1/jobs", s.viewer(s.handleJobList))
	mux.Handle("GET /v1/jobs/{id}", s.viewer(s.handleJobGet))
	mux.Handle("GET /v1/jobs/{id}/events", s.viewer(s.handleJobEvents))
	mux.Handle("POST /v1/jobs/{id}/cancel", s.operator(s.handleJobCancel))
}
