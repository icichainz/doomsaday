package httpapi

import (
	"errors"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"agent_zero/internal/dockerx"
	"agent_zero/internal/sse"
)

// containerDTO is a container list row.
type containerDTO struct {
	ID            string         `json:"id"`
	Name          string         `json:"name"`
	Image         string         `json:"image"`
	State         string         `json:"state"`
	Status        string         `json:"status"`
	Health        string         `json:"health,omitempty"`
	Stack         string         `json:"stack,omitempty"`
	Service       string         `json:"service,omitempty"`
	CreatedAt     time.Time      `json:"created_at"`
	StartedAt     *time.Time     `json:"started_at,omitempty"`
	FinishedAt    *time.Time     `json:"finished_at,omitempty"`
	UptimeSeconds int64          `json:"uptime_seconds"`
	RestartCount  int            `json:"restart_count"`
	ExitCode      int            `json:"exit_code"`
	CPUPercent    float64        `json:"cpu_percent"`
	MemoryUsage   int64          `json:"memory_usage"`
	MemoryLimit   int64          `json:"memory_limit"`
	MemoryPercent float64        `json:"memory_percent"`
	Ports         []dockerx.Port `json:"ports"`
}

func toContainerDTO(c dockerx.Container) containerDTO {
	d := containerDTO{
		ID:           c.ID,
		Name:         c.Name,
		Image:        c.Image,
		State:        c.State,
		Status:       c.Status,
		Health:       c.Health,
		Stack:        c.Stack,
		Service:      c.Service,
		CreatedAt:    c.CreatedAt,
		RestartCount: c.RestartCount,
		ExitCode:     c.ExitCode,
		Ports:        c.Ports,
	}
	if d.Ports == nil {
		d.Ports = []dockerx.Port{}
	}
	if !c.StartedAt.IsZero() {
		started := c.StartedAt
		d.StartedAt = &started
		if c.State == "running" {
			d.UptimeSeconds = int64(time.Since(started).Seconds())
		}
	}
	// Docker keeps the previous finish time on a container that is running again.
	if !c.FinishedAt.IsZero() && c.State != "running" {
		finished := c.FinishedAt
		d.FinishedAt = &finished
	}
	return d
}

func (s *Server) handleContainerList(w http.ResponseWriter, r *http.Request) {
	page, err := readPage(r)
	if err != nil {
		validationError(w, "limit", err.Error())
		return
	}
	q := r.URL.Query()
	state := q.Get("state")
	switch state {
	case "", "running", "exited", "restarting", "paused", "created", "dead":
	default:
		validationError(w, "state", "state must be one of running, exited, restarting, paused, created or dead")
		return
	}
	stack := q.Get("stack")
	if stack != "" && !validID(stack) {
		validationError(w, "stack", "stack is not a valid project name")
		return
	}
	search := q.Get("q")
	if len(search) > maxQueryLen {
		validationError(w, "q", "q is too long")
		return
	}

	containers, err := s.Docker.ContainerList(r.Context(), dockerx.ContainerListOptions{State: state, Stack: stack})
	if err != nil {
		s.fail(w, "container", err)
		return
	}

	out := make([]containerDTO, 0, len(containers))
	for _, c := range containers {
		if search != "" && !(containsFold(c.Name, search) || containsFold(c.Image, search) || strings.HasPrefix(c.ID, search)) {
			continue
		}
		out = append(out, toContainerDTO(c))
	}

	// Live figures only for the page actually returned, so a long list does
	// not open a stats stream per container.
	items, next := paginate(out, page)
	s.fillStats(r, items)

	writeJSON(w, http.StatusOK, listResponse{Items: items, NextCursor: next, Total: len(out)})
}

// fillStats samples CPU and memory for the rows being returned.
func (s *Server) fillStats(r *http.Request, rows []containerDTO) {
	type result struct {
		idx int
		st  dockerx.Stats
	}
	ch := make(chan result, len(rows))
	n := 0
	for i, row := range rows {
		if row.State != "running" {
			continue
		}
		n++
		go func(idx int, id string) {
			st, err := s.Docker.ContainerStats(r.Context(), id)
			if err != nil {
				ch <- result{idx: -1}
				return
			}
			ch <- result{idx: idx, st: st}
		}(i, row.ID)
	}
	for i := 0; i < n; i++ {
		res := <-ch
		if res.idx < 0 {
			continue
		}
		rows[res.idx].CPUPercent = round2(res.st.CPUPercent)
		rows[res.idx].MemoryUsage = res.st.MemUsage
		rows[res.idx].MemoryLimit = res.st.MemLimit
		rows[res.idx].MemoryPercent = round2(res.st.MemPercent)
	}
}

