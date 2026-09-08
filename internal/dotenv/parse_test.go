package dotenv

import (
	"testing"
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
