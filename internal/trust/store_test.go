package trust

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestStoreTrustAndStatus(t *testing.T) {
	dir := t.TempDir()
	s := NewStoreAt(dir)

	path := "/tmp/proj/envee.toml"
	hash := "sha256:abc123"

	// Initially unknown
	if st, err := s.Status(path, hash); err != nil {
		t.Fatal(err)
	} else if st != Unknown {
		t.Errorf("initial status = %v, want Unknown", st)
	}

	// Trust
	if err := s.Trust(path, hash, 0); err != nil {
		t.Fatal(err)
	}

	// Now trusted
	if st, _ := s.Status(path, hash); st != Trusted {
		t.Errorf("after trust, status = %v, want Trusted", st)
	}
}

func TestStoreTrustWithTTL(t *testing.T) {
	dir := t.TempDir()
	s := NewStoreAt(dir)

	path := "/tmp/proj/envee.toml"
	hash := "sha256:def456"

	// Trust with 1-hour TTL
	if err := s.Trust(path, hash, time.Hour); err != nil {
		t.Fatal(err)
	}
	if st, _ := s.Status(path, hash); st != Trusted {
		t.Errorf("status = %v, want Trusted", st)
	}

	// Trust with 1ms TTL — should be expired
	if err := s.Trust(path, hash, time.Millisecond); err != nil {
		t.Fatal(err)
	}
	time.Sleep(10 * time.Millisecond)
	if st, _ := s.Status(path, hash); st != Expired {
		t.Errorf("status = %v, want Expired", st)
	}
}

func TestStoreRevoke(t *testing.T) {
	dir := t.TempDir()
	s := NewStoreAt(dir)

	path := "/tmp/proj/envee.toml"
	hash := "sha256:revoke"

	if err := s.Trust(path, hash, 0); err != nil {
		t.Fatal(err)
	}
	if err := s.Revoke(hash); err != nil {
		t.Fatal(err)
	}
	if st, _ := s.Status(path, hash); st != Unknown {
		t.Errorf("after revoke, status = %v, want Unknown", st)
	}
}

func TestStoreDeny(t *testing.T) {
	dir := t.TempDir()
	s := NewStoreAt(dir)

	path := "/tmp/proj/envee.toml"
	if err := s.Deny(path); err != nil {
		t.Fatal(err)
	}

	denyPath := filepath.Join(dir, "deny", pathHash(path)+".json")
	if _, err := os.Stat(denyPath); err != nil {
		t.Errorf("deny file not created: %v", err)
	}
}

func TestCanonicalHash(t *testing.T) {
	data := []byte("hello world")
	h1 := CanonicalHash(data)
	h2 := CanonicalHash(data)
	if h1 != h2 {
		t.Errorf("CanonicalHash is not deterministic: %s vs %s", h1, h2)
	}
	if len(h1) < 7 || h1[:7] != "sha256:" {
		t.Errorf("hash should start with sha256:, got %q", h1)
	}
}

func TestStatusString(t *testing.T) {
	tests := map[Status]string{
		Unknown: "unknown",
		Trusted: "trusted",
		Denied:  "denied",
		Expired: "expired",
	}
	for st, want := range tests {
		if got := st.String(); got != want {
			t.Errorf("%d.String() = %q, want %q", st, got, want)
		}
	}
}