// containerDetailDTO carries environment variable names only.
type containerDetailDTO struct {
	containerDTO
	Command       string                      `json:"command,omitempty"`
	Entrypoint    []string                    `json:"entrypoint,omitempty"`
	WorkingDir    string                      `json:"working_dir,omitempty"`
	User          string                      `json:"user,omitempty"`
	Platform      string                      `json:"platform,omitempty"`
	Networks      []dockerx.NetworkAttachment `json:"networks"`
	Mounts        []dockerx.Mount             `json:"mounts"`
	RestartPolicy dockerx.RestartPolicy       `json:"restart_policy"`
	LogDriver     string                      `json:"log_driver,omitempty"`
	Labels        map[string]string           `json:"labels"`
	EnvNames      []string                    `json:"env_names"`
}

func envNames(env []string) []string {
	out := make([]string, 0, len(env))
	for _, e := range env {
		name, _, _ := strings.Cut(e, "=")
		if name != "" {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

func (s *Server) containerID(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := r.PathValue("id")
	if !validID(id) {
		validationError(w, "id", "the container id is not valid")
		return "", false
	}
	return id, true
}

func (s *Server) handleContainerGet(w http.ResponseWriter, r *http.Request) {
	id, ok := s.containerID(w, r)
	if !ok {
		return
	}
	det, err := s.Docker.ContainerInspect(r.Context(), id)
	if err != nil {
		s.fail(w, "container", err)
		return
	}
	dto := containerDetailDTO{
		containerDTO:  toContainerDTO(det.Container),
		Command:       det.Command,
		Entrypoint:    det.Entrypoint,
		WorkingDir:    det.WorkingDir,
		User:          det.User,
		Platform:      det.Platform,
		Networks:      det.Networks,
		Mounts:        det.Mounts,
		RestartPolicy: det.RestartPolicy,
		LogDriver:     det.LogDriver,
		Labels:        det.Labels,
		EnvNames:      envNames(det.Env),
	}
	if dto.Labels == nil {
		dto.Labels = map[string]string{}
	}
	if det.State == "running" {
		if st, err := s.Docker.ContainerStats(r.Context(), id); err == nil {
			dto.CPUPercent = round2(st.CPUPercent)
			dto.MemoryUsage = st.MemUsage
			dto.MemoryLimit = st.MemLimit
			dto.MemoryPercent = round2(st.MemPercent)
		}
	}
	writeJSON(w, http.StatusOK, dto)
}

func (s *Server) handleContainerEnv(w http.ResponseWriter, r *http.Request) {
	id, ok := s.containerID(w, r)
	if !ok {
		return
	}
	setAuditTarget(r, id)

	det, err := s.Docker.ContainerInspect(r.Context(), id)
	if err != nil {
		s.fail(w, "container", err)
		return
	}
	vars := make([]map[string]string, 0, len(det.Env))
	for _, e := range det.Env {
		name, value, _ := strings.Cut(e, "=")
		if name == "" {
			continue
		}
		vars = append(vars, map[string]string{"name": name, "value": value})
	}
	sort.Slice(vars, func(i, j int) bool { return vars[i]["name"] < vars[j]["name"] })
	setAuditDetail(r, "container", det.Name)
	writeJSON(w, http.StatusOK, map[string]any{"container_id": det.ID, "name": det.Name, "env": vars})
}

func (s *Server) handleContainerStatsStream(w http.ResponseWriter, r *http.Request) {
	id, ok := s.containerID(w, r)
	if !ok {
		return
	}
	stream, err := sse.NewWriter(w, r)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "streaming is not supported", nil)
		return
	}

	ctx := r.Context()
	samples := make(chan dockerx.Stats, 8)
	done := make(chan error, 1)
	go func() { done <- s.Docker.ContainerStatsStream(ctx, id, samples) }()

	type rateSample struct {
		rx, tx int64
		at     time.Time
	}
	var prev *rateSample

	for {
		select {
		case <-ctx.Done():
			return
		case err := <-done:
			if err != nil && ctx.Err() == nil {
				_ = stream.Send("error", errorDetail{Code: codeDockerUnavailable, Message: err.Error(), Details: map[string]any{}})
			}
			return
		case st, ok := <-samples:
			if !ok {
				return
			}
			payload := map[string]any{
				"ts":             st.Time.Format(time.RFC3339),
				"cpu_percent":    round2(st.CPUPercent),
				"memory_usage":   st.MemUsage,
				"memory_limit":   st.MemLimit,
				"memory_percent": round2(st.MemPercent),
				"net_rx_bytes":   st.NetRxBytes,
				"net_tx_bytes":   st.NetTxBytes,
				"pids":           st.PIDs,
			}
			if prev != nil {
				if secs := st.Time.Sub(prev.at).Seconds(); secs > 0 {
					payload["net_rx_bytes_per_second"] = round2(float64(st.NetRxBytes-prev.rx) / secs)
					payload["net_tx_bytes_per_second"] = round2(float64(st.NetTxBytes-prev.tx) / secs)
				}
			}
			prev = &rateSample{rx: st.NetRxBytes, tx: st.NetTxBytes, at: st.Time}
			if err := stream.Send("stats", payload); err != nil {
				return
			}
		}
	}
}

func (s *Server) handleContainerImpact(w http.ResponseWriter, r *http.Request) {
	id, ok := s.containerID(w, r)
	if !ok {
		return
	}
	det, err := s.Docker.ContainerInspect(r.Context(), id)
	if err != nil {
		s.fail(w, "container", err)
		return
	}

	published := make([]dockerx.Port, 0, len(det.Ports))
	for _, p := range det.Ports {
		if p.PublicPort != 0 {
			published = append(published, p)
		}
	}

	all, err := s.Docker.ContainerList(r.Context(), dockerx.ContainerListOptions{})
	if err != nil {
		s.fail(w, "container", err)
		return
	}
	networks := map[string]bool{}
	for _, n := range det.Networks {
		networks[n.Name] = true
	}

	type dependent struct {
		ID     string `json:"id"`
		Name   string `json:"name"`
		State  string `json:"state"`
		Reason string `json:"reason"`
	}
	dependents := []dependent{}
	seen := map[string]bool{}

	for _, c := range all {
		if c.ID == det.ID || seen[c.ID] {
			continue
		}
		// Same compose project and depends_on is the strongest signal we can
		// read back from the daemon.
		if det.Stack != "" && c.Stack == det.Stack {
			if deps := c.Labels["com.docker.compose.depends_on"]; deps != "" && det.Service != "" {
				for _, d := range strings.Split(deps, ",") {
					name, _, _ := strings.Cut(strings.TrimSpace(d), ":")
					if name == det.Service {
						dependents = append(dependents, dependent{c.ID, c.Name, c.State, "depends_on"})
						seen[c.ID] = true
						break
					}
				}
			}
		}
	}
	for _, c := range all {
		if c.ID == det.ID || seen[c.ID] {
			continue
		}
		if det.NetworkMode == "container:"+c.ID || strings.HasPrefix(det.NetworkMode, "container:"+c.Name) {
			dependents = append(dependents, dependent{c.ID, c.Name, c.State, "shares_network_namespace"})
			seen[c.ID] = true
		}
	}

	sameStack := []dependent{}
	if det.Stack != "" {
		for _, c := range all {
			if c.ID != det.ID && c.Stack == det.Stack {
				sameStack = append(sameStack, dependent{c.ID, c.Name, c.State, "same_stack"})
			}
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"container_id":    det.ID,
		"name":            det.Name,
		"state":           det.State,
		"published_ports": published,
		"dependents":      dependents,
		"same_stack":      sameStack,
		"networks":        det.Networks,
		"restart_policy":  det.RestartPolicy,
	})
}

// action runs a simple container operation and answers 204.
func (s *Server) containerAction(w http.ResponseWriter, r *http.Request, name string, fn func(id string) error) {
	id, ok := s.containerID(w, r)
	if !ok {
		return
	}
	setAuditTarget(r, id)
	if err := fn(id); err != nil {
		s.fail(w, "container", err)
		return
	}
	setAuditDetail(r, "operation", name)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "container_id": id, "action": name})
}

