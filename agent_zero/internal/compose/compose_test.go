package compose

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"agent_zero/internal/dockerx"
	"agent_zero/internal/dockerx/fakedocker"
)

func TestValidateName(t *testing.T) {
	good := []string{"demo", "my-stack", "a", "stack_1", strings.Repeat("a", 63)}
	for _, n := range good {
		if err := ValidateName(n); err != nil {
			t.Errorf("ValidateName(%q) = %v", n, err)
		}
	}
	bad := []string{
		"", "Demo", "-leading", "has space", "../escape", "a/b",
		"--project-name", strings.Repeat("a", 64), "stack;rm -rf /", "$(id)",
	}
	for _, n := range bad {
		if err := ValidateName(n); err == nil {
			t.Errorf("ValidateName(%q) accepted the value", n)
		}
	}
}

func TestArgsForNeverTakesUserInput(t *testing.T) {
	for _, a := range []Action{ActionUp, ActionRedeploy, ActionRestart, ActionDown} {
		steps, err := argsFor(a)
		if err != nil {
			t.Fatalf("argsFor(%q) = %v", a, err)
		}
		if len(steps) == 0 {
			t.Fatalf("argsFor(%q) produced no steps", a)
		}
		for _, step := range steps {
			for _, arg := range step {
				if strings.ContainsAny(arg, "$;&|`") {
					t.Fatalf("argument %q looks like shell", arg)
				}
			}
		}
	}
	if _, err := argsFor(Action("rm -rf /")); err == nil {
		t.Fatal("an unknown action was accepted")
	}
}

func TestRedeployPullsThenUps(t *testing.T) {
	steps, err := argsFor(ActionRedeploy)
	if err != nil {
		t.Fatal(err)
	}
	if len(steps) != 2 || steps[0][0] != "pull" || steps[1][0] != "up" {
		t.Fatalf("redeploy steps = %v", steps)
	}
	if !contains(steps[1], "-d") {
		t.Fatalf("up is not detached: %v", steps[1])
	}
}

func contains(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}

func TestDiscoverFromDirectory(t *testing.T) {
	dir := t.TempDir()
	mustMkdir(t, filepath.Join(dir, "blog"))
	mustWrite(t, filepath.Join(dir, "blog", "compose.yaml"), "services: {}\n")
	mustMkdir(t, filepath.Join(dir, "no-compose-here"))
	mustMkdir(t, filepath.Join(dir, "Legacy_App"))
	mustWrite(t, filepath.Join(dir, "Legacy_App", "docker-compose.yml"), "services: {}\n")

	fake := fakedocker.New()
	fake.Containers = nil
	d := &Discoverer{StacksDir: dir, Docker: fake}

	projects, err := d.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]Project{}
	for _, p := range projects {
		names[p.Name] = p
	}
	if _, ok := names["blog"]; !ok {
		t.Fatalf("blog was not discovered: %v", projects)
	}
	if !names["blog"].ConfigOnDisk {
		t.Fatal("blog has a compose file but config_on_disk is false")
	}
	if _, ok := names["no-compose-here"]; ok {
		t.Fatal("a directory without a compose file was discovered")
	}
	if _, ok := names["legacy_app"]; !ok {
		t.Fatalf("Legacy_App was not normalised to legacy_app: %v", projects)
	}
}

func TestDiscoverFromLabels(t *testing.T) {
	fake := fakedocker.New()
	d := &Discoverer{StacksDir: t.TempDir(), Docker: fake}

	projects, err := d.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(projects) != 1 || projects[0].Name != "demo" {
		t.Fatalf("projects = %+v", projects)
	}
	p := projects[0]
	if p.Source != "labels" {
		t.Fatalf("source = %q", p.Source)
	}
	if p.Total != 2 {
		t.Fatalf("services total = %d, want 2", p.Total)
	}
	if p.Running != 1 {
		t.Fatalf("services running = %d, want 1", p.Running)
	}
	byName := map[string]Service{}
	for _, s := range p.Services {
		byName[s.Name] = s
	}
	if byName["web"].Running != 1 || byName["db"].Running != 0 {
		t.Fatalf("services = %+v", p.Services)
	}
}

func TestDiscoveryMergesBothSources(t *testing.T) {
	dir := t.TempDir()
	mustMkdir(t, filepath.Join(dir, "demo"))
	mustWrite(t, filepath.Join(dir, "demo", "compose.yaml"), "services: {}\n")

	fake := fakedocker.New()
	d := &Discoverer{StacksDir: dir, Docker: fake}

	projects, err := d.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(projects) != 1 {
		t.Fatalf("the same project was reported twice: %+v", projects)
	}
	p := projects[0]
	if p.Source != "directory" || !p.ConfigOnDisk {
		t.Fatalf("project = %+v", p)
	}
	if p.Total != 2 {
		t.Fatalf("the directory project did not pick up its running services: %+v", p)
	}
}

func TestGetRejectsBadNames(t *testing.T) {
	d := &Discoverer{StacksDir: t.TempDir(), Docker: fakedocker.New()}
	if _, err := d.Get(context.Background(), "../etc"); err == nil {
		t.Fatal("a traversal name was accepted")
	}
	if _, err := d.Get(context.Background(), "missing"); err != ErrNotFound {
		t.Fatalf("Get(missing) = %v", err)
	}
}

func TestDiscoverSurvivesADeadDaemon(t *testing.T) {
	dir := t.TempDir()
	mustMkdir(t, filepath.Join(dir, "blog"))
	mustWrite(t, filepath.Join(dir, "blog", "compose.yaml"), "services: {}\n")

	fake := fakedocker.New()
	fake.Errs["ContainerList"] = dockerx.ErrUnavailable

	d := &Discoverer{StacksDir: dir, Docker: fake}
	projects, err := d.Discover(context.Background())
	if err != nil {
		t.Fatalf("discovery failed although a compose file is on disk: %v", err)
	}
	if len(projects) != 1 {
		t.Fatalf("projects = %+v", projects)
	}
}

func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
