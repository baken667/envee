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
	"sort"
	"time"

	"github.com/baken667/envee/internal/paths"
	"github.com/baken667/envee/internal/version"
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
//
// Fields are ordered widest-first (pointer, time.Time, strings, int) to keep
// padding down. That is a deliberate choice, not a linter requirement --
// .golangci.yml disables govet's fieldalignment.
type Entry struct {
	Signature   *Sig      `json:"signature,omitempty"`
	ExpiresAt   time.Time `json:"expires_at,omitempty"`
	TrustedAt   time.Time `json:"trusted_at"`
	FileHash    string    `json:"file_hash"`
	FilePath    string    `json:"file_path"`
	TrustedBy   string    `json:"trusted_by"`
	ToolVersion string    `json:"tool_version"`
	Comment     string    `json:"comment,omitempty"`
	Version     int       `json:"version"`
}

// Sig represents an optional ed25519 signature over the rest of the entry.
type Sig struct {
	SignedAt  time.Time `json:"signed_at"`
	Algorithm string    `json:"algorithm"`
	KeyID     string    `json:"key_id"`
	Value     string    `json:"value"`
}

// Store is a file-backed trust store rooted at $XDG_DATA_HOME/envee/trust.
type Store struct {
	now  func() time.Time
	root string
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
	// Deny is keyed by path, not content: denying a file must keep denying it
	// after an edit. Check it first -- an explicit deny outranks any trust
	// entry that may also exist for the current content.
	if denied, err := s.isDenied(filePath); err != nil {
		return Unknown, err
	} else if denied {
		return Denied, nil
	}

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
	return s.Put(s.NewEntry(filePath, hash, ttl))
}

// NewEntry builds an unsigned trust entry without storing it. Callers that
// need to sign one do so between building and storing, since the signature
// covers the finished entry.
func (s *Store) NewEntry(filePath, hash string, ttl time.Duration) Entry {
	e := Entry{
		Version:     1,
		FileHash:    hash,
		FilePath:    filePath,
		TrustedAt:   s.now(),
		TrustedBy:   currentUser(),
		ToolVersion: version.Version,
	}
	if ttl > 0 {
		e.ExpiresAt = s.now().Add(ttl)
	}
	return e
}

// Put stores a trust entry, clearing any deny for the same path.
func (s *Store) Put(e Entry) error {
	if err := s.Undeny(e.FilePath); err != nil {
		return err
	}
	return s.writeEntry(e.FileHash, e)
}

// Get returns the stored entry for a hash. The boolean reports whether one
// exists; a missing entry is not an error.
func (s *Store) Get(hash string) (Entry, bool, error) {
	data, err := os.ReadFile(s.entryPath(hash))
	if os.IsNotExist(err) {
		return Entry{}, false, nil
	}
	if err != nil {
		return Entry{}, false, err
	}
	var e Entry
	if err := json.Unmarshal(data, &e); err != nil {
		return Entry{}, false, fmt.Errorf("parse trust entry for %s: %w", hash, err)
	}
	return e, true, nil
}

// isDenied reports whether filePath has an explicit deny entry.
func (s *Store) isDenied(filePath string) (bool, error) {
	_, err := os.Stat(s.denyPath(filePath))
	if err == nil {
		return true, nil
	}
	if os.IsNotExist(err) {
		return false, nil
	}
	return false, err
}

// denyPath returns the path of the deny marker for a config file.
func (s *Store) denyPath(filePath string) string {
	return filepath.Join(s.root, "deny", pathHash(filePath)+".json")
}

// Deny adds a deny entry for the file at filePath.
func (s *Store) Deny(filePath string) error {
	denyPath := s.denyPath(filePath)
	if err := os.MkdirAll(filepath.Dir(denyPath), 0o700); err != nil {
		return err
	}
	return os.WriteFile(denyPath, []byte(filePath+"\n"), 0o600)
}

// Undeny removes an explicit deny for a file. Trusting a file implies
// clearing any deny on it, so `envee trust` calls this.
func (s *Store) Undeny(filePath string) error {
	err := os.Remove(s.denyPath(filePath))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
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

// List returns every entry in the store, ordered by trust time (newest
// first). A store directory that does not exist yet is not an error -- it
// simply means nothing has been trusted.
func (s *Store) List() ([]Entry, error) {
	dir, err := os.ReadDir(s.root)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read trust store %s: %w", s.root, err)
	}

	var out []Entry
	for _, f := range dir {
		if f.IsDir() || filepath.Ext(f.Name()) != ".json" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(s.root, f.Name()))
		if err != nil {
			return nil, fmt.Errorf("read trust entry %s: %w", f.Name(), err)
		}
		var e Entry
		if err := json.Unmarshal(data, &e); err != nil {
			return nil, fmt.Errorf("parse trust entry %s: %w", f.Name(), err)
		}
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].TrustedAt.After(out[j].TrustedAt) })
	return out, nil
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
	// If we don't reach the successful rename, remove the temp file.
	// Close errors here are best-effort cleanup.
	defer func() {
		_ = os.Remove(tmpPath)
	}()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
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