func (s *Server) stopTimeout(w http.ResponseWriter, r *http.Request) (int, bool) {
	t, err := queryInt(r, "timeout", 10, 0, maxStopWait)
	if err != nil {
		validationError(w, "timeout", err.Error())
		return 0, false
	}
	return t, true
}

func (s *Server) handleContainerStart(w http.ResponseWriter, r *http.Request) {
	s.containerAction(w, r, "start", func(id string) error {
		return s.Docker.ContainerStart(r.Context(), id)
	})
}

func (s *Server) handleContainerStop(w http.ResponseWriter, r *http.Request) {
	timeout, ok := s.stopTimeout(w, r)
	if !ok {
		return
	}
	s.containerAction(w, r, "stop", func(id string) error {
		return s.Docker.ContainerStop(r.Context(), id, timeout)
	})
}

func (s *Server) handleContainerRestart(w http.ResponseWriter, r *http.Request) {
	timeout, ok := s.stopTimeout(w, r)
	if !ok {
		return
	}
	s.containerAction(w, r, "restart", func(id string) error {
		return s.Docker.ContainerRestart(r.Context(), id, timeout)
	})
}

func (s *Server) handleContainerPause(w http.ResponseWriter, r *http.Request) {
	s.containerAction(w, r, "pause", func(id string) error {
		return s.Docker.ContainerPause(r.Context(), id)
	})
}

func (s *Server) handleContainerUnpause(w http.ResponseWriter, r *http.Request) {
	s.containerAction(w, r, "unpause", func(id string) error {
		return s.Docker.ContainerUnpause(r.Context(), id)
	})
}

