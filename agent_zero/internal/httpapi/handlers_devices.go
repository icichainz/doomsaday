package httpapi

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"agent_zero/internal/audit"
	"agent_zero/internal/auth"
)

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

type pairRequest struct {
	Token      string `json:"token"`
	DeviceName string `json:"device_name"`
	PushToken  string `json:"push_token"`
}

type pairResponse struct {
	DeviceKey       string `json:"device_key"`
	DeviceID        string `json:"device_id"`
	Role            string `json:"role"`
	CertFingerprint string `json:"cert_fingerprint"`
	AgentVersion    string `json:"agent_version"`
}

func (s *Server) handlePair(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !s.PairLimiter.Allow(ip) {
		retry := s.PairLimiter.RetryAfter(ip)
		w.Header().Set("Retry-After", strconv.Itoa(int(retry.Seconds())+1))
		writeError(w, http.StatusTooManyRequests, codeRateLimited,
			"too many pairing attempts from this address", nil)
		return
	}

	var body pairRequest
	if err := decodeJSON(w, r, &body); err != nil {
		return
	}
	if body.Token == "" {
		validationError(w, "token", "token is required")
		return
	}

	res, err := s.Auth.Pair(body.Token, body.DeviceName, body.PushToken)
	if err != nil {
		switch {
		case errors.Is(err, auth.ErrBadToken):
			s.Audit.Write(audit.Record{
				Time: time.Now().UTC(), Action: "POST /v1/pair", Target: body.DeviceName,
				Result: audit.ResultDenied, Status: http.StatusUnauthorized, RemoteIP: ip,
			})
			writeError(w, http.StatusUnauthorized, codePairingFailed,
				"the pairing token is not valid or has expired", nil)
		case errors.Is(err, auth.ErrInvalidInput):
			validationError(w, "device_name", err.Error())
		default:
			s.fail(w, "device", err)
		}
		return
	}

	s.Audit.Write(audit.Record{
		Time: time.Now().UTC(), DeviceID: res.Device.ID, DeviceName: res.Device.Name,
		Role: string(res.Device.Role), Action: "POST /v1/pair", Target: res.Device.ID,
		Result: audit.ResultOK, Status: http.StatusCreated, RemoteIP: ip,
	})
	s.Log.Info("device paired", "device", res.Device.ID, "name", res.Device.Name, "role", res.Device.Role)

	writeJSON(w, http.StatusCreated, pairResponse{
		DeviceKey:       res.DeviceKey,
		DeviceID:        res.Device.ID,
		Role:            string(res.Device.Role),
		CertFingerprint: s.CertFingerprint,
		AgentVersion:    s.Version,
	})
}

// meResponse is GET /v1/me: who the caller is according to the agent, the
// fingerprint the app pins, and how many phones are paired. The role is read
// fresh on every request, so a role an admin changed later is noticed.
type meResponse struct {
	DeviceID        string `json:"device_id"`
	DeviceName      string `json:"device_name"`
	Role            string `json:"role"`
	CertFingerprint string `json:"cert_fingerprint"`
	PairedDevices   int    `json:"paired_devices"`
	AgentVersion    string `json:"agent_version"`
}

// handleMe answers for any authenticated role. It is a read, so it writes no
// audit record.
func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	dev, ok := deviceFrom(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, codeUnauthorized, "authentication is required", nil)
		return
	}
	devices, err := s.Auth.List()
	if err != nil {
		s.fail(w, "device", err)
		return
	}
	writeJSON(w, http.StatusOK, meResponse{
		DeviceID:        dev.ID,
		DeviceName:      dev.Name,
		Role:            string(dev.Role),
		CertFingerprint: s.CertFingerprint,
		PairedDevices:   len(devices),
		AgentVersion:    s.Version,
	})
}

// deviceDTO is a device as the API returns it: no key material.
type deviceDTO struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	Role       string    `json:"role"`
	CreatedAt  time.Time `json:"created_at"`
	LastSeenAt time.Time `json:"last_seen_at"`
	HasPush    bool      `json:"has_push_token"`
	Self       bool      `json:"is_self"`
}

func toDeviceDTO(d auth.Device, selfID string) deviceDTO {
	return deviceDTO{
		ID:         d.ID,
		Name:       d.Name,
		Role:       string(d.Role),
		CreatedAt:  d.CreatedAt,
		LastSeenAt: d.LastSeenAt,
		HasPush:    d.PushToken != "",
		Self:       d.ID == selfID,
	}
}

func (s *Server) handleDeviceList(w http.ResponseWriter, r *http.Request) {
	page, err := readPage(r)
	if err != nil {
		validationError(w, "limit", err.Error())
		return
	}
	devices, err := s.Auth.List()
	if err != nil {
		s.fail(w, "device", err)
		return
	}
	self, _ := deviceFrom(r)
	out := make([]deviceDTO, 0, len(devices))
	for _, d := range devices {
		out = append(out, toDeviceDTO(d, self.ID))
	}
	items, next := paginate(out, page)
	writeJSON(w, http.StatusOK, listResponse{Items: items, NextCursor: next, Total: len(out)})
}

type devicePatchRequest struct {
	Role      *string `json:"role"`
	PushToken *string `json:"push_token"`
}

func (s *Server) handleDevicePatch(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	setAuditTarget(r, id)

	var body devicePatchRequest
	if err := decodeJSON(w, r, &body); err != nil {
		return
	}
	if body.Role == nil && body.PushToken == nil {
		validationError(w, "role", "role or push_token must be given")
		return
	}

	var role *auth.Role
	if body.Role != nil {
		rl := auth.Role(*body.Role)
		if !auth.ValidRole(rl) {
			validationError(w, "role", "role must be admin, operator or viewer")
			return
		}
		role = &rl
	}

	// Refuse to remove the last admin, which would lock the host out.
	if role != nil && *role != auth.RoleAdmin {
		target, err := s.Auth.Get(id)
		if err != nil {
			s.fail(w, "device", err)
			return
		}
		if target.Role == auth.RoleAdmin {
			admins, err := s.Auth.CountAdmins()
			if err != nil {
				s.fail(w, "device", err)
				return
			}
			if admins <= 1 {
				writeError(w, http.StatusConflict, codeConflict,
					"the last admin device cannot be demoted", nil)
				return
			}
		}
	}

	dev, err := s.Auth.Update(id, role, body.PushToken)
	if err != nil {
		s.fail(w, "device", err)
		return
	}
	if body.Role != nil {
		setAuditDetail(r, "role", *body.Role)
	}
	self, _ := deviceFrom(r)
	writeJSON(w, http.StatusOK, toDeviceDTO(dev, self.ID))
}

func (s *Server) handleDeviceDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	setAuditTarget(r, id)

	target, err := s.Auth.Get(id)
	if err != nil {
		s.fail(w, "device", err)
		return
	}
	if target.Role == auth.RoleAdmin {
		admins, err := s.Auth.CountAdmins()
		if err != nil {
			s.fail(w, "device", err)
			return
		}
		self, _ := deviceFrom(r)
		if admins <= 1 && target.ID != self.ID {
			writeError(w, http.StatusConflict, codeConflict,
				"the last admin device cannot be revoked", nil)
			return
		}
	}
	if err := s.Auth.Delete(id); err != nil {
		s.fail(w, "device", err)
		return
	}
	setAuditDetail(r, "device_name", target.Name)
	w.WriteHeader(http.StatusNoContent)
}
