// Package env represents environment variables and provides diff/merge operations.
//
// The core type is Map, an ordered map of variable name -> value. We use
// a sorted slice internally for deterministic output (important for stable
// shell exports and JSON serialization).
//
// See docs/adr/0005-shell-hooks.md for the env diff algorithm.
package env

import (
	"sort"
	"strings"
)

// Map is an ordered collection of environment variables.
type Map struct {
	// entries are kept sorted by Key for deterministic iteration.
	entries []Entry
	index   map[string]int // key -> position in entries
}

// Entry is a single env variable with metadata.
type Entry struct {
	Key      string
	Value    string
	Redacted bool   // value should be masked in output
	Source   string // "toml", "dotenv", "secret", "script", etc.
}

// New returns an empty env Map.
func New() *Map {
	return &Map{
		index: make(map[string]int),
	}
}

// FromMap creates a Map from a plain Go map.
func FromMap(m map[string]string) *Map {
	out := New()
	for k, v := range m {
		out.Set(k, v)
	}
	return out
}

// Clone returns a deep copy.
func (m *Map) Clone() *Map {
	out := &Map{
		entries: make([]Entry, len(m.entries)),
		index:   make(map[string]int, len(m.entries)),
	}
	copy(out.entries, m.entries)
	for k, v := range m.index {
		out.index[k] = v
	}
	return out
}

// Len returns the number of entries.
func (m *Map) Len() int {
	return len(m.entries)
}

// Get returns the value and a boolean indicating presence.
func (m *Map) Get(key string) (string, bool) {
	if i, ok := m.index[key]; ok {
		return m.entries[i].Value, true
	}
	return "", false
}

// GetWithMeta returns the full entry (value + metadata).
func (m *Map) GetWithMeta(key string) (Entry, bool) {
	if i, ok := m.index[key]; ok {
		return m.entries[i], true
	}
	return Entry{}, false
}

// Set inserts or updates an entry.
func (m *Map) Set(key, value string) {
	if i, ok := m.index[key]; ok {
		m.entries[i].Value = value
		return
	}
	m.index[key] = len(m.entries)
	m.entries = append(m.entries, Entry{Key: key, Value: value})
}

// SetWithMeta inserts an entry with full metadata.
func (m *Map) SetWithMeta(e Entry) {
	if i, ok := m.index[e.Key]; ok {
		m.entries[i] = e
		return
	}
	m.index[e.Key] = len(m.entries)
	m.entries = append(m.entries, e)
}

// Unset removes an entry, if present.
func (m *Map) Unset(key string) {
	if _, ok := m.index[key]; !ok {
		return
	}
	delete(m.index, key)
	// Rebuild entries slice to keep it contiguous.
	out := m.entries[:0]
	for _, e := range m.entries {
		if e.Key == key {
			continue
		}
		out = append(out, e)
	}
	m.entries = out
	// Rebuild index.
	for i, e := range m.entries {
		m.index[e.Key] = i
	}
}

// Keys returns all keys in sorted order.
func (m *Map) Keys() []string {
	keys := make([]string, 0, len(m.entries))
	for _, e := range m.entries {
		keys = append(keys, e.Key)
	}
	sort.Strings(keys)
	return keys
}

// AsMap returns a copy as a plain Go map.
func (m *Map) AsMap() map[string]string {
	out := make(map[string]string, len(m.entries))
	for _, e := range m.entries {
		out[e.Key] = e.Value
	}
	return out
}

// AsExport returns the env in "KEY=VALUE" form (suitable for os.Environ).
func (m *Map) AsExport() []string {
	out := make([]string, 0, len(m.entries))
	for _, e := range m.entries {
		out = append(out, e.Key+"="+e.Value)
	}
	return out
}

// Merge applies the other Map on top of m (other wins on key conflicts).
// Useful for layering env from various sources.
func (m *Map) Merge(other *Map) {
	if other == nil {
		return
	}
	for _, e := range other.entries {
		m.SetWithMeta(e)
	}
}

// DiffOp describes a single change between two env states.
type DiffOp struct {
	Key   string
	Set   bool   // true = set, false = unset
	Value string // only meaningful if Set
	Old   string // previous value, if any
}

// Diff returns the diff from m -> other (what would change if we replaced m with other).
func (m *Map) Diff(other *Map) []DiffOp {
	var ops []DiffOp

	// Collect keys from both sides.
	seen := make(map[string]struct{})
	for _, e := range other.entries {
		seen[e.Key] = struct{}{}
		oldVal, exists := m.Get(e.Key)
		if !exists {
			ops = append(ops, DiffOp{Key: e.Key, Set: true, Value: e.Value})
		} else if oldVal != e.Value {
			ops = append(ops, DiffOp{Key: e.Key, Set: true, Value: e.Value, Old: oldVal})
		}
	}
	for _, e := range m.entries {
		if _, ok := seen[e.Key]; ok {
			continue
		}
		ops = append(ops, DiffOp{Key: e.Key, Set: false, Old: e.Value})
	}
	sort.Slice(ops, func(i, j int) bool { return ops[i].Key < ops[j].Key })
	return ops
}

// FromOSEnviron parses os.Environ() into a Map.
func FromOSEnviron() *Map {
	m := New()
	for _, kv := range osEnviron() {
		if eq := strings.IndexByte(kv, '='); eq > 0 {
			m.Set(kv[:eq], kv[eq+1:])
		}
	}
	return m
}
