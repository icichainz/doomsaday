package httpapi

import (
	"context"
	"net/http"
	"time"

	"agent_zero/internal/dockerx"
	"agent_zero/internal/jobs"
)

func (s *Server) handleSwarm(w http.ResponseWriter, r *http.Request) {
	info, err := s.Docker.SwarmInfo(r.Context())
	if err != nil {
		s.fail(w, "swarm", err)
		return
	}
	writeJSON(w, http.StatusOK, info)
}

func (s *Server) handleServiceList(w http.ResponseWriter, r *http.Request) {
	page, err := readPage(r)
	if err != nil {
		validationError(w, "limit", err.Error())
		return
	}
	services, err := s.Docker.ServiceList(r.Context())
	if err != nil {
		s.fail(w, "service", err)
		return
	}
	items, next := paginate(services, page)
	writeJSON(w, http.StatusOK, listResponse{Items: items, NextCursor: next, Total: len(services)})
}

func (s *Server) serviceID(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := r.PathValue("id")
	if !validID(id) {
		validationError(w, "id", "the service id is not valid")
		return "", false
	}
	return id, true
}

func (s *Server) handleServiceTasks(w http.ResponseWriter, r *http.Request) {
	id, ok := s.serviceID(w, r)
	if !ok {
		return
	}
	page, err := readPage(r)
	if err != nil {
		validationError(w, "limit", err.Error())
		return
	}
	tasks, err := s.Docker.ServiceTasks(r.Context(), id)
	if err != nil {
		s.fail(w, "service", err)
		return
	}
	items, next := paginate(tasks, page)
	writeJSON(w, http.StatusOK, listResponse{Items: items, NextCursor: next, Total: len(tasks)})
}

type scaleRequest struct {
	Replicas *int `json:"replicas"`
}

func (s *Server) handleServiceScale(w http.ResponseWriter, r *http.Request) {
	id, ok := s.serviceID(w, r)
	if !ok {
		return
	}
	setAuditTarget(r, id)

	var body scaleRequest
	if err := decodeJSON(w, r, &body); err != nil {
		return
	}
	if body.Replicas == nil {
		validationError(w, "replicas", "replicas is required")
		return
	}
	if *body.Replicas < 0 || *body.Replicas > 1000 {
		validationError(w, "replicas", "replicas must be between 0 and 1000")
		return
	}
	if err := s.Docker.ServiceScale(r.Context(), id, uint64(*body.Replicas)); err != nil {
		s.fail(w, "service", err)
		return
	}
	setAuditDetail(r, "replicas", *body.Replicas)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "service_id": id, "replicas": *body.Replicas})
}

type serviceUpdateRequest struct {
	Image string `json:"image"`
	Force bool   `json:"force"`
}

func (s *Server) handleServiceUpdate(w http.ResponseWriter, r *http.Request) {
	id, ok := s.serviceID(w, r)
	if !ok {
		return
	}
	var body serviceUpdateRequest
	if err := decodeJSON(w, r, &body); err != nil {
		return
	}
	if body.Image != "" && !validImageRef(body.Image) {
		validationError(w, "image", "image is not a valid reference")
		return
	}
	if body.Image == "" && !body.Force {
		validationError(w, "image", "give an image or set force")
		return
	}
	// Fail fast when this node cannot do it at all, so the caller gets the
	// contract's 409 rather than a job that fails later.
	if _, err := s.Docker.ServiceList(r.Context()); err != nil {
		s.fail(w, "service", err)
		return
	}
	setAuditDetail(r, "image", body.Image)
	setAuditDetail(r, "force", body.Force)

	opts := dockerx.ServiceUpdateOptions{Image: body.Image, Force: body.Force}
	s.startJob(w, r, "service_update", id, func(h *jobs.Handle) error {
		ctx, cancel := context.WithTimeout(h.Ctx, 15*time.Minute)
		defer cancel()
		h.Logf("rolling update of service %s", id)
		if err := s.Docker.ServiceUpdate(ctx, id, opts); err != nil {
			h.Fail("service_update_failed", err.Error(), nil)
			return nil
		}
		h.Succeed(map[string]any{"service_id": id, "image": body.Image})
		return nil
	})
}

func (s *Server) handleServiceRollback(w http.ResponseWriter, r *http.Request) {
	id, ok := s.serviceID(w, r)
	if !ok {
		return
	}
	if _, err := s.Docker.ServiceList(r.Context()); err != nil {
		s.fail(w, "service", err)
		return
	}
	s.startJob(w, r, "service_rollback", id, func(h *jobs.Handle) error {
		ctx, cancel := context.WithTimeout(h.Ctx, 15*time.Minute)
		defer cancel()
		h.Logf("rolling back service %s", id)
		if err := s.Docker.ServiceRollback(ctx, id); err != nil {
			h.Fail("service_rollback_failed", err.Error(), nil)
			return nil
		}
		h.Succeed(map[string]any{"service_id": id})
		return nil
	})
}
