package env

import (
	"reflect"
	"sort"
	"testing"
)

func TestMapSetGetUnset(t *testing.T) {
	m := New()
	m.Set("FOO", "bar")
	m.Set("BAZ", "qux")

	if v, ok := m.Get("FOO"); !ok || v != "bar" {
		t.Errorf("Get(FOO) = %q, %v; want \"bar\", true", v, ok)
	}
	if _, ok := m.Get("MISSING"); ok {
		t.Error("Get(MISSING) returned ok=true")
	}
	if m.Len() != 2 {
		t.Errorf("Len = %d, want 2", m.Len())
	}

	m.Unset("FOO")
	if _, ok := m.Get("FOO"); ok {
		t.Error("after Unset, Get(FOO) returned ok=true")
	}
	if m.Len() != 1 {
		t.Errorf("after Unset, Len = %d, want 1", m.Len())
	}
}

func TestMapKeysSorted(t *testing.T) {
	m := New()
	m.Set("Z", "1")
	m.Set("A", "2")
	m.Set("M", "3")

	keys := m.Keys()
	want := []string{"A", "M", "Z"}
	if !reflect.DeepEqual(keys, want) {
		t.Errorf("Keys = %v, want %v", keys, want)
	}
}

func TestMapDiffSetUnset(t *testing.T) {
	a := New()
	a.Set("X", "1")
	a.Set("Y", "2")
	a.Set("Z", "3")

	b := New()
	b.Set("X", "1")   // unchanged
	b.Set("Y", "NEW") // changed
	b.Set("W", "4")   // added

	diff := a.Diff(b)
	if len(diff) != 3 {
		t.Fatalf("expected 3 diffs, got %d: %+v", len(diff), diff)
	}

	// Build a map for easy lookup.
	byKey := make(map[string]DiffOp)
	for _, op := range diff {
		byKey[op.Key] = op
	}

	// X: unchanged → no entry
	if _, ok := byKey["X"]; ok {
		t.Error("X should be unchanged")
	}

	// Y: changed from "2" to "NEW"
	if y, ok := byKey["Y"]; !ok || !y.Set || y.Value != "NEW" || y.Old != "2" {
		t.Errorf("Y diff wrong: %+v", y)
	}

	// Z: removed
	if z, ok := byKey["Z"]; !ok || z.Set || z.Old != "3" {
		t.Errorf("Z diff wrong: %+v", z)
	}

	// W: added
	if w, ok := byKey["W"]; !ok || !w.Set || w.Value != "4" {
		t.Errorf("W diff wrong: %+v", w)
	}
}

func TestMapMergeOverride(t *testing.T) {
	a := New()
	a.Set("X", "1")
	a.Set("Y", "2")

	b := New()
	b.Set("Y", "OVERRIDE")
	b.Set("Z", "3")

	a.Merge(b)

	if v, _ := a.Get("X"); v != "1" {
		t.Errorf("X = %q, want \"1\"", v)
	}
	if v, _ := a.Get("Y"); v != "OVERRIDE" {
		t.Errorf("Y = %q, want \"OVERRIDE\"", v)
	}
	if v, _ := a.Get("Z"); v != "3" {
		t.Errorf("Z = %q, want \"3\"", v)
	}
}

func TestMapFromMap(t *testing.T) {
	src := map[string]string{
		"A": "1",
		"B": "2",
	}
	m := FromMap(src)

	keys := m.Keys()
	sort.Strings(keys)
	if !reflect.DeepEqual(keys, []string{"A", "B"}) {
		t.Errorf("Keys = %v", keys)
	}
}

func TestMapClone(t *testing.T) {
	a := New()
	a.Set("X", "1")

	b := a.Clone()
	b.Set("X", "2")

	if v, _ := a.Get("X"); v != "1" {
		t.Errorf("clone mutated original: X = %q, want \"1\"", v)
	}
	if v, _ := b.Get("X"); v != "2" {
		t.Errorf("clone did not persist: X = %q, want \"2\"", v)
	}
}

func TestMapAsExport(t *testing.T) {
	m := New()
	m.Set("A", "1")
	m.Set("B", "with spaces")
	m.Set("C", "with=equals")

	out := m.AsExport()
	if len(out) != 3 {
		t.Errorf("AsExport len = %d, want 3", len(out))
	}
	// Set semantics are not guaranteed; check that all entries are present.
	have := make(map[string]string)
	for _, kv := range out {
		for i := 0; i < len(kv); i++ {
			if kv[i] == '=' {
				have[kv[:i]] = kv[i+1:]
				break
			}
		}
	}
	if have["A"] != "1" || have["B"] != "with spaces" || have["C"] != "with=equals" {
		t.Errorf("AsExport missing entries: %v", have)
	}
}
