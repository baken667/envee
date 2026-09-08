// Package dotenv implements parsing of the .env file format.
//
// Format reference: https://github.com/bkeepers/dotenv
//
// Supports:
//   - KEY=VALUE pairs
//   - export KEY=VALUE (export prefix is stripped)
//   - Single-quoted values (literal, no escape processing)
//   - Double-quoted values (with $VAR expansion if ExpandVars is true)
//   - Multi-line values inside quotes (line break preserved as \n)
//   - Comments starting with # (not inside quotes)
//   - Empty lines
//
// Implementation: hand-written state-machine scanner, one-pass.
// The direnv-style regex approach turned out to be too brittle.
package dotenv

import (
	"fmt"
	"os"
	"strings"
	"unicode"
)

// Parse reads .env content and returns a map of key=value pairs.
func Parse(data string) (map[string]string, error) {
	return parse(data, false)
}

// ParseWithExpansion reads .env content and expands $VAR references inside
// double-quoted values using the OS environment.
//
// Use this when `_.file` has `expand = true`.
func ParseWithExpansion(data string) (map[string]string, error) {
	return parse(data, true)
}

// ParseFile reads and parses a .env file from disk.
func ParseFile(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Parse(string(data))
}

// parse is the shared implementation.
//
// Algorithm: walk the input char by char, switching between states:
//   - stateKey: reading a key (until = or :).
//   - stateValue: reading a value (handling quotes, escapes, $).
//   - stateSkip: between statements (whitespace, comments).
type state int

const (
	stateStart state = iota
	stateKey
	stateBeforeValue
	stateValue
	stateQuotedSingle
	stateQuotedDouble
	stateEscape
	stateLineComment
	stateDone
)

