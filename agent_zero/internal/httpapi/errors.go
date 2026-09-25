package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"agent_zero/internal/alerts"
	"agent_zero/internal/auth"
	"agent_zero/internal/compose"
	"agent_zero/internal/dockerx"
	"agent_zero/internal/registry"
	"agent_zero/internal/settings"
)

// errorDetail is the inner object of the contract's error envelope.
type errorDetail struct {
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details"`
}

// errorEnvelope is exactly `{"error": {...}}`.
type errorEnvelope struct {
	Error errorDetail `json:"error"`
}

// Error codes used by the agent.
const (
	codeBadRequest           = "bad_request"
	codeUnauthorized         = "unauthorized"
	codeForbidden            = "forbidden"
	codeNotFound             = "not_found"
	codeConflict             = "conflict"
	codeValidationFailed     = "validation_failed"
	codeInternal             = "internal_error"
	codeDockerUnavailable    = "docker_unavailable"
	codeNotAManager          = "not_a_manager"
	codeConfirmationRequired = "confirmation_required"
	codeRateLimited          = "rate_limited"
	codePairingFailed        = "pairing_failed"
	codeNotConfigured        = "not_configured"
	codeUnsupported          = "unsupported"
	codePayloadTooLarge      = "payload_too_large"
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	if v == nil {
		return
	}
	enc := json.NewEncoder(w)
	_ = enc.Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, message string, details map[string]any) {
	if details == nil {
		details = map[string]any{}
	}
	writeJSON(w, status, errorEnvelope{Error: errorDetail{Code: code, Message: message, Details: details}})
}

// notFoundCode turns a resource name into the contract's code shape, for
// example "container" into "container_not_found".
func notFoundCode(resource string) string {
	if resource == "" {
		return codeNotFound
	}
	return resource + "_not_found"
}

// fail maps a domain error onto a status and a code. resource names the thing
// being acted on so 404s read as container_not_found, image_not_found, and so
// on, as the contract's example does.
func (s *Server) fail(w http.ResponseWriter, resource string, err error) {
	switch {
	case err == nil:
		return

	case errors.Is(err, dockerx.ErrUnavailable):
		writeError(w, http.StatusBadGateway, codeDockerUnavailable,
			"the Docker daemon could not be reached", nil)

	case errors.Is(err, dockerx.ErrNotManager):
		writeError(w, http.StatusConflict, codeNotAManager,
			"this host is not a Swarm manager", nil)

	case errors.Is(err, dockerx.ErrNotFound),
		errors.Is(err, compose.ErrNotFound),
		errors.Is(err, registry.ErrNotFound),
		errors.Is(err, alerts.ErrNotFound),
		errors.Is(err, auth.ErrNoDevice):
		writeError(w, http.StatusNotFound, notFoundCode(resource), resource+" not found", nil)

	case errors.Is(err, dockerx.ErrConflict):
		writeError(w, http.StatusConflict, codeConflict, err.Error(), nil)

	case errors.Is(err, dockerx.ErrUnsupported):
		writeError(w, http.StatusInternalServerError, codeUnsupported,
			"this operation is not supported on this host", nil)

	case errors.Is(err, registry.ErrInvalid),
		errors.Is(err, alerts.ErrInvalid),
		errors.Is(err, settings.ErrInvalid),
		errors.Is(err, compose.ErrInvalid),
		errors.Is(err, auth.ErrInvalidInput):
		writeError(w, http.StatusUnprocessableEntity, codeValidationFailed, err.Error(), nil)

	default:
		s.Log.Error("request failed", "resource", resource, "error", err)
		writeError(w, http.StatusInternalServerError, codeInternal,
			"the agent could not complete the request", nil)
	}
}

// validationError reports one bad field.
func validationError(w http.ResponseWriter, field, message string) {
	writeError(w, http.StatusUnprocessableEntity, codeValidationFailed, message,
		map[string]any{"field": field})
}
