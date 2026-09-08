package dotenv

import (
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestParseBasic(t *testing.T) {
	src := `
KEY1=value1
KEY2=value2
KEY3=value with spaces
`
	got, err := Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	if got["KEY1"] != "value1" {
		t.Errorf("KEY1 = %q", got["KEY1"])
	}
	if got["KEY2"] != "value2" {
		t.Errorf("KEY2 = %q", got["KEY2"])
	}
	if got["KEY3"] != "value with spaces" {
		t.Errorf("KEY3 = %q", got["KEY3"])
	}
}

func TestParseExportPrefix(t *testing.T) {
	src := `export FOO=bar`
	got, err := Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	if got["FOO"] != "bar" {
		t.Errorf("FOO = %q, want bar", got["FOO"])
	}
}

func TestParseQuotedValues(t *testing.T) {
	src := `
SINGLE='single value'
DOUBLE="double value"
EMPTY=
`
	got, err := Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	if got["SINGLE"] != "single value" {
		t.Errorf("SINGLE = %q", got["SINGLE"])
	}
	if got["DOUBLE"] != "double value" {
		t.Errorf("DOUBLE = %q", got["DOUBLE"])
	}
	if v, ok := got["EMPTY"]; !ok || v != "" {
		t.Errorf("EMPTY = %q (ok=%v), want empty", v, ok)
	}
}

func TestParseComments(t *testing.T) {
	src := `
# This is a comment
KEY1=value1  # inline comment
# Another comment
KEY2=value2
`
	got, err := Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	if got["KEY1"] != "value1" {
		t.Errorf("KEY1 = %q", got["KEY1"])
	}
	if got["KEY2"] != "value2" {
		t.Errorf("KEY2 = %q", got["KEY2"])
	}
	if len(got) != 2 {
		t.Errorf("expected 2 keys, got %d: %v", len(got), got)
	}
}

func TestParseMultiline(t *testing.T) {
	src := `MULTI="line1
line2
line3"
KEY=after
`
	got, err := Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	want := "line1\nline2\nline3"
	if got["MULTI"] != want {
		t.Errorf("MULTI = %q, want %q", got["MULTI"], want)
	}
	if got["KEY"] != "after" {
		t.Errorf("KEY = %q", got["KEY"])
	}
}

func TestParseEqualsInValue(t *testing.T) {
	src := `URL="postgres://user:pass@host:5432/db?sslmode=require"`
	got, err := Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	if got["URL"] != "postgres://user:pass@host:5432/db?sslmode=require" {
		t.Errorf("URL = %q", got["URL"])
	}
}

func TestParseDottedKeys(t *testing.T) {
	src := `app.name = "myapp"
app.version = "1.0.0"
`
	got, err := Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	if got["app.name"] != "myapp" {
		t.Errorf("app.name = %q", got["app.name"])
	}
}

func TestParseWithExpansion(t *testing.T) {
	t.Setenv("TEST_HOME", "/home/test")
	src := `PATH_EXPANDED="$TEST_HOME/bin"`
	got, err := ParseWithExpansion(src)
	if err != nil {
		t.Fatal(err)
	}
	if got["PATH_EXPANDED"] != "/home/test/bin" {
		t.Errorf("PATH_EXPANDED = %q, want /home/test/bin", got["PATH_EXPANDED"])
	}
}

func TestAsExport(t *testing.T) {
	m := map[string]string{
		"B": "2",
		"A": "1",
	}
	out := AsExport(m)
	// Order is non-deterministic (map iteration), so just check both are present.
	if len(out) < len("A=1\n")+len("B=2\n") {
		t.Errorf("AsExport output too short: %q", out)
	}
}

// A .env file checked out on Windows has CRLF line endings. The parser only
// treats '\n' as a terminator, so before normalisation every value kept a
// trailing carriage return and each blank line produced a variable named
// "\r". Caught by the windows-latest CI job.
func TestParseCRLF(t *testing.T) {
	input := "# comment\r\n" +
		"LOG_FORMAT=json\r\n" +
		"\r\n" +
		"LOG_LEVEL = info\r\n" +
		"export QUOTED=\"has spaces\"\r\n" +
		"SINGLE='single quoted'\r\n"

	got, err := Parse(input)
	if err != nil {
		t.Fatal(err)
	}

	want := map[string]string{
		"LOG_FORMAT": "json",
		"LOG_LEVEL":  "info",
		"QUOTED":     "has spaces",
		"SINGLE":     "single quoted",
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
	if len(got) != len(want) {
		t.Errorf("got %d keys, want %d: %#v", len(got), len(want), got)
	}
	for k := range got {
		if strings.ContainsAny(k, "\r\n") {
			t.Errorf("key %q contains a line terminator", k)
		}
	}
}

// CRLF and LF files must parse identically.
func TestParseCRLFMatchesLF(t *testing.T) {
	lf := "A=1\nB=two words\nC=\"quoted\"\n"
	crlf := strings.ReplaceAll(lf, "\n", "\r\n")

	gotLF, err := Parse(lf)
	if err != nil {
		t.Fatal(err)
	}
	gotCRLF, err := Parse(crlf)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(gotLF, gotCRLF) {
		t.Errorf("CRLF and LF disagree:\n  LF:   %#v\n  CRLF: %#v", gotLF, gotCRLF)
	}
}

// The \r ESCAPE inside a double-quoted value is a different thing from a
// literal carriage return in the file, and must still work.
func TestParseCarriageReturnEscapeSurvives(t *testing.T) {
	got, err := Parse(`A="line1\r\nline2"` + "\n")
	if err != nil {
		t.Fatal(err)
	}
	if got["A"] != "line1\r\nline2" {
		t.Errorf("A = %q, want %q", got["A"], "line1\r\nline2")
	}
}

// `export` on any line other than the first used to send the scanner
// backwards and loop forever, hanging the shell hook on every prompt. The
// offset after "export" was a literal 6 instead of i+6.
func TestParseExportNotOnFirstLine(t *testing.T) {
	done := make(chan struct{})
	var got map[string]string
	var err error

	go func() {
		defer close(done)
		got, err = Parse("FIRST=1\nexport SECOND=2\nTHIRD=3\nexport   FOURTH=4\n")
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("parse did not terminate: the export prefix scan is looping")
	}

	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"FIRST": "1", "SECOND": "2", "THIRD": "3", "FOURTH": "4"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %#v, want %#v", got, want)
	}
}

func TestParseExportEdgeCases(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  map[string]string
	}{
		{"leading export", "export A=1\n", map[string]string{"A": "1"}},
		{"tab after export", "B=0\nexport\tA=1\n", map[string]string{"B": "0", "A": "1"}},
		{"exported word is not a prefix", "exportable=1\n", map[string]string{"exportable": "1"}},
		{"export as a value", "A=export\n", map[string]string{"A": "export"}},
		{"consecutive exports", "export A=1\nexport B=2\n", map[string]string{"A": "1", "B": "2"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			done := make(chan struct{})
			var got map[string]string
			var err error
			go func() {
				defer close(done)
				got, err = Parse(tc.input)
			}()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("parse did not terminate")
			}
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("got %#v, want %#v", got, tc.want)
			}
		})
	}
}
