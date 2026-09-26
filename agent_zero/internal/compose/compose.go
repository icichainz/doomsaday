// Package compose discovers Compose projects and drives `docker compose`.
//
// The command is always built as an argument list and executed directly:
// there is no shell, and no value coming from the API is ever used as a flag
// or a path. The only thing a caller supplies is a project name, which must
// match a project that discovery already found.
package compose

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"agent_zero/internal/dockerx"
)

// Errors returned by this package.
var (
	ErrNotFound = errors.New("compose: project not found")
	ErrInvalid  = errors.New("compose: invalid project name")
)

// projectNameRe is Compose's own project name rule.
var projectNameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,62}$`)

// ValidateName checks a project name coming from the API.
func ValidateName(name string) error {
	if !projectNameRe.MatchString(name) {
		return fmt.Errorf("%w: %q", ErrInvalid, name)
	}
	return nil
}

// composeFileNames are the file names discovery looks for, in order.
var composeFileNames = []string{
	"compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml",
}

// Service is one service of a project.
type Service struct {
	Name       string              `json:"name"`
	Containers []dockerx.Container `json:"containers"`
	Running    int                 `json:"running"`
	Total      int                 `json:"total"`
}

// Project is a discovered Compose project.
type Project struct {
	Name        string    `json:"name"`
	ConfigFiles []string  `json:"config_files"`
	WorkingDir  string    `json:"working_dir,omitempty"`
	Source      string    `json:"source"` // "directory" or "labels"
	Services    []Service `json:"services"`
	Running     int       `json:"services_running"`
	Total       int       `json:"services_total"`
	// ConfigOnDisk says whether a compose file was actually found, which is
	// what tells the API whether up, redeploy and down can work.
	ConfigOnDisk bool `json:"config_on_disk"`
}

// Discoverer finds Compose projects from the stacks directory and from
// container labels.
type Discoverer struct {
	StacksDir string
	Docker    dockerx.Client
}

// Discover returns every project it can see, merging both sources.
func (d *Discoverer) Discover(ctx context.Context) ([]Project, error) {
	byName := map[string]*Project{}

	for _, p := range d.fromDirectory() {
		cp := p
		byName[p.Name] = &cp
	}

	containers, err := d.Docker.ContainerList(ctx, dockerx.ContainerListOptions{})
	if err != nil {
		// Without the daemon we can still report what is on disk.
		if len(byName) == 0 {
			return nil, err
		}
		containers = nil
	}

	svcContainers := map[string]map[string][]dockerx.Container{}
	for _, c := range containers {
		if c.Stack == "" {
			continue
		}
		p, ok := byName[c.Stack]
		if !ok {
			p = &Project{Name: c.Stack, Source: "labels", ConfigFiles: []string{}}
			if c.Labels != nil {
				if cf := c.Labels["com.docker.compose.project.config_files"]; cf != "" {
					p.ConfigFiles = splitConfigFiles(cf)
				}
				p.WorkingDir = c.Labels["com.docker.compose.project.working_dir"]
			}
			for _, f := range p.ConfigFiles {
				if st, err := os.Stat(f); err == nil && !st.IsDir() {
					p.ConfigOnDisk = true
				}
			}
			byName[c.Stack] = p
		}
		svc := c.Service
		if svc == "" {
			svc = "(unknown)"
		}
		if svcContainers[c.Stack] == nil {
			svcContainers[c.Stack] = map[string][]dockerx.Container{}
		}
		svcContainers[c.Stack][svc] = append(svcContainers[c.Stack][svc], c)
	}

	out := make([]Project, 0, len(byName))
	for name, p := range byName {
		for svcName, cs := range svcContainers[name] {
			s := Service{Name: svcName, Containers: cs, Total: len(cs)}
			for _, c := range cs {
				if c.State == "running" {
					s.Running++
				}
			}
			p.Services = append(p.Services, s)
		}
		sort.Slice(p.Services, func(i, j int) bool { return p.Services[i].Name < p.Services[j].Name })
		if p.Services == nil {
			p.Services = []Service{}
		}
		p.Total = len(p.Services)
		for _, s := range p.Services {
			if s.Running > 0 {
				p.Running++
			}
		}
		out = append(out, *p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// Get returns one project by name.
func (d *Discoverer) Get(ctx context.Context, name string) (Project, error) {
	if err := ValidateName(name); err != nil {
		return Project{}, err
	}
	all, err := d.Discover(ctx)
	if err != nil {
		return Project{}, err
	}
	for _, p := range all {
		if p.Name == name {
			return p, nil
		}
	}
	return Project{}, ErrNotFound
}

func splitConfigFiles(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// fromDirectory walks the configured stacks directory one level deep.
func (d *Discoverer) fromDirectory() []Project {
	if d.StacksDir == "" {
		return nil
	}
	entries, err := os.ReadDir(d.StacksDir)
	if err != nil {
		return nil
	}
	var out []Project
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := normalizeProjectName(e.Name())
		if name == "" {
			continue
		}
		dir := filepath.Join(d.StacksDir, e.Name())
		for _, fn := range composeFileNames {
			full := filepath.Join(dir, fn)
			if st, err := os.Stat(full); err == nil && !st.IsDir() {
				out = append(out, Project{
					Name:         name,
					ConfigFiles:  []string{full},
					WorkingDir:   dir,
					Source:       "directory",
					ConfigOnDisk: true,
				})
				break
			}
		}
	}
	return out
}

// normalizeProjectName maps a directory name to a Compose project name the
// same way Compose does, and rejects anything that still does not fit.
func normalizeProjectName(dir string) string {
	s := strings.ToLower(dir)
	s = strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-', r == '_':
			return r
		default:
			return -1
		}
	}, s)
	if err := ValidateName(s); err != nil {
		return ""
	}
	return s
}

// Runner executes docker compose commands for a project.
type Runner struct {
	// Bin is the docker CLI binary, "docker" by default.
	Bin string
	// StopGrace is how long a cancelled command gets between SIGTERM and
	// SIGKILL; defaultStopGrace when zero.
	StopGrace time.Duration
}

// Action is one of the stack operations the API exposes.
type Action string

// The four stack actions.
const (
	ActionUp       Action = "up"
	ActionRedeploy Action = "redeploy"
	ActionRestart  Action = "restart"
	ActionDown     Action = "down"
)

// argsFor returns the fixed argument lists for an action. Each entry is one
// docker compose invocation.
func argsFor(a Action) ([][]string, error) {
	switch a {
	case ActionUp:
		return [][]string{{"up", "-d", "--remove-orphans"}}, nil
	case ActionRedeploy:
		return [][]string{{"pull"}, {"up", "-d", "--remove-orphans"}}, nil
	case ActionRestart:
		return [][]string{{"restart"}}, nil
	case ActionDown:
		return [][]string{{"down"}}, nil
	}
	return nil, fmt.Errorf("compose: unknown action %q", a)
}

// Run performs an action on a project, streaming combined output line by
// line to onLine.
func (r *Runner) Run(ctx context.Context, p Project, a Action, onLine func(string)) error {
	if err := ValidateName(p.Name); err != nil {
		return err
	}
	steps, err := argsFor(a)
	if err != nil {
		return err
	}
	bin := r.Bin
	if bin == "" {
		bin = "docker"
	}
	for _, step := range steps {
		argv := []string{"compose", "--project-name", p.Name}
		for _, f := range p.ConfigFiles {
			argv = append(argv, "--file", f)
		}
		if p.WorkingDir != "" {
			argv = append(argv, "--project-directory", p.WorkingDir)
		}
		argv = append(argv, step...)

		if onLine != nil {
			onLine("$ " + bin + " " + strings.Join(argv, " "))
		}
		grace := r.StopGrace
		if grace <= 0 {
			grace = defaultStopGrace
		}
		if err := runCommand(ctx, bin, argv, p.WorkingDir, grace, onLine); err != nil {
			return err
		}
	}
	return nil
}

// defaultStopGrace is how long a cancelled compose command gets to exit
// after SIGTERM before its process group is killed.
const defaultStopGrace = 10 * time.Second

func runCommand(ctx context.Context, bin string, argv []string, dir string, grace time.Duration, onLine func(string)) error {
	cmd := exec.CommandContext(ctx, bin, argv...)
	if dir != "" {
		cmd.Dir = dir
	}
	// A deliberately minimal environment: no inherited secrets.
	cmd.Env = append(os.Environ(), "COMPOSE_ANSI=never", "DOCKER_CLI_HINTS=false")

	// `docker compose` is the docker CLI running the compose plugin as a
	// child process. Killing only the parent on cancel leaves the plugin
	// running and holding the output pipes, so the command would never be
	// seen to end. The command therefore runs in its own process group: a
	// cancel sends SIGTERM to the whole group and SIGKILL after grace, and
	// WaitDelay stops Wait from waiting on the pipes for longer than that.
	stopGroup := ownProcessGroup(cmd, grace)
	defer stopGroup()
	cmd.WaitDelay = 2 * grace

	out := &lineWriter{onLine: onLine}
	errOut := &lineWriter{onLine: onLine, shared: &out.mu}
	cmd.Stdout = out
	cmd.Stderr = errOut

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("compose: start %s: %w", bin, err)
	}
	err := cmd.Wait()
	out.flush()
	errOut.flush()
	if ctxErr := ctx.Err(); ctxErr != nil {
		return fmt.Errorf("compose: %s stopped: %w", bin, ctxErr)
	}
	if err != nil {
		return fmt.Errorf("compose: %s %s: %w", bin, strings.Join(argv, " "), err)
	}
	return nil
}

// lineWriter turns a command's output into onLine calls, one per line. Two
// writers may share a mutex so stdout and stderr lines never interleave
// mid-call.
type lineWriter struct {
	onLine func(string)
	mu     sync.Mutex
	shared *sync.Mutex
	buf    []byte
}

func (w *lineWriter) lock() func() {
	m := &w.mu
	if w.shared != nil {
		m = w.shared
	}
	m.Lock()
	return m.Unlock
}

func (w *lineWriter) Write(p []byte) (int, error) {
	defer w.lock()()
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		w.emit(w.buf[:i])
		w.buf = w.buf[i+1:]
	}
	// A line longer than this is not a progress line; pass it on in pieces
	// rather than buffering without bound.
	if len(w.buf) > maxLine {
		w.emit(w.buf)
		w.buf = nil
	}
	return len(p), nil
}

func (w *lineWriter) flush() {
	defer w.lock()()
	if len(w.buf) > 0 {
		w.emit(w.buf)
		w.buf = nil
	}
}

func (w *lineWriter) emit(line []byte) {
	if w.onLine != nil {
		w.onLine(strings.TrimRight(string(line), "\r"))
	}
}

const maxLine = 1024 * 1024
