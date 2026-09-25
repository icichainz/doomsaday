// Package version carries the agent build version.
package version

// Version is the agent version. Override at build time with
// -ldflags "-X agent_zero/internal/version.Version=1.2.3".
var Version = "0.1.0"
