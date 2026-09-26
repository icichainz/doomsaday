// Package fakedocker is an in-memory dockerx.Client used by the tests. It
// records every call so a test can assert that a handler reached Docker, and
// each method can be overridden to return an error.
package fakedocker

import (
	"context"
	"fmt"
	"io"
	"sync"
	"time"

	"agent_zero/internal/dockerx"
)

// Call is one recorded call.
type Call struct {
	Method string
	Args   []any
}

// Fake implements dockerx.Client against in-memory state.
type Fake struct {
	mu sync.Mutex

	System      dockerx.SystemInfo
	Metrics     dockerx.HostMetrics
	Disk        dockerx.DiskUsage
	Containers  []dockerx.Container
	Details     map[string]dockerx.ContainerDetail
	StatsByID   map[string]dockerx.Stats
	Images      []dockerx.Image
	Volumes     []dockerx.Volume
	Networks    []dockerx.Network
	Swarm       dockerx.SwarmInfo
	Services    []dockerx.Service
	Tasks       map[string][]dockerx.Task
	LogLines    []dockerx.LogLine
	EventsQueue []dockerx.Event

	// Errs maps a method name onto the error it should return.
	Errs map[string]error

	// PullProgress is replayed by ImagePull.
	PullProgress []dockerx.PullProgress

	// Hold makes the named long-running methods (ImagePull, ImagePrune,
	// VolumePrune, NetworkPrune, ServiceUpdate, ServiceRollback) block after
	// they are entered until the channel is closed or their context ends, the
	// way a real pull or prune does. A held call whose context ends returns
	// the context's error. Set it before the call starts.
	Hold map[string]chan struct{}
	// Entered, when set, receives a method's name as it starts to hold.
	Entered chan string

	calls    []Call
	lastExec *ExecSession
}

var _ dockerx.Client = (*Fake)(nil)

