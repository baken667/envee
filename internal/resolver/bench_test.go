package resolver

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// buildTree creates depth nested directories, each holding an envee.toml, and
// returns the deepest one. It models the real cost driver: Discover stats
// several candidate filenames per level all the way up to the filesystem root.
func buildTree(b *testing.B, depth int) string {
	b.Helper()
	root := b.TempDir()
	dir := root
	for i := 0; i < depth; i++ {
		dir = filepath.Join(dir, fmt.Sprintf("level%d", i))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			b.Fatal(err)
		}
		body := fmt.Sprintf("schema = \"envee/v1\"\n\n[env]\nLEVEL%d = \"value%d\"\n", i, i)
		if err := os.WriteFile(filepath.Join(dir, "envee.toml"), []byte(body), 0o644); err != nil {
			b.Fatal(err)
		}
	}
	return dir
}

// Discover is the filesystem walk: per level it stats up to four candidate
// names and reads envee.d/. Everything else in eval is cheap by comparison.
func BenchmarkDiscover(b *testing.B) {
	for _, depth := range []int{1, 5, 10} {
		b.Run(fmt.Sprintf("depth%d", depth), func(b *testing.B) {
			cwd := buildTree(b, depth)
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				r, err := New(cwd)
				if err != nil {
					b.Fatal(err)
				}
				if _, err := r.Discover(); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

// LoadAll adds a TOML parse and a sha256 canonical hash per discovered file.
func BenchmarkLoadAll(b *testing.B) {
	for _, depth := range []int{1, 5, 10} {
		b.Run(fmt.Sprintf("depth%d", depth), func(b *testing.B) {
			cwd := buildTree(b, depth)
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				r, err := New(cwd)
				if err != nil {
					b.Fatal(err)
				}
				if _, err := r.LoadAll(); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

// The common case in most directories is that there is no config at all: the
// walk still stats its way to the filesystem root and finds nothing.
func BenchmarkDiscoverNoConfig(b *testing.B) {
	cwd := b.TempDir()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r, err := New(cwd)
		if err != nil {
			b.Fatal(err)
		}
		if _, err := r.Discover(); err != nil {
			b.Fatal(err)
		}
	}
}
