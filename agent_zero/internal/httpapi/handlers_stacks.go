package httpapi

import (
	"context"
	"net/http"
	"time"

	"agent_zero/internal/compose"
	"agent_zero/internal/jobs"
)

func (s *Server) handleStackList(w http.ResponseWriter, r *http.Request) {
	page, err := readPage(r)
	if err != nil {
		validationError(w, "limit", err.Error())
		return
	}
	projects, err := s.Compose.Discover(r.Context())
	if err != nil {
		s.fail(w, "stack", err)
		return
	}
	// serviceRow carries running and total per service, so the segmented
	// health bar on the stacks screen needs no second call. Containers are
	// left to GET /v1/stacks/{name}.
	type serviceRow struct {
		Name    string `json:"name"`
		Running int    `json:"running"`
		Total   int    `json:"total"`
	}
	type row struct {
		Name            string       `json:"name"`
		Source          string       `json:"source"`
		Services        []serviceRow `json:"services"`
		ServicesRunning int          `json:"services_running"`
		ServicesTotal   int          `json:"services_total"`
		ConfigOnDisk    bool         `json:"config_on_disk"`
		WorkingDir      string       `json:"working_dir,omitempty"`
	}
	out := make([]row, 0, len(projects))
	for _, p := range projects {
		services := make([]serviceRow, 0, len(p.Services))
		for _, svc := range p.Services {
			services = append(services, serviceRow{svc.Name, svc.Running, svc.Total})
		}
		out = append(out, row{
			Name: p.Name, Source: p.Source, Services: services,
			ServicesRunning: p.Running, ServicesTotal: p.Total,
			ConfigOnDisk: p.ConfigOnDisk, WorkingDir: p.WorkingDir,
		})
	}
	items, next := paginate(out, page)
	writeJSON(w, http.StatusOK, listResponse{Items: items, NextCursor: next, Total: len(out)})
}

func (s *Server) stackName(w http.ResponseWriter, r *http.Request) (string, bool) {
	name := r.PathValue("name")
	if err := compose.ValidateName(name); err != nil {
		validationError(w, "name", "the stack name is not a valid Compose project name")
		return "", false
	}
	return name, true
}

func (s *Server) handleStackGet(w http.ResponseWriter, r *http.Request) {
	name, ok := s.stackName(w, r)
	if !ok {
		return
	}
	p, err := s.Compose.Get(r.Context(), name)
	if err != nil {
		s.fail(w, "stack", err)
		return
	}
	type serviceRow struct {
		Name       string         `json:"name"`
		Running    int            `json:"running"`
		Total      int            `json:"total"`
		Containers []containerDTO `json:"containers"`
	}
	services := make([]serviceRow, 0, len(p.Services))
	for _, svc := range p.Services {
		cs := make([]containerDTO, 0, len(svc.Containers))
		for _, c := range svc.Containers {
			cs = append(cs, toContainerDTO(c))
		}
		services = append(services, serviceRow{svc.Name, svc.Running, svc.Total, cs})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"name":             p.Name,
		"source":           p.Source,
		"config_files":     p.ConfigFiles,
		"working_dir":      p.WorkingDir,
		"config_on_disk":   p.ConfigOnDisk,
		"services":         services,
		"services_running": p.Running,
		"services_total":   p.Total,
	})
}

// stackJob resolves the project and runs the compose action as a job.
func (s *Server) stackJob(w http.ResponseWriter, r *http.Request, action compose.Action) {
	name, ok := s.stackName(w, r)
	if !ok {
		return
	}
	p, err := s.Compose.Get(r.Context(), name)
	if err != nil {
		s.fail(w, "stack", err)
		return
	}
	if !p.ConfigOnDisk || len(p.ConfigFiles) == 0 {
		writeError(w, http.StatusConflict, codeConflict,
			"no compose file was found for this stack, so it cannot be driven from here",
			map[string]any{"stack": name, "source": p.Source})
		return
	}

	setAuditDetail(r, "action", string(action))
	s.startJob(w, r, "stack_"+string(action), name, func(h *jobs.Handle) error {
		ctx, cancel := context.WithTimeout(h.Ctx, 30*time.Minute)
		defer cancel()

		h.Logf("stack %s: %s", name, action)
		err := s.ComposeRunner.Run(ctx, p, action, func(line string) { h.Logf("%s", line) })
		if err != nil {
			h.Fail("compose_failed", err.Error(), map[string]any{"stack": name, "action": string(action)})
			return nil
		}
		h.Succeed(map[string]any{"stack": name, "action": string(action)})
		return nil
	})
}

func (s *Server) handleStackUp(w http.ResponseWriter, r *http.Request) {
	s.stackJob(w, r, compose.ActionUp)
}

func (s *Server) handleStackRedeploy(w http.ResponseWriter, r *http.Request) {
	s.stackJob(w, r, compose.ActionRedeploy)
}

func (s *Server) handleStackRestart(w http.ResponseWriter, r *http.Request) {
	s.stackJob(w, r, compose.ActionRestart)
}

func (s *Server) handleStackDown(w http.ResponseWriter, r *http.Request) {
	s.stackJob(w, r, compose.ActionDown)
}
