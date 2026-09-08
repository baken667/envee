// Package version exposes the envee version string.
//
// Variables are populated via -ldflags at build time:
//
//	-X github.com/baken667/envee/internal/version.Version=$(VERSION)
//	-X github.com/baken667/envee/internal/version.Commit=$(COMMIT)
//	-X github.com/baken667/envee/internal/version.Date=$(DATE)
package version

// Version is the semver of the build (e.g. "0.5.0").
var Version = "0.0.0-dev"

// Commit is the git commit hash the binary was built from.
var Commit = "unknown"

// Date is the RFC3339 build timestamp.
var Date = "unknown"

// GoVersion is the Go toolchain version used to build the binary.
var GoVersion = "unknown"
