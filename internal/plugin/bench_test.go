package plugin

import (
	"os"
	"strings"
	"testing"
)

// DiscoverPaths walks every directory in $PATH looking for envee-plugin-*.
// eval calls it on every prompt regardless of whether the config declares any
// secrets, so this is paid by every shell prompt for nothing in the common
// case.
//
// Benchmarked against the real $PATH, since its length is exactly the cost
// driver and a synthetic one would understate it.
func BenchmarkDiscoverPathsRealPATH(b *testing.B) {
	dirs := len(strings.Split(os.Getenv("PATH"), ":"))
	b.ReportMetric(float64(dirs), "PATH_dirs")
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		DiscoverPaths()
	}
}

// For a stable, machine-independent number: a $PATH of a known size where no
// directory contains a plugin.
func BenchmarkDiscoverPathsSynthetic(b *testing.B) {
	root := b.TempDir()
	var dirs []string
	for i := 0; i < 20; i++ {
		d := root + "/dir" + string(rune('a'+i))
		if err := os.MkdirAll(d, 0o755); err != nil {
			b.Fatal(err)
		}
		// A handful of unrelated files, as a real bin directory would have.
		for j := 0; j < 20; j++ {
			_ = os.WriteFile(d+"/tool"+string(rune('a'+j)), []byte("#!/bin/sh\n"), 0o755)
		}
		dirs = append(dirs, d)
	}
	b.Setenv("PATH", strings.Join(dirs, ":"))

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		DiscoverPaths()
	}
}
