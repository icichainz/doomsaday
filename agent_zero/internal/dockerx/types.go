// Package dockerx is the narrow surface the HTTP handlers use to reach
// Docker. Everything the agent needs is expressed with the domain types in
// this file, so handlers never import the Docker SDK and can be tested
// against a fake.
package dockerx

import (
	"errors"
	"io"
	"time"
)

// Sentinel errors, mapped to HTTP status codes by the API layer.
var (
	// ErrNotFound means the object does not exist.
	ErrNotFound = errors.New("dockerx: not found")
	// ErrConflict means the daemon refused because of current state.
	ErrConflict = errors.New("dockerx: conflict")
	// ErrNotManager means the host is not a Swarm manager.
	ErrNotManager = errors.New("dockerx: not a swarm manager")
	// ErrUnavailable means the daemon could not be reached.
	ErrUnavailable = errors.New("dockerx: docker daemon unavailable")
	// ErrUnsupported means the operation is not available on this host.
	ErrUnsupported = errors.New("dockerx: unsupported")
)

// SystemInfo describes the host and its daemon.
type SystemInfo struct {
	Hostname          string `json:"hostname"`
	DockerVersion     string `json:"docker_version"`
	APIVersion        string `json:"api_version"`
	OS                string `json:"os"`
	OSType            string `json:"os_type"`
	Arch              string `json:"arch"`
	KernelVersion     string `json:"kernel_version"`
	CPUCores          int    `json:"cpu_cores"`
	MemTotal          int64  `json:"memory_total"`
	SwarmRole         string `json:"swarm_role"` // manager, worker or inactive
	SwarmNodeID       string `json:"swarm_node_id,omitempty"`
	Containers        int    `json:"containers"`
	ContainersRunning int    `json:"containers_running"`
	ContainersPaused  int    `json:"containers_paused"`
	ContainersStopped int    `json:"containers_stopped"`
	Images            int    `json:"images"`
	DockerRoot        string `json:"-"`
}

// HostMetrics are the live host figures behind the overview screen.
type HostMetrics struct {
	CPUPercent        float64 `json:"cpu_percent"`
	MemTotal          int64   `json:"memory_total"`
	MemUsed           int64   `json:"memory_used"`
	DiskTotal         int64   `json:"disk_total"`
	DiskUsed          int64   `json:"disk_used"`
	HostUptimeSeconds int64   `json:"host_uptime_seconds"`
	// CPUSource says how CPU was measured: "host" or "containers".
	CPUSource string `json:"cpu_source"`
	// MemSource says how memory was measured: "host" or "containers".
	MemSource string `json:"memory_source"`
}

// DiskUsage is what Docker itself is holding on disk.
type DiskUsage struct {
	ImagesSize      int64 `json:"images_size"`
	ImagesReclaim   int64 `json:"images_reclaimable"`
	ContainersSize  int64 `json:"containers_size"`
	VolumesSize     int64 `json:"volumes_size"`
	VolumesReclaim  int64 `json:"volumes_reclaimable"`
	BuildCacheSize  int64 `json:"build_cache_size"`
	BuildCacheClean int64 `json:"build_cache_reclaimable"`
}

// Port is a container port mapping.
type Port struct {
	IP          string `json:"ip,omitempty"`
	PrivatePort int    `json:"private_port"`
	PublicPort  int    `json:"public_port,omitempty"`
	Type        string `json:"type"`
}

// Container is a list row.
type Container struct {
	ID           string            `json:"id"`
	Name         string            `json:"name"`
	Image        string            `json:"image"`
	ImageID      string            `json:"image_id"`
	State        string            `json:"state"`
	Status       string            `json:"status"`
	Health       string            `json:"health,omitempty"`
	CreatedAt    time.Time         `json:"created_at"`
	StartedAt    time.Time         `json:"started_at,omitempty"`
	FinishedAt   time.Time         `json:"finished_at,omitempty"`
	ExitCode     int               `json:"exit_code"`
	RestartCount int               `json:"restart_count"`
	Stack        string            `json:"stack,omitempty"`
	Service      string            `json:"service,omitempty"`
	Ports        []Port            `json:"ports"`
	Labels       map[string]string `json:"labels,omitempty"`
}

