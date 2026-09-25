// Package store is the agent's embedded persistence layer. It wraps bbolt
// with a tiny JSON document API: buckets of keys holding JSON values, plus an
// append-only log bucket used for the audit trail.
package store

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	bolt "go.etcd.io/bbolt"
)

// Bucket names used across the agent.
const (
	BucketDevices    = "devices"
	BucketDeviceKeys = "device_keys"
	BucketSettings   = "settings"
	BucketRegistries = "registries"
	BucketAlerts     = "alerts"
	BucketAlertRules = "alert_rules"
	BucketAudit      = "audit"
	BucketMeta       = "meta"
)

var buckets = []string{
	BucketDevices, BucketDeviceKeys, BucketSettings, BucketRegistries,
	BucketAlerts, BucketAlertRules, BucketAudit, BucketMeta,
}

// ErrNotFound is returned when a key is absent.
var ErrNotFound = errors.New("store: not found")

// Store is a bbolt-backed document store.
type Store struct {
	db *bolt.DB
}

// Open creates or opens the database at path, creating parent directories.
func Open(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("store: create data dir: %w", err)
	}
	db, err := bolt.Open(path, 0o600, &bolt.Options{Timeout: 5 * time.Second})
	if err != nil {
		return nil, fmt.Errorf("store: open %s: %w", path, err)
	}
	err = db.Update(func(tx *bolt.Tx) error {
		for _, b := range buckets {
			if _, err := tx.CreateBucketIfNotExists([]byte(b)); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("store: init buckets: %w", err)
	}
	return &Store{db: db}, nil
}

// Close releases the database.
func (s *Store) Close() error { return s.db.Close() }

// Put stores v as JSON under bucket/key.
func (s *Store) Put(bucket, key string, v any) error {
	raw, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("store: marshal: %w", err)
	}
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(bucket))
		if b == nil {
			return fmt.Errorf("store: unknown bucket %q", bucket)
		}
		return b.Put([]byte(key), raw)
	})
}

// PutRaw stores raw bytes under bucket/key.
func (s *Store) PutRaw(bucket, key string, raw []byte) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(bucket))
		if b == nil {
			return fmt.Errorf("store: unknown bucket %q", bucket)
		}
		return b.Put([]byte(key), raw)
	})
}

// Get decodes bucket/key into v. It returns ErrNotFound when absent.
func (s *Store) Get(bucket, key string, v any) error {
	return s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(bucket))
		if b == nil {
			return fmt.Errorf("store: unknown bucket %q", bucket)
		}
		raw := b.Get([]byte(key))
		if raw == nil {
			return ErrNotFound
		}
		return json.Unmarshal(raw, v)
	})
}

// GetRaw returns the raw bytes at bucket/key.
func (s *Store) GetRaw(bucket, key string) ([]byte, error) {
	var out []byte
	err := s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(bucket))
		if b == nil {
			return fmt.Errorf("store: unknown bucket %q", bucket)
		}
		raw := b.Get([]byte(key))
		if raw == nil {
			return ErrNotFound
		}
		out = append(out, raw...)
		return nil
	})
	return out, err
}

// Delete removes bucket/key. Deleting a missing key is not an error.
func (s *Store) Delete(bucket, key string) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(bucket))
		if b == nil {
			return fmt.Errorf("store: unknown bucket %q", bucket)
		}
		return b.Delete([]byte(key))
	})
}

// ForEach walks every key in a bucket in key order.
func (s *Store) ForEach(bucket string, fn func(key string, raw []byte) error) error {
	return s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(bucket))
		if b == nil {
			return fmt.Errorf("store: unknown bucket %q", bucket)
		}
		return b.ForEach(func(k, v []byte) error {
			return fn(string(k), v)
		})
	})
}

// Update runs fn inside a single write transaction, giving it a Tx view that
// can read and write several buckets atomically.
func (s *Store) Update(fn func(tx *Tx) error) error {
	return s.db.Update(func(btx *bolt.Tx) error { return fn(&Tx{tx: btx}) })
}