func parse(data string, expand bool) (map[string]string, error) {
	out := make(map[string]string)

	var (
		st            = stateStart
		key           strings.Builder
		value         strings.Builder
		curLine       = 1
		statementLine = 1
	)

	flush := func() {
		if key.Len() > 0 {
			out[key.String()] = value.String()
			key.Reset()
			value.Reset()
		}
	}

	for i := 0; i < len(data); i++ {
		c := data[i]

		switch st {
		case stateStart, stateBeforeValue:
			// Skip leading whitespace on a line.
			if c == ' ' || c == '\t' {
				continue
			}
			// Comment to end of line.
			if c == '#' {
				st = stateLineComment
				continue
			}
			// Newline: just advance.
			if c == '\n' {
				curLine++
				if st == stateStart {
					continue
				}
				// We were in BeforeValue (key seen but no value) — treat as empty value.
				flush()
				st = stateStart
				continue
			}
			// Export prefix.
			if (st == stateStart) && i+6 < len(data) && data[i:i+6] == "export" &&
				(i+6 == len(data) || data[i+6] == ' ' || data[i+6] == '\t') {
				// Find first non-space char after "export".
				j := 6 // "export" is positions 0..5, so 6 is right after
				for j < len(data) && (data[j] == ' ' || data[j] == '\t') {
					j++
				}
				// Set i to land on j after the for-loop's i++.
				i = j - 1
				st = stateKey
				statementLine = curLine
				continue
			}
			// Anything else is the start of a key.
			st = stateKey
			statementLine = curLine
			key.WriteByte(c)

		case stateKey:
			if c == '=' || c == ':' {
				st = stateValue
				continue
			}
			if c == '\n' {
				// Key without value — treat as empty value.
				curLine++
				flush()
				st = stateStart
				continue
			}
			if c == '#' {
				flush()
				st = stateLineComment
				continue
			}
			// Keys allow letters, digits, underscore, dot.
			if isKeyChar(c) {
				key.WriteByte(c)
			}

		case stateValue:
			// Unquoted value: read until newline or comment.
			if c == '"' {
				st = stateQuotedDouble
				continue
			}
			if c == '\'' {
				st = stateQuotedSingle
				continue
			}
			if c == '\n' {
				curLine++
				flush()
				st = stateStart
				continue
			}
			if c == '#' {
				// Trailing whitespace before # — strip it.
				s := strings.TrimRight(value.String(), " \t")
				value.Reset()
				value.WriteString(s)
				flush()
				st = stateLineComment
				continue
			}
			// Strip surrounding whitespace from unquoted values.
			if c == ' ' || c == '\t' {
				if value.Len() == 0 {
					continue // skip leading whitespace
				}
				value.WriteByte(c)
				continue
			}
			value.WriteByte(c)

		case stateQuotedSingle:
			// Literal: no escapes, no $ expansion. Closing ' ends the value.
			if c == '\'' {
				st = stateValue
				continue
			}
			if c == '\n' {
				value.WriteByte('\n')
				curLine++
				continue
			}
			value.WriteByte(c)

		case stateQuotedDouble:
			if c == '"' {
				st = stateValue
				continue
			}
			if c == '\\' {
				st = stateEscape
				continue
			}
			if c == '$' && expand {
				// Read ${VAR} or $VAR.
				name, lit, n := readDollarRef(data[i:])
				if name != "" {
					envVal := os.Getenv(name)
					if envVal == "" {
						envVal = lit // default if ${VAR:-default}
					}
					value.WriteString(envVal)
					i += n - 1 // -1 because the for-loop also increments
					continue
				}
			}
			if c == '\n' {
				value.WriteByte('\n')
				curLine++
				continue
			}
			value.WriteByte(c)

		case stateEscape:
			// In double-quoted string after a backslash.
			switch c {
			case 'n':
				value.WriteByte('\n')
			case 'r':
				value.WriteByte('\r')
			case 't':
				value.WriteByte('\t')
			case '\\':
				value.WriteByte('\\')
			case '"':
				value.WriteByte('"')
			case '$':
				value.WriteByte('$')
			default:
				// Unknown escape: keep the char as-is.
				value.WriteByte('\\')
				value.WriteByte(c)
			}
			st = stateQuotedDouble

		case stateLineComment:
			if c == '\n' {
				curLine++
				st = stateStart
			}
		}
	}

	// Flush any pending key/value at EOF.
	switch st {
	case stateValue, stateQuotedDouble, stateQuotedSingle:
		flush()
	case stateKey:
		// KEY without value at EOF — treat as empty.
		flush()
	}

	// Validate that quoted strings were closed.
	if st == stateQuotedSingle {
		return nil, fmt.Errorf("dotenv: line %d: unterminated single-quoted string", statementLine)
	}
	if st == stateQuotedDouble {
		return nil, fmt.Errorf("dotenv: line %d: unterminated double-quoted string", statementLine)
	}

	return out, nil
}

// readDollarRef tries to read a ${VAR} or $VAR reference at the start of s.
// Returns the variable name, default literal (if any), and the number of bytes
// consumed. If no valid reference is found, returns "".
func readDollarRef(s string) (name, def string, n int) {
	if len(s) == 0 || s[0] != '$' {
		return "", "", 0
	}

	// ${VAR} or ${VAR:-default}
	if len(s) > 1 && s[1] == '{' {
		// Find closing }.
		end := strings.IndexByte(s[2:], '}')
		if end < 0 {
			return "", "", 0
		}
		body := s[2 : 2+end]
		// Check for :- default.
		if idx := strings.Index(body, ":-"); idx >= 0 {
			return body[:idx], body[idx+2:], 2 + end + 1
		}
		return body, "", 2 + end + 1
	}

	// $VAR (alphanumeric + underscore).
	i := 1
	for i < len(s) && (isAlphaNumeric(s[i]) || s[i] == '_') {
		i++
	}
	if i == 1 {
		return "", "", 0 // $ followed by non-identifier char
	}
	return s[1:i], "", i
}

func isAlphaNumeric(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// isKeyChar reports whether c is allowed in a key (letters, digits, underscore, dot).
func isKeyChar(c byte) bool {
	return isAlphaNumeric(c) || c == '.'
}

// AsExport renders a parsed map as KEY=VALUE lines.
func AsExport(m map[string]string) string {
	var b strings.Builder
	for k, v := range m {
		fmt.Fprintf(&b, "%s=%s\n", k, v)
	}
	return b.String()
}

// Unused but reserved.
var _ = unicode.IsSpace
