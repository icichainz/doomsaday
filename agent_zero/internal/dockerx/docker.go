package dockerx

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	cerrdefs "github.com/containerd/errdefs"
	"github.com/docker/docker/api/types/events"
	"github.com/docker/docker/api/types/registry"
	"github.com/docker/docker/client"
)

// Docker is the real dockerx.Client, backed by the official SDK.
type Docker struct {
	cli *client.Client

	mu            sync.Mutex
	lastCPU       cpuSample
	lastAggregate aggregateSample
}

type cpuSample struct {
	total, idle uint64
	at          time.Time
}

var _ Client = (*Docker)(nil)

// New connects to the Docker daemon. host may be empty, in which case the
// usual environment defaults apply.
func New(host string) (*Docker, error) {
	opts := []client.Opt{client.WithAPIVersionNegotiation()}
	if host != "" {
		opts = append(opts, client.WithHost(host))
	} else {
		opts = append(opts, client.FromEnv)
	}
	cli, err := client.NewClientWithOpts(opts...)
	if err != nil {
		return nil, fmt.Errorf("dockerx: %w", err)
	}
	return &Docker{cli: cli}, nil
}

// Close releases the underlying HTTP client.
func (d *Docker) Close() error { return d.cli.Close() }

// Ping checks that the daemon answers.
func (d *Docker) Ping(ctx context.Context) error {
	if _, err := d.cli.Ping(ctx); err != nil {
		return wrap(err)
	}
	return nil
}

// wrap maps SDK errors onto the package's sentinel errors so the API layer
// can pick a status code without knowing about Docker.
func wrap(err error) error {
	if err == nil {
		return nil
	}
	switch {
	case client.IsErrConnectionFailed(err), cerrdefs.IsUnavailable(err):
		return fmt.Errorf("%w: %s", ErrUnavailable, err)
	case client.IsErrNotFound(err), cerrdefs.IsNotFound(err):
		return fmt.Errorf("%w: %s", ErrNotFound, err)
	case cerrdefs.IsConflict(err), cerrdefs.IsFailedPrecondition(err), cerrdefs.IsAlreadyExists(err):
		return fmt.Errorf("%w: %s", ErrConflict, err)
	case cerrdefs.IsNotImplemented(err):
		return fmt.Errorf("%w: %s", ErrUnsupported, err)
	}
	msg := err.Error()
	if strings.Contains(msg, "This node is not a swarm manager") ||
		strings.Contains(msg, "not a swarm manager") {
		return fmt.Errorf("%w: %s", ErrNotManager, err)
	}
	if strings.Contains(msg, "Cannot connect to the Docker daemon") ||
		strings.Contains(msg, "connection refused") ||
		strings.Contains(msg, "no such file or directory") && strings.Contains(msg, "docker.sock") {
		return fmt.Errorf("%w: %s", ErrUnavailable, err)
	}
	return err
}

// Info returns host and daemon facts.
func (d *Docker) Info(ctx context.Context) (SystemInfo, error) {
	info, err := d.cli.Info(ctx)
	if err != nil {
		return SystemInfo{}, wrap(err)
	}
	ver, verErr := d.cli.ServerVersion(ctx)

	role := "inactive"
	switch {
	case info.Swarm.LocalNodeState == "active" && info.Swarm.ControlAvailable:
		role = "manager"
	case info.Swarm.LocalNodeState == "active":
		role = "worker"
	}

	out := SystemInfo{
		Hostname:          info.Name,
		DockerVersion:     info.ServerVersion,
		OS:                info.OperatingSystem,
		OSType:            info.OSType,
		Arch:              info.Architecture,
		KernelVersion:     info.KernelVersion,
		CPUCores:          info.NCPU,
		MemTotal:          info.MemTotal,
		SwarmRole:         role,
		SwarmNodeID:       info.Swarm.NodeID,
		Containers:        info.Containers,
		ContainersRunning: info.ContainersRunning,
		ContainersPaused:  info.ContainersPaused,
		ContainersStopped: info.ContainersStopped,
		Images:            info.Images,
		DockerRoot:        info.DockerRootDir,
	}
	if verErr == nil {
		out.APIVersion = ver.APIVersion
	}
	return out, nil
}

