// trust/prompt.go — interactive trust prompt.
package trust

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"
)

// Response is the user's response to a trust prompt.
type Response int

const (
	ResponseGrant Response = iota
	ResponseDeny
	ResponseShowDiff
	ResponseSkip
	ResponseQuit
	ResponseError
)

// String returns a human-readable label.
func (r Response) String() string {
	switch r {
	case ResponseGrant:
		return "grant"
	case ResponseDeny:
		return "deny"
	case ResponseShowDiff:
		return "show-diff"
	case ResponseSkip:
		return "skip"
	case ResponseQuit:
		return "quit"
	}
	return "unknown"
}

// PromptOptions configures the trust prompt.
type PromptOptions struct {
	// Question is the prompt string (e.g., "Trust this file? [Y/n/d/s/q]").
	Question string

	// Default is the response to use when the user just hits Enter.
	// Defaults to ResponseGrant if zero.
	Default Response

	// Reader is the input source (default: os.Stdin).
	Reader io.Reader

	// Writer is the output destination for prompts (default: os.Stderr).
	Writer io.Writer

	// Yes auto-grants without prompting.
	Yes bool

	// NoTTY disables interactive mode and returns an error.
	NoTTY bool
}

// Prompt asks the user for a response.
//
// On EOF, returns ResponseQuit, nil (clean exit).
// On read error, returns ResponseError, err.
func Prompt(opts PromptOptions) (Response, error) {
	if opts.Yes {
		return ResponseGrant, nil
	}
	if opts.Reader == nil {
		opts.Reader = os.Stdin
	}
	if opts.Writer == nil {
		opts.Writer = os.Stderr
	}
	if opts.Default == 0 {
		opts.Default = ResponseGrant
	}

	if opts.NoTTY {
		// Non-interactive: only Yes flag works.
		return ResponseError, fmt.Errorf("non-interactive mode and no --yes")
	}

	fmt.Fprint(opts.Writer, opts.Question)
	scanner := bufio.NewScanner(opts.Reader)
	if !scanner.Scan() {
		if err := scanner.Err(); err != nil {
			return ResponseError, err
		}
		return ResponseQuit, nil // EOF
	}

	line := strings.ToLower(strings.TrimSpace(scanner.Text()))
	if line == "" {
		return opts.Default, nil
	}

	switch line {
	case "y", "yes":
		return ResponseGrant, nil
	case "n", "no":
		return ResponseDeny, nil
	case "d", "diff":
		return ResponseShowDiff, nil
	case "s", "skip":
		return ResponseSkip, nil
	case "q", "quit":
		return ResponseQuit, nil
	}
	// Unrecognized — treat as default.
	return opts.Default, nil
}