// Tx is a write transaction handle.
type Tx struct{ tx *bolt.Tx }

// Put stores v as JSON.
func (t *Tx) Put(bucket, key string, v any) error {
	raw, err := json.Marshal(v)
	if err != nil {
		return err
	}
	b := t.tx.Bucket([]byte(bucket))
	if b == nil {
		return fmt.Errorf("store: unknown bucket %q", bucket)
	}
	return b.Put([]byte(key), raw)
}

// Get decodes bucket/key into v.
func (t *Tx) Get(bucket, key string, v any) error {
	b := t.tx.Bucket([]byte(bucket))
	if b == nil {
		return fmt.Errorf("store: unknown bucket %q", bucket)
	}
	raw := b.Get([]byte(key))
	if raw == nil {
		return ErrNotFound
	}
	return json.Unmarshal(raw, v)
}

// IsEmpty reports whether a bucket holds no keys.
func (t *Tx) IsEmpty(bucket string) (bool, error) {
	b := t.tx.Bucket([]byte(bucket))
	if b == nil {
		return false, fmt.Errorf("store: unknown bucket %q", bucket)
	}
	k, _ := b.Cursor().First()
	return k == nil, nil
}

// Delete removes bucket/key.
func (t *Tx) Delete(bucket, key string) error {
	b := t.tx.Bucket([]byte(bucket))
	if b == nil {
		return fmt.Errorf("store: unknown bucket %q", bucket)
	}
	return b.Delete([]byte(key))
}

// Append writes v to an append-only bucket keyed by an increasing sequence,
// so that key order is insertion order. It returns the sequence number.
func (s *Store) Append(bucket string, v any) (uint64, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return 0, err
	}
	var seq uint64
	err = s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(bucket))
		if b == nil {
			return fmt.Errorf("store: unknown bucket %q", bucket)
		}
		n, err := b.NextSequence()
		if err != nil {
			return err
		}
		seq = n
		return b.Put(SeqKey(n), raw)
	})
	return seq, err
}

// SeqKey encodes a sequence number as a sortable 8 byte key.
func SeqKey(n uint64) []byte {
	var k [8]byte
	binary.BigEndian.PutUint64(k[:], n)
	return k[:]
}

// SeqOf decodes a key produced by SeqKey.
func SeqOf(key []byte) uint64 {
	if len(key) != 8 {
		return 0
	}
	return binary.BigEndian.Uint64(key)
}

// WalkDesc walks an append-only bucket newest first, starting strictly below
// startSeq when startSeq > 0. fn stops the walk by returning false.
func (s *Store) WalkDesc(bucket string, startSeq uint64, fn func(seq uint64, raw []byte) bool) error {
	return s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(bucket))
		if b == nil {
			return fmt.Errorf("store: unknown bucket %q", bucket)
		}
		c := b.Cursor()
		var k, v []byte
		if startSeq > 0 {
			k, v = c.Seek(SeqKey(startSeq))
			if k == nil {
				k, v = c.Last()
			} else {
				k, v = c.Prev()
			}
		} else {
			k, v = c.Last()
		}
		for ; k != nil; k, v = c.Prev() {
			if !fn(SeqOf(k), v) {
				return nil
			}
		}
		return nil
	})
}

// TrimOldest keeps at most max entries in an append-only bucket.
func (s *Store) TrimOldest(bucket string, max int) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(bucket))
		if b == nil {
			return fmt.Errorf("store: unknown bucket %q", bucket)
		}
		n := b.Stats().KeyN
		excess := n - max
		if excess <= 0 {
			return nil
		}
		c := b.Cursor()
		var doomed [][]byte
		for k, _ := c.First(); k != nil && excess > 0; k, _ = c.Next() {
			doomed = append(doomed, append([]byte(nil), k...))
			excess--
		}
		for _, k := range doomed {
			if err := b.Delete(k); err != nil {
				return err
			}
		}
		return nil
	})
}
