// path.go — PATH directive helpers.
package directive

import (
	"path/filepath"
	"strings"
)

// DeduplicatePath removes duplicates from a path list while preserving order.
func DeduplicatePath(dirs []string) []string {
	seen := make(map[string]bool, len(dirs))
	out := make([]string, 0, len(dirs))
	for _, d := range dirs {
		// Resolve symlinks for dedup purposes.
		abs, err := filepath.EvalSymlinks(d)
		if err != nil {
			abs = d
		}
		if !seen[abs] {
			seen[abs] = true
			out = append(out, d)
		}
	}
	return out
}

// PrependToPath adds dirs to the front of a $PATH-style string.
// Removes duplicates and any existing occurrences of the same dir.
//
// Returns the new PATH value.
func PrependToPath(dirs []string, currentPath string) string {
	currentList := filepath.SplitList(currentPath)

	// Build set of existing dirs (resolved) for fast lookup.
	existing := make(map[string]bool, len(currentList))
	for _, d := range currentList {
		abs, err := filepath.EvalSymlinks(d)
		if err != nil {
			abs = d
		}
		existing[abs] = true
	}

	// Prepend new dirs, skipping ones already in PATH.
	var result []string
	for _, d := range dirs {
		abs, err := filepath.EvalSymlinks(d)
		if err != nil {
			abs = d
		}
		if existing[abs] {
			continue
		}
		result = append(result, d)
		existing[abs] = true // prevent within-list dups
	}
	result = append(result, currentList...)

	return strings.Join(result, string(filepath.ListSeparator))
}