// Mount is a container mount point.
type Mount struct {
	Type        string `json:"type"`
	Name        string `json:"name,omitempty"`
	Source      string `json:"source,omitempty"`
	Destination string `json:"destination"`
	Mode        string `json:"mode,omitempty"`
	RW          bool   `json:"rw"`
}

// NetworkAttachment is one network a container is joined to.
type NetworkAttachment struct {
	Name        string   `json:"name"`
	NetworkID   string   `json:"network_id"`
	IPAddress   string   `json:"ip_address,omitempty"`
	Gateway     string   `json:"gateway,omitempty"`
	MacAddress  string   `json:"mac_address,omitempty"`
	Aliases     []string `json:"aliases,omitempty"`
	IPPrefixLen int      `json:"ip_prefix_len,omitempty"`
}

// RestartPolicy is the container restart policy.
type RestartPolicy struct {
	Name              string `json:"name"`
	MaximumRetryCount int    `json:"maximum_retry_count,omitempty"`
}

// ContainerDetail is the container detail screen.
type ContainerDetail struct {
	Container
	Command       string              `json:"command,omitempty"`
	Entrypoint    []string            `json:"entrypoint,omitempty"`
	WorkingDir    string              `json:"working_dir,omitempty"`
	User          string              `json:"user,omitempty"`
	Platform      string              `json:"platform,omitempty"`
	Networks      []NetworkAttachment `json:"networks"`
	Mounts        []Mount             `json:"mounts"`
	RestartPolicy RestartPolicy       `json:"restart_policy"`
	LogDriver     string              `json:"log_driver,omitempty"`
	// Env holds the real values. Handlers expose names only, except on the
	// admin-only /env endpoint.
	Env []string `json:"-"`
	// DependsOn lists container names this one links to or shares a
	// namespace with, used by /impact.
	DependsOn   []string `json:"depends_on,omitempty"`
	NetworkMode string   `json:"network_mode,omitempty"`
}

// Stats is one sample of a container's resource use.
type Stats struct {
	Time       time.Time `json:"ts"`
	CPUPercent float64   `json:"cpu_percent"`
	MemUsage   int64     `json:"memory_usage"`
	MemLimit   int64     `json:"memory_limit"`
	MemPercent float64   `json:"memory_percent"`
	NetRxBytes int64     `json:"net_rx_bytes"`
	NetTxBytes int64     `json:"net_tx_bytes"`
	BlkRead    int64     `json:"block_read_bytes"`
	BlkWrite   int64     `json:"block_write_bytes"`
	PIDs       int64     `json:"pids"`
}

// ContainerListOptions filters a container listing.
type ContainerListOptions struct {
	State string
	Stack string
}

// LogOptions selects a slice of a container's logs.
type LogOptions struct {
	Since  time.Time
	Until  time.Time
	Tail   string
	Stdout bool
	Stderr bool
	Follow bool
}

// LogLine is one log record.
type LogLine struct {
	Time   time.Time `json:"ts"`
	Stream string    `json:"stream"`
	Line   string    `json:"line"`
}

// LogReader yields log lines until io.EOF.
type LogReader interface {
	Next() (LogLine, error)
	Close() error
}

// ExecOptions configures an interactive exec session.
type ExecOptions struct {
	Cmd    []string
	TTY    bool
	User   string
	Width  uint
	Height uint
}

// ExecSession is a live exec: read output, write stdin.
type ExecSession interface {
	io.ReadWriteCloser
	Resize(width, height uint) error
	// ExitCode reports the exit status once the process is gone.
	ExitCode() (code int, running bool, err error)
}

// Image is an image list row.
type Image struct {
	ID         string    `json:"id"`
	Tags       []string  `json:"tags"`
	Digests    []string  `json:"digests,omitempty"`
	Size       int64     `json:"size"`
	SharedSize int64     `json:"shared_size,omitempty"`
	CreatedAt  time.Time `json:"created_at"`
	Containers int64     `json:"-"`
	Dangling   bool      `json:"dangling"`
}

