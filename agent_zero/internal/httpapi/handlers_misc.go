package httpapi

import (
	"errors"
	"net/http"
	"time"

	"agent_zero/internal/alerts"
	"agent_zero/internal/dockerx"
	"agent_zero/internal/jobs"
	"agent_zero/internal/registry"
)

// Label validation errors.
var (
	errTooManyLabels = errors.New("at most 64 labels are allowed")
	errBadLabel      = errors.New("label keys must be 1 to 128 characters and values at most 1024")
	errReservedLabel = errors.New("labels starting with com.docker. are reserved")
)

// ---------------------------------------------------------------- alerts

func (s *Server) handleAlertList(w http.ResponseWriter, r *http.Request) {
	page, err := readPage(r)
	if err != nil {
		validationError(w, "limit", err.Error())
		return
	}
	state := r.URL.Query().Get("state")
	switch state {
	case "", alerts.StateActive, alerts.StateResolved, alerts.StateMuted:
	default:
		validationError(w, "state", "state must be active, resolved or muted")
		return
	}
	list, err := s.Alerts.List(state)
	if err != nil {
		s.fail(w, "alert", err)
		return
	}
	if list == nil {
		list = []alerts.Alert{}
	}
	items, next := paginate(list, page)
	writeJSON(w, http.StatusOK, listResponse{Items: items, NextCursor: next, Total: len(list)})
}

type alertMuteRequest struct {
	Minutes int `json:"minutes"`
}

func (s *Server) handleAlertMute(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	setAuditTarget(r, id)

	var body alertMuteRequest
	if err := decodeJSON(w, r, &body); err != nil {
		return
	}
	a, err := s.Alerts.Mute(id, body.Minutes)
	if err != nil {
		s.fail(w, "alert", err)
		return
	}
	setAuditDetail(r, "minutes", body.Minutes)
	writeJSON(w, http.StatusOK, a)
}

func (s *Server) handleAlertResolve(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	setAuditTarget(r, id)

	a, err := s.Alerts.Resolve(id)
	if err != nil {
		s.fail(w, "alert", err)
		return
	}
	writeJSON(w, http.StatusOK, a)
}

func (s *Server) handleAlertRuleList(w http.ResponseWriter, r *http.Request) {
	rules, err := s.Alerts.Rules()
	if err != nil {
		s.fail(w, "alert_rule", err)
		return
	}
	writeJSON(w, http.StatusOK, listResponse{Items: rules, Total: len(rules)})
}

type alertRulePatchRequest struct {
	Enabled       *bool    `json:"enabled"`
	Threshold     *float64 `json:"threshold"`
	WindowSeconds *int     `json:"window_seconds"`
}

func (s *Server) handleAlertRulePatch(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	setAuditTarget(r, id)

	var body alertRulePatchRequest
	if err := decodeJSON(w, r, &body); err != nil {
		return
	}
	if body.Enabled == nil && body.Threshold == nil && body.WindowSeconds == nil {
		validationError(w, "enabled", "enabled, threshold or window_seconds must be given")
		return
	}
	rule, err := s.Alerts.UpdateRule(id, body.Enabled, body.Threshold, body.WindowSeconds)
	if err != nil {
		s.fail(w, "alert_rule", err)
		return
	}
	writeJSON(w, http.StatusOK, rule)
}

// ------------------------------------------------------------ registries

func (s *Server) handleRegistryList(w http.ResponseWriter, r *http.Request) {
	page, err := readPage(r)
	if err != nil {
		validationError(w, "limit", err.Error())
		return
	}
	list, err := s.Registries.List()
	if err != nil {
		s.fail(w, "registry", err)
		return
	}
	if list == nil {
		list = []registry.Registry{}
	}
	items, next := paginate(list, page)
	writeJSON(w, http.StatusOK, listResponse{Items: items, NextCursor: next, Total: len(list)})
}

type registryCreateRequest struct {
	Host     string `json:"host"`
	Username string `json:"username"`
	Secret   string `json:"secret"`
}