// New returns a Fake with a small, plausible host.
func New() *Fake {
	now := time.Now().UTC()
	f := &Fake{
		System: dockerx.SystemInfo{
			Hostname: "test-host", DockerVersion: "29.0.1", APIVersion: "1.52",
			OS: "Test Linux", OSType: "linux", Arch: "arm64", KernelVersion: "6.1.0",
			CPUCores: 4, MemTotal: 8 << 30, SwarmRole: "inactive",
			Containers: 2, ContainersRunning: 1, ContainersStopped: 1, Images: 2,
			DockerRoot: "/var/lib/docker",
		},
		Metrics: dockerx.HostMetrics{
			CPUPercent: 12.5, MemTotal: 8 << 30, MemUsed: 2 << 30,
			DiskTotal: 100 << 30, DiskUsed: 40 << 30, HostUptimeSeconds: 3600,
			CPUSource: "host", MemSource: "host",
		},
		Disk:      dockerx.DiskUsage{ImagesSize: 500 << 20, ImagesReclaim: 100 << 20},
		Details:   map[string]dockerx.ContainerDetail{},
		StatsByID: map[string]dockerx.Stats{},
		Tasks:     map[string][]dockerx.Task{},
		Errs:      map[string]error{},
		Swarm:     dockerx.SwarmInfo{Active: false, NodeRole: "inactive", Nodes: []dockerx.SwarmNode{}},
	}

	web := dockerx.Container{
		ID:   "c1web0000000000000000000000000000000000000000000000000000000000",
		Name: "agentzero-test-web", Image: "nginx:alpine", ImageID: "sha256:img1",
		State: "running", Status: "Up 2 hours (healthy)", Health: "healthy",
		CreatedAt: now.Add(-3 * time.Hour), StartedAt: now.Add(-2 * time.Hour),
		RestartCount: 0, Stack: "demo", Service: "web",
		Ports:  []dockerx.Port{{IP: "0.0.0.0", PrivatePort: 80, PublicPort: 8080, Type: "tcp"}},
		Labels: map[string]string{"com.docker.compose.project": "demo", "com.docker.compose.service": "web"},
	}
	db := dockerx.Container{
		ID:   "c2db00000000000000000000000000000000000000000000000000000000000",
		Name: "agentzero-test-db", Image: "postgres:16", ImageID: "sha256:img2",
		State: "exited", Status: "Exited (1) 5 minutes ago",
		CreatedAt: now.Add(-4 * time.Hour), StartedAt: now.Add(-4 * time.Hour),
		FinishedAt: now.Add(-5 * time.Minute), ExitCode: 1, RestartCount: 4,
		Stack: "demo", Service: "db",
		Ports:  []dockerx.Port{},
		Labels: map[string]string{"com.docker.compose.project": "demo", "com.docker.compose.service": "db"},
	}
	f.Containers = []dockerx.Container{web, db}

	f.Details[web.ID] = dockerx.ContainerDetail{
		Container:     web,
		Command:       "nginx -g daemon off;",
		Networks:      []dockerx.NetworkAttachment{{Name: "demo_default", NetworkID: "n1", IPAddress: "172.20.0.2"}},
		Mounts:        []dockerx.Mount{{Type: "volume", Name: "agentzero-test-data", Destination: "/data", RW: true}},
		RestartPolicy: dockerx.RestartPolicy{Name: "unless-stopped"},
		Env:           []string{"PATH=/usr/bin", "DB_PASSWORD=super-secret", "NGINX_HOST=example.test"},
	}
	f.Details[db.ID] = dockerx.ContainerDetail{
		Container:     db,
		Networks:      []dockerx.NetworkAttachment{{Name: "demo_default", NetworkID: "n1"}},
		Mounts:        []dockerx.Mount{},
		RestartPolicy: dockerx.RestartPolicy{Name: "always"},
		Env:           []string{"POSTGRES_PASSWORD=also-secret"},
	}

	f.StatsByID[web.ID] = dockerx.Stats{
		Time: now, CPUPercent: 4.5, MemUsage: 100 << 20, MemLimit: 1 << 30, MemPercent: 9.8,
		NetRxBytes: 1000, NetTxBytes: 2000, PIDs: 12,
	}

	f.Images = []dockerx.Image{
		{ID: "sha256:img1", Tags: []string{"nginx:alpine"}, Size: 50 << 20, CreatedAt: now.Add(-48 * time.Hour)},
		{ID: "sha256:img3", Tags: []string{}, Size: 20 << 20, CreatedAt: now.Add(-72 * time.Hour), Dangling: true},
	}
	f.Volumes = []dockerx.Volume{
		{Name: "agentzero-test-data", Driver: "local", Size: 4096, CreatedAt: now.Add(-24 * time.Hour)},
	}
	f.Networks = []dockerx.Network{
		{ID: "n0", Name: "bridge", Driver: "bridge", Scope: "local", IsDefault: true, Subnets: []string{"172.17.0.0/16"}},
		{ID: "n1", Name: "demo_default", Driver: "bridge", Scope: "local", Subnets: []string{"172.20.0.0/16"}, Containers: 2},
	}
	f.LogLines = []dockerx.LogLine{
		{Time: now.Add(-2 * time.Minute), Stream: "stdout", Line: "listening on :80"},
		{Time: now.Add(-1 * time.Minute), Stream: "stderr", Line: "upstream timed out"},
	}
	return f
}

// Calls returns a copy of the recorded calls.
func (f *Fake) Calls() []Call {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Call(nil), f.calls...)
}

// Called reports whether method was called at least once.
func (f *Fake) Called(method string) bool {
	for _, c := range f.Calls() {
		if c.Method == method {
			return true
		}
	}
	return false
}

func (f *Fake) record(method string, args ...any) error {
	f.mu.Lock()
	f.calls = append(f.calls, Call{Method: method, Args: args})
	err := f.Errs[method]
	f.mu.Unlock()
	return err
}

