// Package trust implements the envee trust store.
//
// The trust store records explicit user approvals of envee.toml files. Each
// entry is keyed by the canonical SHA-256 hash of the file content (see
// docs/adr/0004-trust-model.md) and stored in JSON form under
// $XDG_DATA_HOME/envee/trust/.
//
// We deliberately store the trust entries in $XDG_DATA_HOME (not
// $XDG_CONFIG_HOME) so that they are not synced to iCloud/Dropbox/syncthing,
// which are often configured to mirror ~/.config.
package trust

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/baken667/envee/internal/paths"
)

// Status describes the trust state of a file.
type Status int

const (
	// Unknown means no trust entry exists for this file.
	Unknown Status = iota
	// Trusted means the file is explicitly approved.
	Trusted
	// Denied means the file is explicitly blocked.
	Denied
	// Expired means a previous trust has timed out.
	Expired
)

// Entry is a single trust record persisted to disk.
type Entry struct {
	Version     int       `json:"version"`
	FileHash    string    `json:"file_hash"`
	FilePath    string    `json:"file_path"`
	TrustedAt   time.Time `json:"trusted_at"`
	TrustedBy   string    `json:"trusted_by"`
	ToolVersion string    `json:"tool_version"`
	ExpiresAt   time.Time `json:"expires_at,omitempty"`
	Signature   *Sig      `json:"signature,omitempty"`
	Comment     string    `json:"comment,omitempty"`
}

// Sig represents an optional ed25519 signature over the rest of the entry.
type Sig struct {
	Algorithm string    `json:"algorithm"`
	KeyID     string    `json:"key_id"`
	Value     string    `json:"value"`
	SignedAt  time.Time `json:"signed_at"`
}

// Store is a file-backed trust store rooted at $XDG_DATA_HOME/envee/trust.
type Store struct {
	root string
	now  func() time.Time
}

// NewStore returns a Store rooted at the default location.
func NewStore() *Store {
	return &Store{
		root: paths.TrustStore(),
		now:  time.Now,
	}
}

// NewStoreAt returns a Store rooted at an explicit directory (for testing).
func NewStoreAt(root string) *Store {
	return &Store{root: root, now: time.Now}
}

// Status returns the trust status for the given file.
//
// The hash is computed by CanonicalHash.
func (s *Store) Status(filePath, hash string) (Status, error) {
	entryPath := s.entryPath(hash)

	data, err := os.ReadFile(entryPath)
	if err != nil {
		if os.IsNotExist(err) {
			return Unknown, nil
		}
		return Unknown, err
	}

	var entry Entry
	if err := json.Unmarshal(data, &entry); err != nil {
		return Unknown, err
	}

	if !entry.ExpiresAt.IsZero() && s.now().After(entry.ExpiresAt) {
		return Expired, nil
	}
	return Trusted, nil
}

// Trust adds a trust entry for the file at filePath with the given hash.
//
// TTL of zero means "never expires". Use a positive duration for time-bounded trust.
func (s *Store) Trust(filePath, hash string, ttl time.Duration) error {
	entry := Entry{
		Version:     1,
		FileHash:    hash,
		FilePath:    filePath,
		TrustedAt:   s.now(),
		TrustedBy:   currentUser(),
		ToolVersion: "0.0.0-dev",
	}
	if ttl > 0 {
		entry.ExpiresAt = s.now().Add(ttl)
	}
	return s.writeEntry(hash, entry)
}

// Deny adds a deny entry for the file at filePath.
func (s *Store) Deny(filePath string) error {
	pathHash := pathHash(filePath)
	denyPath := filepath.Join(s.root, "deny", pathHash+".json")
	if err := os.MkdirAll(filepath.Dir(denyPath), 0o700); err != nil {
		return err
	}
	return os.WriteFile(denyPath, []byte(filePath+"\n"), 0o600)
}

// Revoke removes the trust entry for a file (does not affect deny).
func (s *Store) Revoke(hash string) error {
	entryPath := s.entryPath(hash)
	err := os.Remove(entryPath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// entryPath returns the path to the trust entry for a given hash.
func (s *Store) entryPath(hash string) string {
	return filepath.Join(s.root, sanitize(hash)+".json")
}

// writeEntry atomically writes an entry to disk.
func (s *Store) writeEntry(hash string, e Entry) error {
	if err := os.MkdirAll(s.root, 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(e, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(s.root, "trust-*.json.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return err
	}
	return os.Rename(tmpPath, s.entryPath(hash))
}

// sanitize strips the "sha256:" prefix from a hash for use in filenames.
func sanitize(h string) string {
	if len(h) > 7 && h[:7] == "sha256:" {
		return h[7:]
	}
	return h
}

// pathHash returns the sha256 of the absolute path, hex-encoded.
func pathHash(p string) string {
	abs, err := filepath.Abs(p)
	if err != nil {
		abs = p
	}
	sum := sha256.Sum256([]byte(abs + "\n"))
	return hex.EncodeToString(sum[:])
}

// CanonicalHash computes a stable sha256 of a TOML document.
//
// For now we just hash the raw bytes; future versions can re-marshal to
// canonicalize key order.
func CanonicalHash(data []byte) string {
	sum := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func currentUser() string {
	if u := os.Getenv("USER"); u != "" {
		return u
	}
	if u := os.Getenv("USERNAME"); u != "" {
		return u
	}
	return "unknown"
}

// String returns a human-readable status.
func (st Status) String() string {
	switch st {
	case Trusted:
		return "trusted"
	case Denied:
		return "denied"
	case Expired:
		return "expired"
	default:
		return "unknown"
	}
}

// ErrNotTrusted is returned when an action requires a trusted file.
var ErrNotTrusted = fmt.Errorf("file is not trusted")