func (s *Server) handleContainerRemove(w http.ResponseWriter, r *http.Request) {
	force, err := queryBool(r, "force")
	if err != nil {
		validationError(w, "force", err.Error())
		return
	}
	volumes, err := queryBool(r, "volumes")
	if err != nil {
		validationError(w, "volumes", err.Error())
		return
	}
	id, ok := s.containerID(w, r)
	if !ok {
		return
	}
	setAuditTarget(r, id)
	setAuditDetail(r, "force", force)
	setAuditDetail(r, "volumes", volumes)

	if err := s.Docker.ContainerRemove(r.Context(), id, force, volumes); err != nil {
		s.fail(w, "container", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// logQuery is the shared parsing for both log endpoints.
type logQuery struct {
	opts   dockerx.LogOptions
	filter string
}

func (s *Server) readLogQuery(w http.ResponseWriter, r *http.Request, follow bool) (logQuery, bool) {
	q := logQuery{opts: dockerx.LogOptions{Follow: follow, Stdout: true, Stderr: true}}

	since, err := queryTime(r, "since")
	if err != nil {
		validationError(w, "since", err.Error())
		return q, false
	}
	until, err := queryTime(r, "until")
	if err != nil {
		validationError(w, "until", err.Error())
		return q, false
	}
	q.opts.Since, q.opts.Until = since, until

	switch stream := r.URL.Query().Get("stream"); stream {
	case "":
	case "stdout":
		q.opts.Stderr = false
	case "stderr":
		q.opts.Stdout = false
	default:
		validationError(w, "stream", "stream must be stdout or stderr")
		return q, false
	}

	tail := r.URL.Query().Get("tail")
	switch {
	case tail == "", tail == "all":
		q.opts.Tail = "200"
		if follow {
			q.opts.Tail = "100"
		}
	default:
		n, err := strconv.Atoi(tail)
		if err != nil || n < 1 || n > maxTailLines {
			validationError(w, "tail", "tail must be a whole number between 1 and "+strconv.Itoa(maxTailLines))
			return q, false
		}
		q.opts.Tail = strconv.Itoa(n)
	}

	q.filter = r.URL.Query().Get("q")
	if len(q.filter) > maxQueryLen {
		validationError(w, "q", "q is too long")
		return q, false
	}
	return q, true
}

func (s *Server) handleContainerLogs(w http.ResponseWriter, r *http.Request) {
	id, ok := s.containerID(w, r)
	if !ok {
		return
	}
	q, ok := s.readLogQuery(w, r, false)
	if !ok {
		return
	}

	reader, err := s.Docker.ContainerLogs(r.Context(), id, q.opts)
	if err != nil {
		s.fail(w, "container", err)
		return
	}
	defer reader.Close()

	lines := make([]dockerx.LogLine, 0, 256)
	for len(lines) < maxTailLines {
		line, err := reader.Next()
		if err != nil {
			if !errors.Is(err, io.EOF) && r.Context().Err() == nil {
				s.Log.Debug("log read ended", "container", id, "error", err)
			}
			break
		}
		if q.filter != "" && !containsFold(line.Line, q.filter) {
			continue
		}
		lines = append(lines, line)
	}
	writeJSON(w, http.StatusOK, map[string]any{"container_id": id, "lines": lines, "count": len(lines)})
}

func (s *Server) handleContainerLogsStream(w http.ResponseWriter, r *http.Request) {
	id, ok := s.containerID(w, r)
	if !ok {
		return
	}
	q, ok := s.readLogQuery(w, r, true)
	if !ok {
		return
	}

	reader, err := s.Docker.ContainerLogs(r.Context(), id, q.opts)
	if err != nil {
		s.fail(w, "container", err)
		return
	}
	defer reader.Close()

	stream, err := sse.NewWriter(w, r)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "streaming is not supported", nil)
		return
	}

	ctx := r.Context()
	lines := make(chan dockerx.LogLine, 64)
	go func() {
		defer close(lines)
		for {
			line, err := reader.Next()
			if err != nil {
				return
			}
			select {
			case lines <- line:
			case <-ctx.Done():
				return
			}
		}
	}()

	keepalive := time.NewTicker(s.KeepAlive)
	defer keepalive.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case line, ok := <-lines:
			if !ok {
				_ = stream.Send("end", map[string]any{"container_id": id})
				return
			}
			if q.filter != "" && !containsFold(line.Line, q.filter) {
				continue
			}
			if err := stream.Send("log", map[string]any{
				"ts":     line.Time.Format(time.RFC3339Nano),
				"stream": line.Stream,
				"line":   line.Line,
			}); err != nil {
				return
			}
		case <-keepalive.C:
			if err := stream.Comment("keep-alive"); err != nil {
				return
			}
		}
	}
}