// DiskUsage reports what Docker is holding on disk.
func (d *Docker) DiskUsage(ctx context.Context) (DiskUsage, error) {
	du, err := d.cli.DiskUsage(ctx, dockerDiskUsageOptions())
	if err != nil {
		return DiskUsage{}, wrap(err)
	}
	out := DiskUsage{}
	inUse := map[string]bool{}
	for _, c := range du.Containers {
		if c == nil {
			continue
		}
		out.ContainersSize += c.SizeRw
		inUse[c.ImageID] = true
	}
	for _, img := range du.Images {
		if img == nil {
			continue
		}
		out.ImagesSize += img.Size
		if img.Containers == 0 && !inUse[img.ID] {
			out.ImagesReclaim += img.Size - img.SharedSize
		}
	}
	for _, v := range du.Volumes {
		if v == nil || v.UsageData == nil {
			continue
		}
		if v.UsageData.Size > 0 {
			out.VolumesSize += v.UsageData.Size
			if v.UsageData.RefCount == 0 {
				out.VolumesReclaim += v.UsageData.Size
			}
		}
	}
	for _, b := range du.BuildCache {
		if b == nil {
			continue
		}
		out.BuildCacheSize += b.Size
		if !b.InUse {
			out.BuildCacheClean += b.Size
		}
	}
	return out, nil
}

// HostMetrics reads live host CPU, memory and disk. On Linux the figures come
// from /proc; elsewhere (and inside a VM-backed daemon) CPU and memory fall
// back to the sum of running containers, which is flagged in the result.
func (d *Docker) HostMetrics(ctx context.Context) (HostMetrics, error) {
	info, err := d.Info(ctx)
	if err != nil {
		return HostMetrics{}, err
	}
	out := HostMetrics{
		MemTotal:  info.MemTotal,
		CPUSource: "containers",
		MemSource: "containers",
	}

	if runtime.GOOS == "linux" {
		if cpu, ok := d.readProcCPU(); ok {
			out.CPUPercent = cpu
			out.CPUSource = "host"
		}
		if total, used, ok := readProcMem(); ok {
			out.MemTotal, out.MemUsed = total, used
			out.MemSource = "host"
		}
		if up, ok := readProcUptime(); ok {
			out.HostUptimeSeconds = up
		}
	}

	if out.CPUSource == "containers" || out.MemSource == "containers" {
		cpuPct, mem := d.aggregateContainerUse(ctx)
		if out.CPUSource == "containers" {
			if info.CPUCores > 0 {
				cpuPct /= float64(info.CPUCores)
			}
			if cpuPct > 100 {
				cpuPct = 100
			}
			out.CPUPercent = cpuPct
		}
		if out.MemSource == "containers" {
			out.MemUsed = mem
		}
	}

	total, used, err := diskUsageOf(info.DockerRoot)
	if err != nil {
		// A VM-backed daemon exposes a root directory that does not exist on
		// this machine; report the agent's own filesystem instead.
		total, used, err = diskUsageOf("/")
	}
	if err == nil {
		out.DiskTotal, out.DiskUsed = total, used
	}
	return out, nil
}

// aggregateTTL is how long a fallback host measurement is reused. Sampling
// every container costs two stats frames each, about two seconds, so without
// this the system stats stream would spend all its time measuring.
const aggregateTTL = 5 * time.Second

// aggregateWorkers bounds the concurrent stats streams opened while measuring.
const aggregateWorkers = 8

type aggregateSample struct {
	cpu float64
	mem int64
	at  time.Time
}

// aggregateContainerUse sums the running containers' CPU and memory. It is
// the fallback for hosts where /proc is not the Docker host's /proc.
func (d *Docker) aggregateContainerUse(ctx context.Context) (float64, int64) {
	d.mu.Lock()
	cached := d.lastAggregate
	d.mu.Unlock()
	if !cached.at.IsZero() && time.Since(cached.at) < aggregateTTL {
		return cached.cpu, cached.mem
	}

	cs, err := d.ContainerList(ctx, ContainerListOptions{State: "running"})
	if err != nil {
		return cached.cpu, cached.mem
	}

	var mu sync.Mutex
	var cpu float64
	var mem int64
	sem := make(chan struct{}, aggregateWorkers)
	var wg sync.WaitGroup
	for _, c := range cs {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			st, err := d.ContainerStats(ctx, id)
			if err != nil {
				return
			}
			mu.Lock()
			cpu += st.CPUPercent
			mem += st.MemUsage
			mu.Unlock()
		}(c.ID)
	}
	wg.Wait()

	d.mu.Lock()
	d.lastAggregate = aggregateSample{cpu: cpu, mem: mem, at: time.Now()}
	d.mu.Unlock()
	return cpu, mem
}