// hold blocks a long-running method as Hold asks.
func (f *Fake) hold(ctx context.Context, method string) error {
	f.mu.Lock()
	release, ok := f.Hold[method]
	entered := f.Entered
	f.mu.Unlock()
	if !ok {
		return nil
	}
	if entered != nil {
		entered <- method
	}
	select {
	case <-release:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Ping answers unless an error is configured.
func (f *Fake) Ping(context.Context) error { return f.record("Ping") }

// Close is a no-op.
func (f *Fake) Close() error { return nil }

// Info returns the configured host info.
func (f *Fake) Info(context.Context) (dockerx.SystemInfo, error) {
	if err := f.record("Info"); err != nil {
		return dockerx.SystemInfo{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.System, nil
}

// HostMetrics returns the configured metrics.
func (f *Fake) HostMetrics(context.Context) (dockerx.HostMetrics, error) {
	if err := f.record("HostMetrics"); err != nil {
		return dockerx.HostMetrics{}, err
	}
	return f.Metrics, nil
}

// DiskUsage returns the configured disk usage.
func (f *Fake) DiskUsage(context.Context) (dockerx.DiskUsage, error) {
	if err := f.record("DiskUsage"); err != nil {
		return dockerx.DiskUsage{}, err
	}
	return f.Disk, nil
}

// Events replays EventsQueue and then blocks until ctx is done.
func (f *Fake) Events(ctx context.Context) (<-chan dockerx.Event, <-chan error) {
	_ = f.record("Events")
	out := make(chan dockerx.Event, len(f.EventsQueue)+1)
	errs := make(chan error, 1)
	for _, e := range f.EventsQueue {
		out <- e
	}
	go func() {
		<-ctx.Done()
		close(out)
	}()
	return out, errs
}

// ContainerList filters the in-memory containers.
func (f *Fake) ContainerList(_ context.Context, opts dockerx.ContainerListOptions) ([]dockerx.Container, error) {
	if err := f.record("ContainerList", opts); err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]dockerx.Container, 0, len(f.Containers))
	for _, c := range f.Containers {
		if opts.State != "" && c.State != opts.State {
			continue
		}
		if opts.Stack != "" && c.Stack != opts.Stack {
			continue
		}
		out = append(out, c)
	}
	return out, nil
}

// ContainerInspect returns a stored detail.
func (f *Fake) ContainerInspect(_ context.Context, id string) (dockerx.ContainerDetail, error) {
	if err := f.record("ContainerInspect", id); err != nil {
		return dockerx.ContainerDetail{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if d, ok := f.Details[id]; ok {
		return d, nil
	}
	for key, d := range f.Details {
		if len(id) >= 4 && len(key) >= len(id) && key[:len(id)] == id {
			return d, nil
		}
		if d.Name == id {
			return d, nil
		}
	}
	return dockerx.ContainerDetail{}, fmt.Errorf("%w: container %s", dockerx.ErrNotFound, id)
}

// ContainerStats returns a stored sample.
func (f *Fake) ContainerStats(_ context.Context, id string) (dockerx.Stats, error) {
	if err := f.record("ContainerStats", id); err != nil {
		return dockerx.Stats{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if st, ok := f.StatsByID[id]; ok {
		return st, nil
	}
	return dockerx.Stats{Time: time.Now().UTC()}, nil
}

// ContainerStatsStream emits one sample then returns.
func (f *Fake) ContainerStatsStream(ctx context.Context, id string, out chan<- dockerx.Stats) error {
	if err := f.record("ContainerStatsStream", id); err != nil {
		return err
	}
	st, _ := f.ContainerStats(ctx, id)
	select {
	case out <- st:
	case <-ctx.Done():
		return ctx.Err()
	}
	<-ctx.Done()
	return nil
}

func (f *Fake) setState(id, state string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.Containers {
		if f.Containers[i].ID == id {
			f.Containers[i].State = state
		}
	}
}

// ContainerStart marks the container running.
func (f *Fake) ContainerStart(_ context.Context, id string) error {
	if err := f.record("ContainerStart", id); err != nil {
		return err
	}
	f.setState(id, "running")
	return nil
}

// ContainerStop marks the container exited.
func (f *Fake) ContainerStop(_ context.Context, id string, timeout int) error {
	if err := f.record("ContainerStop", id, timeout); err != nil {
		return err
	}
	f.setState(id, "exited")
	return nil
}

// ContainerRestart marks the container running.
func (f *Fake) ContainerRestart(_ context.Context, id string, timeout int) error {
	if err := f.record("ContainerRestart", id, timeout); err != nil {
		return err
	}
	f.setState(id, "running")
	return nil
}

// ContainerPause marks the container paused.
func (f *Fake) ContainerPause(_ context.Context, id string) error {
	if err := f.record("ContainerPause", id); err != nil {
		return err
	}
	f.setState(id, "paused")
	return nil
}

// ContainerUnpause marks the container running.
func (f *Fake) ContainerUnpause(_ context.Context, id string) error {
	if err := f.record("ContainerUnpause", id); err != nil {
		return err
	}
	f.setState(id, "running")
	return nil
}

// ContainerRemove drops the container from the list.
func (f *Fake) ContainerRemove(_ context.Context, id string, force, volumes bool) error {
	if err := f.record("ContainerRemove", id, force, volumes); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	out := f.Containers[:0]
	for _, c := range f.Containers {
		if c.ID != id {
			out = append(out, c)
		}
	}
	f.Containers = out
	delete(f.Details, id)
	return nil
}

// sliceLogReader replays LogLines.
type sliceLogReader struct {
	lines  []dockerx.LogLine
	i      int
	follow bool
	ctx    context.Context
}

func (r *sliceLogReader) Next() (dockerx.LogLine, error) {
	if r.i < len(r.lines) {
		l := r.lines[r.i]
		r.i++
		return l, nil
	}
	if r.follow {
		<-r.ctx.Done()
	}
	return dockerx.LogLine{}, io.EOF
}

func (r *sliceLogReader) Close() error { return nil }

// ContainerLogs replays the configured log lines.
func (f *Fake) ContainerLogs(ctx context.Context, id string, opts dockerx.LogOptions) (dockerx.LogReader, error) {
	if err := f.record("ContainerLogs", id, opts); err != nil {
		return nil, err
	}
	lines := make([]dockerx.LogLine, 0, len(f.LogLines))
	for _, l := range f.LogLines {
		if !opts.Stdout && l.Stream == "stdout" {
			continue
		}
		if !opts.Stderr && l.Stream == "stderr" {
			continue
		}
		lines = append(lines, l)
	}
	return &sliceLogReader{lines: lines, follow: opts.Follow, ctx: ctx}, nil
}

// ExecSession is a scripted exec session.
type ExecSession struct {
	Output   []byte
	Written  []byte
	Closed   bool
	ExitWith int

	mu  sync.Mutex
	pos int
}

// Read returns the scripted output once, then EOF.
func (e *ExecSession) Read(p []byte) (int, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.pos >= len(e.Output) {
		return 0, io.EOF
	}
	n := copy(p, e.Output[e.pos:])
	e.pos += n
	return n, nil
}

// Write records the input.
func (e *ExecSession) Write(p []byte) (int, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.Written = append(e.Written, p...)
	return len(p), nil
}

// Close marks the session closed.
func (e *ExecSession) Close() error { e.Closed = true; return nil }

// Resize is a no-op.
func (e *ExecSession) Resize(uint, uint) error { return nil }

// ExitCode reports the scripted exit code.
func (e *ExecSession) ExitCode() (int, bool, error) { return e.ExitWith, false, nil }

var _ dockerx.ExecSession = (*ExecSession)(nil)

// ContainerExec returns a scripted session.
func (f *Fake) ContainerExec(_ context.Context, id string, opts dockerx.ExecOptions) (dockerx.ExecSession, error) {
	if err := f.record("ContainerExec", id, opts); err != nil {
		return nil, err
	}
	sess := &ExecSession{Output: []byte("# ")}
	f.mu.Lock()
	f.lastExec = sess
	f.mu.Unlock()
	return sess, nil
}

// LastExecSession returns the session handed out by the last ContainerExec.
func (f *Fake) LastExecSession() *ExecSession {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.lastExec
}

// ImageList returns the in-memory images.
func (f *Fake) ImageList(context.Context) ([]dockerx.Image, error) {
	if err := f.record("ImageList"); err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]dockerx.Image(nil), f.Images...), nil
}

// ImagePull replays PullProgress.
func (f *Fake) ImagePull(ctx context.Context, ref string, auth *dockerx.RegistryAuth, onProgress func(dockerx.PullProgress)) error {
	hasAuth := auth != nil
	if err := f.record("ImagePull", ref, hasAuth); err != nil {
		return err
	}
	if err := f.hold(ctx, "ImagePull"); err != nil {
		return err
	}
	for _, p := range f.PullProgress {
		if onProgress != nil {
			onProgress(p)
		}
	}
	return nil
}

// ImageRemove drops an image.
func (f *Fake) ImageRemove(_ context.Context, id string, force bool) error {
	if err := f.record("ImageRemove", id, force); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	out := f.Images[:0]
	for _, i := range f.Images {
		if i.ID != id {
			out = append(out, i)
		}
	}
	f.Images = out
	return nil
}

// ImagePrune reports a fixed reclaim.
func (f *Fake) ImagePrune(ctx context.Context, danglingOnly bool) (dockerx.PruneResult, error) {
	if err := f.record("ImagePrune", danglingOnly); err != nil {
		return dockerx.PruneResult{}, err
	}
	if err := f.hold(ctx, "ImagePrune"); err != nil {
		return dockerx.PruneResult{}, err
	}
	return dockerx.PruneResult{Deleted: []string{"sha256:img3"}, SpaceReclaimed: 20 << 20}, nil
}

// VolumeList returns the in-memory volumes.
func (f *Fake) VolumeList(context.Context) ([]dockerx.Volume, error) {
	if err := f.record("VolumeList"); err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]dockerx.Volume(nil), f.Volumes...), nil
}

// VolumeCreate appends a volume.
func (f *Fake) VolumeCreate(_ context.Context, opts dockerx.VolumeCreateOptions) (dockerx.Volume, error) {
	if err := f.record("VolumeCreate", opts); err != nil {
		return dockerx.Volume{}, err
	}
	v := dockerx.Volume{Name: opts.Name, Driver: opts.Driver, Labels: opts.Labels, CreatedAt: time.Now().UTC()}
	if v.Driver == "" {
		v.Driver = "local"
	}
	f.mu.Lock()
	f.Volumes = append(f.Volumes, v)
	f.mu.Unlock()
	return v, nil
}

// VolumeRemove drops a volume.
func (f *Fake) VolumeRemove(_ context.Context, name string, force bool) error {
	if err := f.record("VolumeRemove", name, force); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	out := f.Volumes[:0]
	for _, v := range f.Volumes {
		if v.Name != name {
			out = append(out, v)
		}
	}
	f.Volumes = out
	return nil
}

// VolumePrune reports a fixed reclaim.
func (f *Fake) VolumePrune(ctx context.Context) (dockerx.PruneResult, error) {
	if err := f.record("VolumePrune"); err != nil {
		return dockerx.PruneResult{}, err
	}
	if err := f.hold(ctx, "VolumePrune"); err != nil {
		return dockerx.PruneResult{}, err
	}
	return dockerx.PruneResult{Deleted: []string{}, SpaceReclaimed: 0}, nil
}

// NetworkList returns the in-memory networks.
func (f *Fake) NetworkList(context.Context) ([]dockerx.Network, error) {
	if err := f.record("NetworkList"); err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]dockerx.Network(nil), f.Networks...), nil
}

