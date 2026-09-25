package httpapi

import (
	"net/http"
	"time"

	"agent_zero/internal/audit"
	"agent_zero/internal/dockerx"
	"agent_zero/internal/sse"
)

type systemResponse struct {
	Hostname          string `json:"hostname"`
	DockerVersion     string `json:"docker_version"`
	DockerAPIVersion  string `json:"docker_api_version,omitempty"`
	AgentVersion      string `json:"agent_version"`
	OS                string `json:"os"`
	Arch              string `json:"arch"`
	KernelVersion     string `json:"kernel_version,omitempty"`
	CPUCores          int    `json:"cpu_cores"`
	MemoryTotal       int64  `json:"memory_total"`
	DiskTotal         int64  `json:"disk_total"`
	DiskUsed          int64  `json:"disk_used"`
	SwarmRole         string `json:"swarm_role"`
	SwarmNodeID       string `json:"swarm_node_id,omitempty"`
	AgentUptimeSecs   int64  `json:"agent_uptime_seconds"`
	HostUptimeSecs    int64  `json:"host_uptime_seconds"`
	CertFingerprint   string `json:"cert_fingerprint,omitempty"`
	ContainersTotal   int    `json:"containers_total"`
	ContainersRunning int    `json:"containers_running"`
	ImagesTotal       int    `json:"images_total"`
	Time              string `json:"time"`
}

func (s *Server) handleSystem(w http.ResponseWriter, r *http.Request) {
	info, err := s.Docker.Info(r.Context())
	if err != nil {
		s.fail(w, "system", err)
		return
	}
	metrics, err := s.Docker.HostMetrics(r.Context())
	if err != nil {
		s.fail(w, "system", err)
		return
	}
	writeJSON(w, http.StatusOK, systemResponse{
		Hostname:          info.Hostname,
		DockerVersion:     info.DockerVersion,
		DockerAPIVersion:  info.APIVersion,
		AgentVersion:      s.Version,
		OS:                info.OS,
		Arch:              info.Arch,
		KernelVersion:     info.KernelVersion,
		CPUCores:          info.CPUCores,
		MemoryTotal:       metrics.MemTotal,
		DiskTotal:         metrics.DiskTotal,
		DiskUsed:          metrics.DiskUsed,
		SwarmRole:         info.SwarmRole,
		SwarmNodeID:       info.SwarmNodeID,
		AgentUptimeSecs:   int64(time.Since(s.StartedAt).Seconds()),
		HostUptimeSecs:    metrics.HostUptimeSeconds,
		CertFingerprint:   s.CertFingerprint,
		ContainersTotal:   info.Containers,
		ContainersRunning: info.ContainersRunning,
		ImagesTotal:       info.Images,
		Time:              time.Now().UTC().Format(time.RFC3339),
	})
}

type containerCounts struct {
	Running    int `json:"running"`
	Exited     int `json:"exited"`
	Paused     int `json:"paused"`
	Restarting int `json:"restarting"`
	Created    int `json:"created"`
	Total      int `json:"total"`
}

type systemStats struct {
	Time            string          `json:"ts"`
	CPUPercent      float64         `json:"cpu_percent"`
	CPUSource       string          `json:"cpu_source"`
	MemoryUsed      int64           `json:"memory_used"`
	MemoryTotal     int64           `json:"memory_total"`
	MemoryPercent   float64         `json:"memory_percent"`
	MemorySource    string          `json:"memory_source"`
	DiskUsed        int64           `json:"disk_used"`
	DiskTotal       int64           `json:"disk_total"`
	DiskPercent     float64         `json:"disk_percent"`
	Containers      containerCounts `json:"containers"`
	ActiveAlerts    int             `json:"active_alerts"`
	DockerReachable bool            `json:"docker_reachable"`
}

func percent(used, total int64) float64 {
	if total <= 0 {
		return 0
	}
	return float64(used) / float64(total) * 100
}

