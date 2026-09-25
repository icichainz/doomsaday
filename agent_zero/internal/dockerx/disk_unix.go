//go:build linux || darwin

package dockerx

import "syscall"

// diskUsageOf returns the total and used bytes of the filesystem holding path.
func diskUsageOf(path string) (total, used int64, err error) {
	if path == "" {
		return 0, 0, ErrUnsupported
	}
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0, err
	}
	bs := uint64(st.Bsize)
	total = int64(st.Blocks * bs)
	used = int64((st.Blocks - st.Bfree) * bs)
	return total, used, nil
}
