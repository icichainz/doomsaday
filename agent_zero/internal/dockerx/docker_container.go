package dockerx

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"sync"
	"time"

	dtypes "github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/filters"
)

func base64URL(raw []byte) string { return base64.URLEncoding.EncodeToString(raw) }

func dockerDiskUsageOptions() dtypes.DiskUsageOptions { return dtypes.DiskUsageOptions{} }

const composeProjectLabel = "com.docker.compose.project"
const composeServiceLabel = "com.docker.compose.service"

// inspectWorkers bounds how many inspect calls run at once while building a
// container list.
const inspectWorkers = 8

// ContainerList lists containers, enriching each row with the detail the
// list screen needs (restart count, health, uptime).
func (d *Docker) ContainerList(ctx context.Context, opts ContainerListOptions) ([]Container, error) {
	f := filters.NewArgs()
	if opts.State != "" {
		f.Add("status", opts.State)
	}
	if opts.Stack != "" {
		f.Add("label", composeProjectLabel+"="+opts.Stack)
	}
	summaries, err := d.cli.ContainerList(ctx, container.ListOptions{All: true, Filters: f})
	if err != nil {
		return nil, wrap(err)
	}

	out := make([]Container, len(summaries))
	sem := make(chan struct{}, inspectWorkers)
	var wg sync.WaitGroup
	for i, s := range summaries {
		c := Container{
			ID:        s.ID,
			Name:      strings.TrimPrefix(firstName(s.Names), "/"),
			Image:     s.Image,
			ImageID:   s.ImageID,
			State:     string(s.State),
			Status:    s.Status,
			CreatedAt: time.Unix(s.Created, 0).UTC(),
			Labels:    s.Labels,
			Health:    healthFromStatus(s.Status),
		}
		if s.Labels != nil {
			c.Stack = s.Labels[composeProjectLabel]
			c.Service = s.Labels[composeServiceLabel]
		}
		for _, p := range s.Ports {
			c.Ports = append(c.Ports, Port{IP: p.IP, PrivatePort: int(p.PrivatePort), PublicPort: int(p.PublicPort), Type: p.Type})
		}
		out[i] = c

		wg.Add(1)
		go func(idx int, id string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			ins, err := d.cli.ContainerInspect(ctx, id)
			if err != nil || ins.ContainerJSONBase == nil {
				return
			}
			out[idx].RestartCount = ins.RestartCount
			if ins.State != nil {
				out[idx].StartedAt = parseDockerTime(ins.State.StartedAt)
				out[idx].FinishedAt = parseDockerTime(ins.State.FinishedAt)
				out[idx].ExitCode = ins.State.ExitCode
				if ins.State.Health != nil {
					out[idx].Health = strings.ToLower(ins.State.Health.Status)
				}
			}
		}(i, s.ID)
	}
	wg.Wait()

	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

func firstName(names []string) string {
	if len(names) == 0 {
		return ""
	}
	return names[0]
}

func healthFromStatus(status string) string {
	switch {
	case strings.Contains(status, "(healthy)"):
		return "healthy"
	case strings.Contains(status, "(unhealthy)"):
		return "unhealthy"
	case strings.Contains(status, "(health: starting)"):
		return "starting"
	}
	return ""
}

func parseDockerTime(s string) time.Time {
	if s == "" || strings.HasPrefix(s, "0001-01-01") {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return time.Time{}
	}
	return t.UTC()
}

// ContainerInspect returns the full container detail.
func (d *Docker) ContainerInspect(ctx context.Context, id string) (ContainerDetail, error) {
	ins, err := d.cli.ContainerInspect(ctx, id)
	if err != nil {
		return ContainerDetail{}, wrap(err)
	}
	if ins.ContainerJSONBase == nil {
		return ContainerDetail{}, ErrNotFound
	}

	det := ContainerDetail{}
	det.ID = ins.ID
	det.Name = strings.TrimPrefix(ins.Name, "/")
	det.ImageID = ins.Image
	det.CreatedAt = parseDockerTime(ins.Created)
	det.RestartCount = ins.RestartCount
	det.Platform = ins.Platform
	if ins.State != nil {
		det.State = string(ins.State.Status)
		det.ExitCode = ins.State.ExitCode
		det.StartedAt = parseDockerTime(ins.State.StartedAt)
		det.FinishedAt = parseDockerTime(ins.State.FinishedAt)
		if ins.State.Health != nil {
			det.Health = strings.ToLower(ins.State.Health.Status)
		}
	}
	if ins.Config != nil {
		det.Image = ins.Config.Image
		det.Labels = ins.Config.Labels
		det.Env = ins.Config.Env
		det.WorkingDir = ins.Config.WorkingDir
		det.User = ins.Config.User
		det.Entrypoint = ins.Config.Entrypoint
		det.Command = strings.Join(ins.Config.Cmd, " ")
		if ins.Config.Labels != nil {
			det.Stack = ins.Config.Labels[composeProjectLabel]
			det.Service = ins.Config.Labels[composeServiceLabel]
		}
	}
	if ins.HostConfig != nil {
		det.RestartPolicy = RestartPolicy{
			Name:              string(ins.HostConfig.RestartPolicy.Name),
			MaximumRetryCount: ins.HostConfig.RestartPolicy.MaximumRetryCount,
		}
		det.LogDriver = ins.HostConfig.LogConfig.Type
		det.NetworkMode = string(ins.HostConfig.NetworkMode)
		for _, l := range ins.HostConfig.Links {
			if name, _, ok := strings.Cut(l, ":"); ok {
				det.DependsOn = append(det.DependsOn, strings.TrimPrefix(name, "/"))
			} else {
				det.DependsOn = append(det.DependsOn, strings.TrimPrefix(l, "/"))
			}
		}
	}
	for _, m := range ins.Mounts {
		det.Mounts = append(det.Mounts, Mount{
			Type:        string(m.Type),
			Name:        m.Name,
			Source:      m.Source,
			Destination: m.Destination,
			Mode:        m.Mode,
			RW:          m.RW,
		})
	}
	det.Mounts = nonNilMounts(det.Mounts)

	if ins.NetworkSettings != nil {
		for name, ep := range ins.NetworkSettings.Networks {
			if ep == nil {
				continue
			}
			det.Networks = append(det.Networks, NetworkAttachment{
				Name:        name,
				NetworkID:   ep.NetworkID,
				IPAddress:   ep.IPAddress,
				Gateway:     ep.Gateway,
				MacAddress:  ep.MacAddress,
				Aliases:     ep.Aliases,
				IPPrefixLen: ep.IPPrefixLen,
			})
		}
		sort.Slice(det.Networks, func(i, j int) bool { return det.Networks[i].Name < det.Networks[j].Name })
		for portSpec, bindings := range ins.NetworkSettings.Ports {
			priv := portSpec.Int()
			proto := portSpec.Proto()
			if len(bindings) == 0 {
				det.Ports = append(det.Ports, Port{PrivatePort: priv, Type: proto})
				continue
			}
			for _, b := range bindings {
				pub := 0
				fmt.Sscanf(b.HostPort, "%d", &pub)
				det.Ports = append(det.Ports, Port{IP: b.HostIP, PrivatePort: priv, PublicPort: pub, Type: proto})
			}
		}
		sort.Slice(det.Ports, func(i, j int) bool { return det.Ports[i].PrivatePort < det.Ports[j].PrivatePort })
	}
	if det.Networks == nil {
		det.Networks = []NetworkAttachment{}
	}
	if det.Ports == nil {
		det.Ports = []Port{}
	}
	return det, nil
}

func nonNilMounts(m []Mount) []Mount {
	if m == nil {
		return []Mount{}
	}
	return m
}

// ContainerStats takes a single CPU-accurate sample by reading two frames
// from the stats stream.
func (d *Docker) ContainerStats(ctx context.Context, id string) (Stats, error) {
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()

	resp, err := d.cli.ContainerStats(ctx, id, true)
	if err != nil {
		return Stats{}, wrap(err)
	}
	defer resp.Body.Close()

	dec := json.NewDecoder(resp.Body)
	var last Stats
	for i := 0; i < 2; i++ {
		var raw container.StatsResponse
		if err := dec.Decode(&raw); err != nil {
			if i == 0 {
				return Stats{}, wrap(err)
			}
			break
		}
		last = convertStats(raw)
	}
	return last, nil
}

// ContainerStatsStream pushes a sample onto out until ctx is done.
func (d *Docker) ContainerStatsStream(ctx context.Context, id string, out chan<- Stats) error {
	resp, err := d.cli.ContainerStats(ctx, id, true)
	if err != nil {
		return wrap(err)
	}
	defer resp.Body.Close()

	dec := json.NewDecoder(resp.Body)
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		var raw container.StatsResponse
		if err := dec.Decode(&raw); err != nil {
			if errors.Is(err, io.EOF) || ctx.Err() != nil {
				return nil
			}
			return wrap(err)
		}
		select {
		case out <- convertStats(raw):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func convertStats(raw container.StatsResponse) Stats {
	s := Stats{Time: raw.Read.UTC()}
	if s.Time.IsZero() {
		s.Time = time.Now().UTC()
	}

	cpuDelta := float64(raw.CPUStats.CPUUsage.TotalUsage) - float64(raw.PreCPUStats.CPUUsage.TotalUsage)
	sysDelta := float64(raw.CPUStats.SystemUsage) - float64(raw.PreCPUStats.SystemUsage)
	cores := float64(raw.CPUStats.OnlineCPUs)
	if cores == 0 {
		cores = float64(len(raw.CPUStats.CPUUsage.PercpuUsage))
	}
	if cores == 0 {
		cores = 1
	}
	if cpuDelta > 0 && sysDelta > 0 {
		s.CPUPercent = cpuDelta / sysDelta * cores * 100
	} else if sysDelta == 0 && raw.NumProcs > 0 && cpuDelta > 0 {
		// Windows containers report no system usage.
		s.CPUPercent = 0
	}

	usage := raw.MemoryStats.Usage
	if cache, ok := raw.MemoryStats.Stats["inactive_file"]; ok && cache < usage {
		usage -= cache
	} else if cache, ok := raw.MemoryStats.Stats["cache"]; ok && cache < usage {
		usage -= cache
	}
	s.MemUsage = int64(usage)
	s.MemLimit = int64(raw.MemoryStats.Limit)
	if s.MemLimit > 0 {
		s.MemPercent = float64(s.MemUsage) / float64(s.MemLimit) * 100
	}

	for _, n := range raw.Networks {
		s.NetRxBytes += int64(n.RxBytes)
		s.NetTxBytes += int64(n.TxBytes)
	}
	for _, b := range raw.BlkioStats.IoServiceBytesRecursive {
		switch strings.ToLower(b.Op) {
		case "read":
			s.BlkRead += int64(b.Value)
		case "write":
			s.BlkWrite += int64(b.Value)
		}
	}
	s.PIDs = int64(raw.PidsStats.Current)
	return s
}

// ContainerStart starts a container.
func (d *Docker) ContainerStart(ctx context.Context, id string) error {
	return wrap(d.cli.ContainerStart(ctx, id, container.StartOptions{}))
}

// ContainerStop sends SIGTERM then SIGKILL after timeoutSeconds.
func (d *Docker) ContainerStop(ctx context.Context, id string, timeoutSeconds int) error {
	return wrap(d.cli.ContainerStop(ctx, id, container.StopOptions{Timeout: &timeoutSeconds}))
}

// ContainerRestart restarts a container.
func (d *Docker) ContainerRestart(ctx context.Context, id string, timeoutSeconds int) error {
	return wrap(d.cli.ContainerRestart(ctx, id, container.StopOptions{Timeout: &timeoutSeconds}))
}

// ContainerPause pauses a container.
func (d *Docker) ContainerPause(ctx context.Context, id string) error {
	return wrap(d.cli.ContainerPause(ctx, id))
}

// ContainerUnpause resumes a container.
func (d *Docker) ContainerUnpause(ctx context.Context, id string) error {
	return wrap(d.cli.ContainerUnpause(ctx, id))
}

// ContainerRemove deletes a container.
func (d *Docker) ContainerRemove(ctx context.Context, id string, force, volumes bool) error {
	return wrap(d.cli.ContainerRemove(ctx, id, container.RemoveOptions{Force: force, RemoveVolumes: volumes}))
}

// ContainerLogs opens a log reader.
func (d *Docker) ContainerLogs(ctx context.Context, id string, opts LogOptions) (LogReader, error) {
	ins, err := d.cli.ContainerInspect(ctx, id)
	if err != nil {
		return nil, wrap(err)
	}
	tty := ins.Config != nil && ins.Config.Tty

	lo := container.LogsOptions{
		ShowStdout: opts.Stdout,
		ShowStderr: opts.Stderr,
		Follow:     opts.Follow,
		Timestamps: true,
		Tail:       opts.Tail,
	}
	if !lo.ShowStdout && !lo.ShowStderr {
		lo.ShowStdout, lo.ShowStderr = true, true
	}
	if !opts.Since.IsZero() {
		lo.Since = opts.Since.UTC().Format(time.RFC3339Nano)
	}
	if !opts.Until.IsZero() {
		lo.Until = opts.Until.UTC().Format(time.RFC3339Nano)
	}

	rc, err := d.cli.ContainerLogs(ctx, id, lo)
	if err != nil {
		return nil, wrap(err)
	}
	return &logReader{rc: rc, br: bufio.NewReaderSize(rc, 64*1024), tty: tty}, nil
}

// maxLogFrame caps one multiplexed log frame so a hostile log line cannot
// exhaust memory.
const maxLogFrame = 1 << 20

type logReader struct {
	rc    io.ReadCloser
	br    *bufio.Reader
	tty   bool
	queue []LogLine
}

func (r *logReader) Close() error { return r.rc.Close() }

func (r *logReader) Next() (LogLine, error) {
	for {
		if len(r.queue) > 0 {
			l := r.queue[0]
			r.queue = r.queue[1:]
			return l, nil
		}
		if r.tty {
			line, err := r.br.ReadString('\n')
			if line == "" && err != nil {
				return LogLine{}, err
			}
			r.queue = append(r.queue, parseLogLine("stdout", line))
			continue
		}
		var hdr [8]byte
		if _, err := io.ReadFull(r.br, hdr[:]); err != nil {
			if errors.Is(err, io.ErrUnexpectedEOF) {
				return LogLine{}, io.EOF
			}
			return LogLine{}, err
		}
		stream := "stdout"
		if hdr[0] == 2 {
			stream = "stderr"
		}
		n := binary.BigEndian.Uint32(hdr[4:8])
		if n > maxLogFrame {
			n = maxLogFrame
		}
		buf := make([]byte, n)
		if _, err := io.ReadFull(r.br, buf); err != nil {
			return LogLine{}, err
		}
		for _, l := range strings.Split(strings.TrimRight(string(buf), "\n"), "\n") {
			r.queue = append(r.queue, parseLogLine(stream, l))
		}
	}
}

func parseLogLine(stream, raw string) LogLine {
	raw = strings.TrimRight(raw, "\r\n")
	l := LogLine{Stream: stream, Line: raw}
	if ts, rest, ok := strings.Cut(raw, " "); ok {
		if t, err := time.Parse(time.RFC3339Nano, ts); err == nil {
			l.Time = t.UTC()
			l.Line = rest
		}
	}
	if l.Time.IsZero() {
		l.Time = time.Now().UTC()
	}
	return l
}

// ContainerExec starts an interactive exec session.
func (d *Docker) ContainerExec(ctx context.Context, id string, opts ExecOptions) (ExecSession, error) {
	cmd := opts.Cmd
	if len(cmd) == 0 {
		cmd = []string{"/bin/sh"}
	}
	created, err := d.cli.ContainerExecCreate(ctx, id, container.ExecOptions{
		AttachStdin:  true,
		AttachStdout: true,
		AttachStderr: true,
		Tty:          opts.TTY,
		Cmd:          cmd,
		User:         opts.User,
	})
	if err != nil {
		return nil, wrap(err)
	}
	att, err := d.cli.ContainerExecAttach(ctx, created.ID, container.ExecAttachOptions{Tty: opts.TTY})
	if err != nil {
		return nil, wrap(err)
	}
	s := &execSession{d: d, id: created.ID, att: att, tty: opts.TTY}
	if opts.Width > 0 && opts.Height > 0 {
		_ = s.Resize(opts.Width, opts.Height)
	}
	return s, nil
}

type execSession struct {
	d   *Docker
	id  string
	att dtypes.HijackedResponse
	tty bool

	closeOnce sync.Once
}

func (s *execSession) Read(p []byte) (int, error) {
	if s.tty {
		return s.att.Reader.Read(p)
	}
	// Demultiplex stdout and stderr into one stream for the terminal.
	var hdr [8]byte
	if _, err := io.ReadFull(s.att.Reader, hdr[:]); err != nil {
		return 0, err
	}
	n := int(binary.BigEndian.Uint32(hdr[4:8]))
	if n > len(p) {
		n = len(p)
	}
	return io.ReadFull(s.att.Reader, p[:n])
}

func (s *execSession) Write(p []byte) (int, error) { return s.att.Conn.Write(p) }

func (s *execSession) Close() error {
	s.closeOnce.Do(func() { s.att.Close() })
	return nil
}

func (s *execSession) Resize(w, h uint) error {
	return wrap(s.d.cli.ContainerExecResize(context.Background(), s.id, container.ResizeOptions{Width: w, Height: h}))
}

func (s *execSession) ExitCode() (int, bool, error) {
	ins, err := s.d.cli.ContainerExecInspect(context.Background(), s.id)
	if err != nil {
		return 0, false, wrap(err)
	}
	return ins.ExitCode, ins.Running, nil
}
