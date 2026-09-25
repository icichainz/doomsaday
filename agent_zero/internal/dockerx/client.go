package dockerx

import "context"

// Client is everything the agent is allowed to do to Docker. It is
// deliberately a closed list: the agent never proxies the raw Docker API, so
// anything not on this interface cannot be reached through the REST API.
type Client interface {
	Ping(ctx context.Context) error
	Close() error

	Info(ctx context.Context) (SystemInfo, error)
	HostMetrics(ctx context.Context) (HostMetrics, error)
	DiskUsage(ctx context.Context) (DiskUsage, error)
	Events(ctx context.Context) (<-chan Event, <-chan error)

	ContainerList(ctx context.Context, opts ContainerListOptions) ([]Container, error)
	ContainerInspect(ctx context.Context, id string) (ContainerDetail, error)
	ContainerStats(ctx context.Context, id string) (Stats, error)
	ContainerStatsStream(ctx context.Context, id string, out chan<- Stats) error
	ContainerStart(ctx context.Context, id string) error
	ContainerStop(ctx context.Context, id string, timeoutSeconds int) error
	ContainerRestart(ctx context.Context, id string, timeoutSeconds int) error
	ContainerPause(ctx context.Context, id string) error
	ContainerUnpause(ctx context.Context, id string) error
	ContainerRemove(ctx context.Context, id string, force, volumes bool) error
	ContainerLogs(ctx context.Context, id string, opts LogOptions) (LogReader, error)
	ContainerExec(ctx context.Context, id string, opts ExecOptions) (ExecSession, error)

	ImageList(ctx context.Context) ([]Image, error)
	ImagePull(ctx context.Context, ref string, auth *RegistryAuth, onProgress func(PullProgress)) error
	ImageRemove(ctx context.Context, id string, force bool) error
	ImagePrune(ctx context.Context, danglingOnly bool) (PruneResult, error)

	VolumeList(ctx context.Context) ([]Volume, error)
	VolumeCreate(ctx context.Context, opts VolumeCreateOptions) (Volume, error)
	VolumeRemove(ctx context.Context, name string, force bool) error
	VolumePrune(ctx context.Context) (PruneResult, error)

	NetworkList(ctx context.Context) ([]Network, error)
	NetworkCreate(ctx context.Context, opts NetworkCreateOptions) (Network, error)
	NetworkRemove(ctx context.Context, id string) error
	NetworkPrune(ctx context.Context) (PruneResult, error)

	SwarmInfo(ctx context.Context) (SwarmInfo, error)
	ServiceList(ctx context.Context) ([]Service, error)
	ServiceTasks(ctx context.Context, serviceID string) ([]Task, error)
	ServiceScale(ctx context.Context, serviceID string, replicas uint64) error
	ServiceUpdate(ctx context.Context, serviceID string, opts ServiceUpdateOptions) error
	ServiceRollback(ctx context.Context, serviceID string) error

	RegistryLogin(ctx context.Context, auth RegistryAuth) error
}