// NetworkCreate appends a network.
func (f *Fake) NetworkCreate(_ context.Context, opts dockerx.NetworkCreateOptions) (dockerx.Network, error) {
	if err := f.record("NetworkCreate", opts); err != nil {
		return dockerx.Network{}, err
	}
	n := dockerx.Network{
		ID: "n" + opts.Name, Name: opts.Name, Driver: opts.Driver, Scope: "local",
		Attachable: opts.Attachable, Subnets: []string{},
	}
	if opts.Subnet != "" {
		n.Subnets = append(n.Subnets, opts.Subnet)
	}
	f.mu.Lock()
	f.Networks = append(f.Networks, n)
	f.mu.Unlock()
	return n, nil
}

// NetworkRemove drops a network.
func (f *Fake) NetworkRemove(_ context.Context, id string) error {
	if err := f.record("NetworkRemove", id); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	out := f.Networks[:0]
	for _, n := range f.Networks {
		if n.ID != id && n.Name != id {
			out = append(out, n)
		}
	}
	f.Networks = out
	return nil
}

// NetworkPrune reports nothing removed.
func (f *Fake) NetworkPrune(ctx context.Context) (dockerx.PruneResult, error) {
	if err := f.record("NetworkPrune"); err != nil {
		return dockerx.PruneResult{}, err
	}
	if err := f.hold(ctx, "NetworkPrune"); err != nil {
		return dockerx.PruneResult{}, err
	}
	return dockerx.PruneResult{Deleted: []string{}}, nil
}

