package errs

import (
	"fmt"
	"io"
	"strings"
)

// Multi is a collection of errors collected during a single operation.
//
// Print emits each error on its own line with a header summarizing the count.
type Multi struct {
	Errors []*Error
}

// Add appends an error to the collection.
func (m *Multi) Add(e *Error) {
	if e == nil {
		return
	}
	m.Errors = append(m.Errors, e)
}

// Any reports whether at least one error has been added.
func (m *Multi) Any() bool {
	return len(m.Errors) > 0
}

// Error implements the error interface and joins all sub-errors.
func (m *Multi) Error() string {
	if len(m.Errors) == 0 {
		return ""
	}
	parts := make([]string, 0, len(m.Errors))
	for _, e := range m.Errors {
		parts = append(parts, e.Error())
	}
	return strings.Join(parts, "\n")
}

// Print writes a summarized form to the given writer.
func (m *Multi) Print(w io.Writer) {
	if len(m.Errors) == 0 {
		return
	}
	if len(m.Errors) == 1 {
		m.Errors[0].Print(w)
		return
	}
	fmt.Fprintf(w, "[envee] %d issues found:\n", len(m.Errors))
	for i, e := range m.Errors {
		fmt.Fprintf(w, "  %d. %s\n", i+1, e.Error())
	}
}
