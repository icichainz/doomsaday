//go:build unix

package compose

import (
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// ownProcessGroup starts cmd as the leader of a new process group and makes a
// context cancel send SIGTERM to the whole group, so the compose plugin the
// docker CLI runs as a child stops too, then SIGKILL to the group after grace
// for anything that ignored it or was forked while the first signal was in
// flight. The returned function must be called once the command has been
// waited for: it kills whatever is still left of a cancelled group and stops
// the pending SIGKILL timer.
func ownProcessGroup(cmd *exec.Cmd, grace time.Duration) func() {
	var (
		mu        sync.Mutex
		cancelled bool
		timer     *time.Timer
	)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		mu.Lock()
		defer mu.Unlock()
		cancelled = true
		timer = time.AfterFunc(grace, func() { _ = signalGroup(cmd, syscall.SIGKILL) })
		return signalGroup(cmd, syscall.SIGTERM)
	}
	return func() {
		mu.Lock()
		defer mu.Unlock()
		if timer != nil {
			timer.Stop()
		}
		if cancelled {
			_ = signalGroup(cmd, syscall.SIGKILL)
		}
	}
}

func signalGroup(cmd *exec.Cmd, sig syscall.Signal) error {
	if cmd.Process == nil {
		return nil
	}
	// A negative pid addresses the process group led by that pid.
	err := syscall.Kill(-cmd.Process.Pid, sig)
	if err == syscall.ESRCH {
		return nil
	}
	return err
}
