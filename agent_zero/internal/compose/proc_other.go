//go:build !unix

package compose

import (
	"os/exec"
	"time"
)

// ownProcessGroup keeps exec's default on platforms without process groups:
// a cancel kills the command itself, and WaitDelay bounds the wait for its
// pipes.
func ownProcessGroup(*exec.Cmd, time.Duration) func() { return func() {} }