func (s *Server) handleRegistryCreate(w http.ResponseWriter, r *http.Request) {
	var body registryCreateRequest
	if err := decodeJSON(w, r, &body); err != nil {
		return
	}
	reg, err := s.Registries.Create(body.Host, body.Username, body.Secret)
	if err != nil {
		s.fail(w, "registry", err)
		return
	}
	setAuditTarget(r, reg.ID)
	setAuditDetail(r, "host", reg.Host)
	writeJSON(w, http.StatusCreated, reg)
}

type registryPatchRequest struct {
	Username *string `json:"username"`
	Secret   *string `json:"secret"`
}

func (s *Server) handleRegistryPatch(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	setAuditTarget(r, id)

	var body registryPatchRequest
	if err := decodeJSON(w, r, &body); err != nil {
		return
	}
	if body.Username == nil && body.Secret == nil {
		validationError(w, "secret", "username or secret must be given")
		return
	}
	reg, err := s.Registries.Update(id, body.Username, body.Secret)
	if err != nil {
		s.fail(w, "registry", err)
		return
	}
	setAuditDetail(r, "secret_rotated", body.Secret != nil)
	writeJSON(w, http.StatusOK, reg)
}

func (s *Server) handleRegistryTest(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	setAuditTarget(r, id)

	cred, err := s.Registries.Credential(id)
	if err != nil {
		s.fail(w, "registry", err)
		return
	}
	ctx, cancel := contextWithTimeout(r, 20*time.Second)
	defer cancel()

	loginErr := s.Docker.RegistryLogin(ctx, dockerx.RegistryAuth{
		Host: cred.Host, Username: cred.Username, Secret: cred.Secret,
	})
	status := registry.StatusOK
	message := ""
	if loginErr != nil {
		status = registry.StatusFailed
		message = loginErr.Error()
	}
	reg, err := s.Registries.SetStatus(id, status, message)
	if err != nil {
		s.fail(w, "registry", err)
		return
	}
	setAuditDetail(r, "status", status)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":       loginErr == nil,
		"status":   status,
		"message":  message,
		"registry": reg,
	})
}

func (s *Server) handleRegistryDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	setAuditTarget(r, id)
	if err := s.Registries.Delete(id); err != nil {
		s.fail(w, "registry", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// -------------------------------------------------------------- settings

func (s *Server) handleSettingsGet(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.Settings.Get())
}

type settingsPatchRequest struct {
	RequireBiometricForRisky *bool   `json:"require_biometric_for_risky"`
	StacksDir                *string `json:"stacks_dir"`
}

func (s *Server) handleSettingsPatch(w http.ResponseWriter, r *http.Request) {
	var body settingsPatchRequest
	if err := decodeJSON(w, r, &body); err != nil {
		return
	}
	if body.RequireBiometricForRisky == nil && body.StacksDir == nil {
		validationError(w, "require_biometric_for_risky", "nothing to change")
		return
	}
	next, err := s.Settings.Update(body.RequireBiometricForRisky, body.StacksDir)
	if err != nil {
		s.fail(w, "settings", err)
		return
	}
	if body.StacksDir != nil {
		s.Compose.StacksDir = next.StacksDir
	}
	if body.RequireBiometricForRisky != nil {
		setAuditDetail(r, "require_biometric_for_risky", *body.RequireBiometricForRisky)
	}
	writeJSON(w, http.StatusOK, next)
}

// ---------------------------------------------------------- agent update

func (s *Server) handleAgentUpdateGet(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"current_version":    s.Version,
		"latest_version":     "unknown",
		"update_available":   false,
		"release_notes_url":  nil,
		"update_channel":     "not_configured",
		"self_update_status": "not_configured",
		"message":            "this agent has no update channel configured, so it cannot check for or install updates",
	})
}

func (s *Server) handleAgentUpdatePost(w http.ResponseWriter, r *http.Request) {
	s.startJob(w, r, "agent_update", s.Version, func(h *jobs.Handle) error {
		h.Logf("checking for an update channel")
		h.Fail(codeNotConfigured,
			"this agent has no update channel configured: it will not download or execute anything",
			map[string]any{"current_version": s.Version})
		return nil
	})
}
