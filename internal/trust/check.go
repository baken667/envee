// trust/check.go — gate function for `envee eval`.
package trust

import "fmt"

// CheckFile verifies the trust status of a file with a given hash.
//
// Returns nil if trusted, error otherwise.
func (s *Store) CheckFile(filePath, hash string) error {
	st, err := s.Status(filePath, hash)
	if err != nil {
		return fmt.Errorf("trust check: %w", err)
	}
	switch st {
	case Trusted:
		return nil
	case Expired:
		return fmt.Errorf("trust expired for %s (hash %s) — run `envee trust` to renew", filePath, hash)
	case Denied:
		return fmt.Errorf("trust denied for %s — run `envee trust` to approve", filePath)
	case Unknown:
		fallthrough
	default:
		return fmt.Errorf("file %s (hash %s) is not trusted — run `envee trust` to approve", filePath, hash)
	}
}

// IsTrusted returns true if the file at the given path with the given hash
// is currently trusted.
func (s *Store) IsTrusted(filePath, hash string) bool {
	st, _ := s.Status(filePath, hash)
	return st == Trusted
}
