package cli

import "github.com/baken667/envee/internal/errs"

// notImplemented is returned by commands that exist in the CLI surface but
// have no implementation yet.
//
// They used to print a message and exit 0, which made scripts (and `make
// examples`, and the Homebrew formula's test block) pass vacuously. A command
// that did not do what it was asked must fail.
//
// Commands in this state are also marked Hidden so they stay out of --help and
// the generated man pages until they do something.
func notImplemented(what, hint string) error {
	e := errs.New("E014", what+" is not implemented yet").
		WithContext("status", "planned")
	if hint != "" {
		e = e.WithHint(hint)
	}
	return e
}