// SwarmInfo returns the configured cluster.
func (f *Fake) SwarmInfo(context.Context) (dockerx.SwarmInfo, error) {
	if err := f.record("SwarmInfo"); err != nil {
		return dockerx.SwarmInfo{}, err
	}
	return f.Swarm, nil
}

// ServiceList returns services, or ErrNotManager when the fake is not one.
func (f *Fake) ServiceList(context.Context) ([]dockerx.Service, error) {
	if err := f.record("ServiceList"); err != nil {
		return nil, err
	}
	if !f.Swarm.Manager {
		return nil, dockerx.ErrNotManager
	}
	return f.Services, nil
}

// ServiceTasks returns the tasks of a service.
func (f *Fake) ServiceTasks(_ context.Context, id string) ([]dockerx.Task, error) {
	if err := f.record("ServiceTasks", id); err != nil {
		return nil, err
	}
	if !f.Swarm.Manager {
		return nil, dockerx.ErrNotManager
	}
	return f.Tasks[id], nil
}

// ServiceScale records the call.
func (f *Fake) ServiceScale(_ context.Context, id string, replicas uint64) error {
	if err := f.record("ServiceScale", id, replicas); err != nil {
		return err
	}
	if !f.Swarm.Manager {
		return dockerx.ErrNotManager
	}
	return nil
}

// ServiceUpdate records the call.
func (f *Fake) ServiceUpdate(ctx context.Context, id string, opts dockerx.ServiceUpdateOptions) error {
	if err := f.record("ServiceUpdate", id, opts); err != nil {
		return err
	}
	if err := f.hold(ctx, "ServiceUpdate"); err != nil {
		return err
	}
	if !f.Swarm.Manager {
		return dockerx.ErrNotManager
	}
	return nil
}

// ServiceRollback records the call.
func (f *Fake) ServiceRollback(ctx context.Context, id string) error {
	if err := f.record("ServiceRollback", id); err != nil {
		return err
	}
	if err := f.hold(ctx, "ServiceRollback"); err != nil {
		return err
	}
	if !f.Swarm.Manager {
		return dockerx.ErrNotManager
	}
	return nil
}

// RegistryLogin records the credential it was given so a test can prove the
// secret reached Docker and nowhere else.
func (f *Fake) RegistryLogin(_ context.Context, a dockerx.RegistryAuth) error {
	return f.record("RegistryLogin", a)
}
