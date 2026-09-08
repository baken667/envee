package cli

import "github.com/baken667/envee/internal/shell"

// shellAdapter returns a shell adapter for the given name, or nil.
func shellAdapter(name string) shell.Adapter {
	return shell.Detect(name)
}
