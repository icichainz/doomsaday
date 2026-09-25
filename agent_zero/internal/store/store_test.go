package store

import (
	"errors"
	"path/filepath"
	"testing"
)

type doc struct {
	Name string `json:"name"`
	N    int    `json:"n"`
}

func open(t *testing.T) *Store {
	t.Helper()
	st, err := Open(filepath.Join(t.TempDir(), "s.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func TestPutGetDelete(t *testing.T) {
	st := open(t)
	if err := st.Put(BucketMeta, "k", doc{Name: "a", N: 1}); err != nil {
		t.Fatal(err)
	}
	var got doc
	if err := st.Get(BucketMeta, "k", &got); err != nil {
		t.Fatal(err)
	}
	if got.Name != "a" || got.N != 1 {
		t.Fatalf("got %+v", got)
	}
	if err := st.Get(BucketMeta, "missing", &got); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Get(missing) = %v", err)
	}
	if err := st.Delete(BucketMeta, "k"); err != nil {
		t.Fatal(err)
	}
	if err := st.Get(BucketMeta, "k", &got); !errors.Is(err, ErrNotFound) {
		t.Fatalf("after delete: %v", err)
	}
	if err := st.Put("nope", "k", got); err == nil {
		t.Fatal("an unknown bucket was accepted")
	}
}

func TestTransactionIsAtomic(t *testing.T) {
	st := open(t)
	wantErr := errors.New("rollback")
	err := st.Update(func(tx *Tx) error {
		if err := tx.Put(BucketMeta, "a", doc{Name: "a"}); err != nil {
			return err
		}
		return wantErr
	})
	if !errors.Is(err, wantErr) {
		t.Fatalf("Update = %v", err)
	}
	var got doc
	if err := st.Get(BucketMeta, "a", &got); !errors.Is(err, ErrNotFound) {
		t.Fatalf("a failed transaction was committed: %v", err)
	}
}

func TestIsEmpty(t *testing.T) {
	st := open(t)
	err := st.Update(func(tx *Tx) error {
		empty, err := tx.IsEmpty(BucketDevices)
		if err != nil {
			return err
		}
		if !empty {
			t.Fatal("a fresh bucket is not empty")
		}
		return tx.Put(BucketDevices, "d1", doc{Name: "d"})
	})
	if err != nil {
		t.Fatal(err)
	}
	err = st.Update(func(tx *Tx) error {
		empty, err := tx.IsEmpty(BucketDevices)
		if err != nil {
			return err
		}
		if empty {
			t.Fatal("a bucket with a key reports empty")
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestAppendAndWalkDesc(t *testing.T) {
	st := open(t)
	for i := 0; i < 5; i++ {
		if _, err := st.Append(BucketAudit, doc{N: i}); err != nil {
			t.Fatal(err)
		}
	}
	var order []uint64
	err := st.WalkDesc(BucketAudit, 0, func(seq uint64, _ []byte) bool {
		order = append(order, seq)
		return true
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(order) != 5 {
		t.Fatalf("walked %d entries", len(order))
	}
	for i := 1; i < len(order); i++ {
		if order[i] >= order[i-1] {
			t.Fatalf("WalkDesc is not newest first: %v", order)
		}
	}

	// Resuming from a sequence starts at that entry.
	var resumed []uint64
	err = st.WalkDesc(BucketAudit, 3, func(seq uint64, _ []byte) bool {
		resumed = append(resumed, seq)
		return true
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(resumed) != 2 || resumed[0] != 2 {
		t.Fatalf("resumed walk = %v, want [2 1]", resumed)
	}
}

func TestTrimOldest(t *testing.T) {
	st := open(t)
	for i := 0; i < 20; i++ {
		if _, err := st.Append(BucketAudit, doc{N: i}); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.TrimOldest(BucketAudit, 5); err != nil {
		t.Fatal(err)
	}
	n := 0
	oldest := uint64(0)
	err := st.WalkDesc(BucketAudit, 0, func(seq uint64, _ []byte) bool {
		n++
		oldest = seq
		return true
	})
	if err != nil {
		t.Fatal(err)
	}
	if n != 5 {
		t.Fatalf("kept %d entries, want 5", n)
	}
	if oldest != 16 {
		t.Fatalf("oldest kept sequence = %d, want 16", oldest)
	}
}

func TestSeqKeyRoundTrip(t *testing.T) {
	for _, n := range []uint64{0, 1, 1 << 40} {
		if got := SeqOf(SeqKey(n)); got != n {
			t.Fatalf("SeqOf(SeqKey(%d)) = %d", n, got)
		}
	}
	if SeqOf([]byte("short")) != 0 {
		t.Fatal("a malformed key did not decode to zero")
	}
}