func (d *Docker) readProcCPU() (float64, bool) {
	raw, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, false
	}
	line := ""
	for _, l := range strings.Split(string(raw), "\n") {
		if strings.HasPrefix(l, "cpu ") {
			line = l
			break
		}
	}
	if line == "" {
		return 0, false
	}
	fields := strings.Fields(line)[1:]
	var total, idle uint64
	for i, f := range fields {
		n, err := strconv.ParseUint(f, 10, 64)
		if err != nil {
			continue
		}
		total += n
		if i == 3 || i == 4 { // idle + iowait
			idle += n
		}
	}
	now := time.Now()
	d.mu.Lock()
	prev := d.lastCPU
	d.lastCPU = cpuSample{total: total, idle: idle, at: now}
	d.mu.Unlock()

	if prev.at.IsZero() || total <= prev.total {
		return 0, false
	}
	dt := float64(total - prev.total)
	di := float64(idle - prev.idle)
	pct := (dt - di) / dt * 100
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	return pct, true
}

func readProcMem() (total, used int64, ok bool) {
	raw, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, 0, false
	}
	vals := map[string]int64{}
	for _, l := range strings.Split(string(raw), "\n") {
		parts := strings.Fields(l)
		if len(parts) < 2 {
			continue
		}
		n, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil {
			continue
		}
		vals[strings.TrimSuffix(parts[0], ":")] = n * 1024
	}
	total = vals["MemTotal"]
	avail, hasAvail := vals["MemAvailable"]
	if total == 0 {
		return 0, 0, false
	}
	if !hasAvail {
		avail = vals["MemFree"] + vals["Buffers"] + vals["Cached"]
	}
	return total, total - avail, true
}

func readProcUptime() (int64, bool) {
	raw, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0, false
	}
	fields := strings.Fields(string(raw))
	if len(fields) == 0 {
		return 0, false
	}
	f, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, false
	}
	return int64(f), true
}

// Events streams Docker events.
func (d *Docker) Events(ctx context.Context) (<-chan Event, <-chan error) {
	out := make(chan Event, 64)
	errs := make(chan error, 1)
	msgs, derrs := d.cli.Events(ctx, events.ListOptions{})
	go func() {
		defer close(out)
		for {
			select {
			case <-ctx.Done():
				return
			case err := <-derrs:
				if err != nil && !errors.Is(err, context.Canceled) {
					select {
					case errs <- wrap(err):
					default:
					}
				}
				return
			case m, ok := <-msgs:
				if !ok {
					return
				}
				ev := Event{
					Time:       time.Unix(0, m.TimeNano).UTC(),
					Type:       string(m.Type),
					Action:     string(m.Action),
					ActorID:    m.Actor.ID,
					Scope:      m.Scope,
					Attributes: m.Actor.Attributes,
				}
				if m.Actor.Attributes != nil {
					ev.ActorName = m.Actor.Attributes["name"]
				}
				select {
				case out <- ev:
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	return out, errs
}

// RegistryLogin verifies a registry credential.
func (d *Docker) RegistryLogin(ctx context.Context, a RegistryAuth) error {
	_, err := d.cli.RegistryLogin(ctx, registry.AuthConfig{
		Username:      a.Username,
		Password:      a.Secret,
		ServerAddress: a.Host,
	})
	return wrap(err)
}

func encodeAuth(a *RegistryAuth) string {
	if a == nil {
		return ""
	}
	raw, err := json.Marshal(registry.AuthConfig{
		Username:      a.Username,
		Password:      a.Secret,
		ServerAddress: a.Host,
	})
	if err != nil {
		return ""
	}
	return base64URL(raw)
}
