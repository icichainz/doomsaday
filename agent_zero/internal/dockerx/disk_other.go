//go:build !linux && !darwin

package dockerx

// diskUsageOf is not implemented on this platform.
func diskUsageOf(string) (total, used int64, err error) {
	return 0, 0, ErrUnsupported
}
