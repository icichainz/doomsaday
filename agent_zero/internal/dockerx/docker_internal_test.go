package dockerx

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"testing"
	"time"

	"github.com/docker/docker/api/types/container"
)

// frame builds one multiplexed docker log frame.
func frame(stream byte, payload string) []byte {
	var hdr [8]byte
	hdr[0] = stream
	binary.BigEndian.PutUint32(hdr[4:8], uint32(len(payload)))
	return append(hdr[:], []byte(payload)...)
}

func TestLogReaderDemultiplexes(t *testing.T) {
	var buf bytes.Buffer
	buf.Write(frame(1, "2024-05-01T10:00:00.000000000Z hello from stdout\n"))
	buf.Write(frame(2, "2024-05-01T10:00:01.000000000Z oops from stderr\n"))

	r := &logReader{rc: io.NopCloser(&buf), br: bufio.NewReader(&buf)}
	first, err := r.Next()
	if err != nil {
		t.Fatal(err)
	}
	if first.Stream != "stdout" || first.Line != "hello from stdout" {
		t.Fatalf("first = %+v", first)
	}
	if first.Time.Format(time.RFC3339) != "2024-05-01T10:00:00Z" {
		t.Fatalf("timestamp = %s", first.Time)
	}

	second, err := r.Next()
	if err != nil {
		t.Fatal(err)
	}
	if second.Stream != "stderr" || second.Line != "oops from stderr" {
		t.Fatalf("second = %+v", second)
	}

	if _, err := r.Next(); !errors.Is(err, io.EOF) {
		t.Fatalf("third read = %v, want EOF", err)
	}
}

func TestLogReaderSplitsAFrameWithSeveralLines(t *testing.T) {
	var buf bytes.Buffer
	buf.Write(frame(1, "one\ntwo\nthree\n"))
	r := &logReader{rc: io.NopCloser(&buf), br: bufio.NewReader(&buf)}

	var got []string
	for {
		l, err := r.Next()
		if err != nil {
			break
		}
		got = append(got, l.Line)
	}
	if len(got) != 3 || got[2] != "three" {
		t.Fatalf("lines = %v", got)
	}
}

func TestLogReaderTTYStream(t *testing.T) {
	buf := bytes.NewBufferString("2024-05-01T10:00:00.000000000Z raw tty line\n")
	r := &logReader{rc: io.NopCloser(buf), br: bufio.NewReader(buf), tty: true}

	l, err := r.Next()
	if err != nil {
		t.Fatal(err)
	}
	if l.Line != "raw tty line" || l.Stream != "stdout" {
		t.Fatalf("line = %+v", l)
	}
}

func TestParseLogLineWithoutATimestamp(t *testing.T) {
	l := parseLogLine("stdout", "no timestamp here")
	if l.Line != "no timestamp here" {
		t.Fatalf("line = %q", l.Line)
	}
	if l.Time.IsZero() {
		t.Fatal("no fallback timestamp was set")
	}
}

func TestConvertStats(t *testing.T) {
	raw := container.StatsResponse{
		Read: time.Date(2024, 5, 1, 10, 0, 0, 0, time.UTC),
	}
	raw.CPUStats.CPUUsage.TotalUsage = 2_000_000_000
	raw.PreCPUStats.CPUUsage.TotalUsage = 1_000_000_000
	raw.CPUStats.SystemUsage = 20_000_000_000
	raw.PreCPUStats.SystemUsage = 10_000_000_000
	raw.CPUStats.OnlineCPUs = 4
	raw.MemoryStats.Usage = 200 << 20
	raw.MemoryStats.Limit = 1 << 30
	raw.MemoryStats.Stats = map[string]uint64{"inactive_file": 100 << 20}
	raw.Networks = map[string]container.NetworkStats{
		"eth0": {RxBytes: 100, TxBytes: 200},
		"eth1": {RxBytes: 50, TxBytes: 25},
	}
	raw.BlkioStats.IoServiceBytesRecursive = []container.BlkioStatEntry{
		{Op: "Read", Value: 4096}, {Op: "Write", Value: 8192},
	}
	raw.PidsStats.Current = 7

	got := convertStats(raw)
	// 1e9 / 1e10 * 4 * 100 = 40 percent.
	if got.CPUPercent < 39.9 || got.CPUPercent > 40.1 {
		t.Fatalf("cpu = %v, want 40", got.CPUPercent)
	}
	// Page cache is subtracted, the way docker stats reports it.
	if got.MemUsage != 100<<20 {
		t.Fatalf("memory = %d, want %d", got.MemUsage, 100<<20)
	}
	if got.MemPercent < 9.7 || got.MemPercent > 9.8 {
		t.Fatalf("memory percent = %v", got.MemPercent)
	}
	if got.NetRxBytes != 150 || got.NetTxBytes != 225 {
		t.Fatalf("network = %d/%d", got.NetRxBytes, got.NetTxBytes)
	}
	if got.BlkRead != 4096 || got.BlkWrite != 8192 {
		t.Fatalf("block io = %d/%d", got.BlkRead, got.BlkWrite)
	}
	if got.PIDs != 7 {
		t.Fatalf("pids = %d", got.PIDs)
	}
}

func TestConvertStatsWithNoPreviousSample(t *testing.T) {
	raw := container.StatsResponse{}
	raw.CPUStats.CPUUsage.TotalUsage = 1000
	got := convertStats(raw)
	if got.CPUPercent != 0 {
		t.Fatalf("cpu without a previous sample = %v, want 0", got.CPUPercent)
	}
	if got.Time.IsZero() {
		t.Fatal("no fallback time")
	}
}

func TestHealthFromStatus(t *testing.T) {
	for in, want := range map[string]string{
		"Up 2 hours (healthy)":           "healthy",
		"Up 3 minutes (unhealthy)":       "unhealthy",
		"Up 1 second (health: starting)": "starting",
		"Up 4 days":                      "",
		"Exited (1) 5 minutes ago":       "",
	} {
		if got := healthFromStatus(in); got != want {
			t.Errorf("healthFromStatus(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestIsDefaultNetwork(t *testing.T) {
	for _, n := range []string{"bridge", "host", "none", "ingress", "docker_gwbridge"} {
		if !isDefaultNetwork(n) {
			t.Errorf("%q is not treated as a default network", n)
		}
	}
	if isDefaultNetwork("my-app_default") {
		t.Error("a compose network is treated as a default network")
	}
}

func TestWrapMapsErrors(t *testing.T) {
	if err := wrap(errors.New("This node is not a swarm manager.")); !errors.Is(err, ErrNotManager) {
		t.Fatalf("swarm error mapped to %v", err)
	}
	if err := wrap(errors.New("Cannot connect to the Docker daemon at unix:///var/run/docker.sock")); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("connection error mapped to %v", err)
	}
	if wrap(nil) != nil {
		t.Fatal("wrap(nil) is not nil")
	}
}