// RegistryAuth is a resolved credential for a pull.
type RegistryAuth struct {
	Host     string
	Username string
	Secret   string
}

// PullProgress is one layer progress update.
type PullProgress struct {
	ID      string `json:"id,omitempty"`
	Status  string `json:"status"`
	Current int64  `json:"current,omitempty"`
	Total   int64  `json:"total,omitempty"`
}

// PruneResult is what a prune reclaimed.
type PruneResult struct {
	Deleted        []string `json:"deleted"`
	SpaceReclaimed int64    `json:"space_reclaimed"`
}

// Volume is a volume list row.
type Volume struct {
	Name       string            `json:"name"`
	Driver     string            `json:"driver"`
	Mountpoint string            `json:"mountpoint,omitempty"`
	CreatedAt  time.Time         `json:"created_at"`
	Size       int64             `json:"size"`
	Scope      string            `json:"scope,omitempty"`
	Labels     map[string]string `json:"labels,omitempty"`
}

// VolumeCreateOptions is the body of POST /volumes.
type VolumeCreateOptions struct {
	Name   string
	Driver string
	Labels map[string]string
}

// Network is a network list row.
type Network struct {
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	Driver     string   `json:"driver"`
	Scope      string   `json:"scope"`
	Subnets    []string `json:"subnets"`
	Internal   bool     `json:"internal"`
	Attachable bool     `json:"attachable"`
	IsDefault  bool     `json:"is_default"`
	Containers int      `json:"attached_containers"`
	Ingress    bool     `json:"ingress,omitempty"`
}

// NetworkCreateOptions is the body of POST /networks.
type NetworkCreateOptions struct {
	Name       string
	Driver     string
	Subnet     string
	Attachable bool
}

// SwarmNode is one node in the cluster.
type SwarmNode struct {
	ID            string    `json:"id"`
	Hostname      string    `json:"hostname"`
	Role          string    `json:"role"`
	Availability  string    `json:"availability"`
	Status        string    `json:"status"`
	Addr          string    `json:"addr,omitempty"`
	EngineVersion string    `json:"engine_version,omitempty"`
	Leader        bool      `json:"leader"`
	CreatedAt     time.Time `json:"created_at,omitempty"`
}

// SwarmInfo is GET /swarm.
type SwarmInfo struct {
	Active    bool        `json:"active"`
	NodeID    string      `json:"node_id,omitempty"`
	NodeRole  string      `json:"node_role"`
	ClusterID string      `json:"cluster_id,omitempty"`
	Manager   bool        `json:"is_manager"`
	Nodes     []SwarmNode `json:"nodes"`
}

// Service is a Swarm service row.
type Service struct {
	ID            string    `json:"id"`
	Name          string    `json:"name"`
	Image         string    `json:"image"`
	Mode          string    `json:"mode"`
	Replicas      uint64    `json:"desired_tasks"`
	Running       uint64    `json:"running_tasks"`
	UpdateState   string    `json:"update_state,omitempty"`
	UpdateMessage string    `json:"update_message,omitempty"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
	Ports         []Port    `json:"ports,omitempty"`
}

// Task is one Swarm task.
type Task struct {
	ID           string    `json:"id"`
	ServiceID    string    `json:"service_id"`
	Slot         int       `json:"slot,omitempty"`
	NodeID       string    `json:"node_id,omitempty"`
	NodeName     string    `json:"node_name,omitempty"`
	State        string    `json:"state"`
	DesiredState string    `json:"desired_state"`
	Error        string    `json:"error,omitempty"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// ServiceUpdateOptions is the body of POST /services/{id}/update.
type ServiceUpdateOptions struct {
	Image string
	Force bool
}

// Event is a Docker event.
type Event struct {
	Time       time.Time         `json:"ts"`
	Type       string            `json:"type"`
	Action     string            `json:"action"`
	ActorID    string            `json:"actor_id,omitempty"`
	ActorName  string            `json:"actor_name,omitempty"`
	Scope      string            `json:"scope,omitempty"`
	Attributes map[string]string `json:"attributes,omitempty"`
}
