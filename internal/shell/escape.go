// Shell-safe escaping for bash and POSIX sh.
//
// Based on direnv's BashEscape implementation (which is itself derived from
// https://github.com/solidsnack/shell-escape).
package shell

import (
	"fmt"
	"strings"
)

// BashEscape returns a string safe to use as a bash token (unquoted context).
//
// Strategy:
//   - Empty string → '' (literal empty).
//   - String contains only safe characters (alphanumeric, dot, slash, dash,
//     underscore, colon, equals, comma, plus) → return as-is.
//   - String contains control characters (newline, tab, etc.) or non-ASCII →
//     use ANSI-C $'...' quoting.
//   - Otherwise (contains shell metacharacters) → wrap in single quotes and
//     escape inner single quotes via the canonical '\'' sequence.
func BashEscape(s string) string {
	if s == "" {
		return "''"
	}

	// Detect control chars / non-ASCII.
	hasControl := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < 0x20 || c == 0x7f || c >= 0x80 {
			hasControl = true
			break
		}
	}
	if hasControl {
		return ansiCEscape(s)
	}

	// Detect shell metacharacters that need quoting.
	needsQuoting := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			continue
		}
		switch c {
		case '.', '/', '-', '_', ':', '=', ',', '+', '@', '%':
			continue
		}
		needsQuoting = true
		break
	}

	if !needsQuoting {
		return s
	}

	// Wrap in single quotes; replace inner ' with '\''.
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// DoubleQuoteEscape returns a string safe to use inside a bash
// double-quoted context (e.g., "export X=...").
//
// We escape \, $, `, ", and newline. Other characters are passed through
// since they're safe in double-quoted bash.
func DoubleQuoteEscape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '\\':
			b.WriteString(`\\`)
		case '$':
			b.WriteString(`\$`)
		case '`':
			b.WriteString("\\`")
		case '"':
			b.WriteString(`\"`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '!':
			// History expansion — escape to be safe in interactive shells.
			b.WriteString(`\!`)
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

// ANSI-C escape via $'...' — for control characters / non-ASCII bytes.
// Not exported for general use; reserved for future shell adapters that
// need literal control character round-trips.
func ansiCEscape(s string) string {
	if s == "" {
		return "''"
	}
	var b strings.Builder
	escape := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\n':
			b.WriteString(`\n`)
			escape = true
		case c == '\r':
			b.WriteString(`\r`)
			escape = true
		case c == '\t':
			b.WriteString(`\t`)
			escape = true
		case c < 0x20 || c == 0x7f:
			fmt.Fprintf(&b, `\x%02x`, c)
			escape = true
		case c >= 0x80:
			fmt.Fprintf(&b, `\x%02x`, c)
			escape = true
		default:
			b.WriteByte(c)
		}
	}
	if escape {
		return "$'" + b.String() + "'"
	}
	return b.String()
}

// SingleQuote wraps s in single quotes and escapes inner single quotes.
// Always returns a single-quoted string, even if s is empty.
func SingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