func (s *Server) collectStats(r *http.Request) (systemStats, error) {
	metrics, err := s.Docker.HostMetrics(r.Context())
	if err != nil {
		return systemStats{}, err
	}
	containers, err := s.Docker.ContainerList(r.Context(), dockerx.ContainerListOptions{})
	if err != nil {
		return systemStats{}, err
	}
	counts := containerCounts{Total: len(containers)}
	for _, c := range containers {
		switch c.State {
		case "running":
			counts.Running++
		case "exited", "dead":
			counts.Exited++
		case "paused":
			counts.Paused++
		case "restarting":
			counts.Restarting++
		case "created":
			counts.Created++
		}
	}
	active := 0
	if list, err := s.Alerts.List("active"); err == nil {
		active = len(list)
	}
	return systemStats{
		Time:            time.Now().UTC().Format(time.RFC3339),
		CPUPercent:      round2(metrics.CPUPercent),
		CPUSource:       metrics.CPUSource,
		MemoryUsed:      metrics.MemUsed,
		MemoryTotal:     metrics.MemTotal,
		MemoryPercent:   round2(percent(metrics.MemUsed, metrics.MemTotal)),
		MemorySource:    metrics.MemSource,
		DiskUsed:        metrics.DiskUsed,
		DiskTotal:       metrics.DiskTotal,
		DiskPercent:     round2(percent(metrics.DiskUsed, metrics.DiskTotal)),
		Containers:      counts,
		ActiveAlerts:    active,
		DockerReachable: true,
	}, nil
}

func round2(f float64) float64 { return float64(int64(f*100+0.5)) / 100 }

func (s *Server) handleSystemStats(w http.ResponseWriter, r *http.Request) {
	st, err := s.collectStats(r)
	if err != nil {
		s.fail(w, "system", err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (s *Server) handleSystemStatsStream(w http.ResponseWriter, r *http.Request) {
	stream, err := sse.NewWriter(w, r)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "streaming is not supported", nil)
		return
	}
	ticker := time.NewTicker(s.StatsInterval)
	defer ticker.Stop()

	for {
		st, err := s.collectStats(r)
		if err == nil {
			if sendErr := stream.Send("stats", st); sendErr != nil {
				return
			}
		} else if sendErr := stream.Send("error", errorDetail{
			Code: codeDockerUnavailable, Message: err.Error(), Details: map[string]any{},
		}); sendErr != nil {
			return
		}
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
		}
	}
}

func (s *Server) handleActivity(w http.ResponseWriter, r *http.Request) {
	page, err := readPage(r)
	if err != nil {
		validationError(w, "limit", err.Error())
		return
	}
	since, err := queryTime(r, "since")
	if err != nil {
		validationError(w, "since", err.Error())
		return
	}
	actor := r.URL.Query().Get("actor")
	if len(actor) > maxQueryLen {
		validationError(w, "actor", "actor is too long")
		return
	}

	cursor := r.URL.Query().Get("cursor")
	records, next, err := s.Audit.List(audit.Filter{
		Actor:  actor,
		Since:  since,
		Limit:  page.Limit,
		Cursor: cursor,
	})
	if err != nil {
		validationError(w, "cursor", "cursor is not valid")
		return
	}
	if records == nil {
		records = []audit.Record{}
	}
	writeJSON(w, http.StatusOK, listResponse{Items: records, NextCursor: next, Total: len(records)})
}

func (s *Server) handleEventsStream(w http.ResponseWriter, r *http.Request) {
	stream, err := sse.NewWriter(w, r)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "streaming is not supported", nil)
		return
	}
	ctx := r.Context()
	events, errs := s.Docker.Events(ctx)
	keepalive := time.NewTicker(s.KeepAlive)
	defer keepalive.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case err := <-errs:
			if err != nil {
				_ = stream.Send("error", errorDetail{
					Code: codeDockerUnavailable, Message: err.Error(), Details: map[string]any{},
				})
			}
			return
		case ev, ok := <-events:
			if !ok {
				return
			}
			if sendErr := stream.Send("docker_event", ev); sendErr != nil {
				return
			}
		case <-keepalive.C:
			if err := stream.Comment("keep-alive"); err != nil {
				return
			}
		}
	}
}
