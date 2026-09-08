package sdkgo_test

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	sdkgo "github.com/baken667/envee/pkg/sdk-go"
)

var demoBin string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "envee-sdk-test-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir)

	demoBin = filepath.Join(dir, "demoplugin")
	if runtime.GOOS == "windows" {
		demoBin += ".exe"
	}
	build := exec.Command("go", "build", "-o", demoBin, "./testdata/demoplugin")
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		panic("building the demo plugin failed: " + err.Error())
	}
	os.Exit(m.Run())
}

// runDemo invokes the demo plugin the way envee does and returns stdout.
func runDemo(t *testing.T, mode string, args []string, stdin string) (string, error) {
	t.Helper()
	cmd := exec.Command(demoBin, args...)
	cmd.Stdin = strings.NewReader(stdin)
	cmd.Env = append(os.Environ(), "DEMO_MODE="+mode)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = os.Stderr
	err := cmd.Run()
	return out.String(), err
}

func requestJSON(t *testing.T, apiVersion int, ref string) string {
	t.Helper()
	req := sdkgo.Request{
		APIVersion: apiVersion,
		RequestID:  "req-1",
		Spec:       map[string]any{"ref": ref},
	}
	b, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestRunMetadata(t *testing.T) {
	out, err := runDemo(t, "", []string{"metadata"}, "")
	if err != nil {
		t.Fatal(err)
	}
	var md sdkgo.Metadata
	if err := json.Unmarshal([]byte(out), &md); err != nil {
		t.Fatalf("metadata is not valid JSON: %v (%q)", err, out)
	}
	if md.Name != "demo" || md.Version != "1.2.3" || md.APIVersion != sdkgo.APIVersion {
		t.Errorf("unexpected metadata: %+v", md)
	}
}

func TestRunResolve(t *testing.T) {
	out, err := runDemo(t, "", []string{"resolve"}, requestJSON(t, sdkgo.APIVersion, "db/password"))
	if err != nil {
		t.Fatal(err)
	}
	var resp sdkgo.Response
	if err := json.Unmarshal([]byte(out), &resp); err != nil {
		t.Fatalf("response is not valid JSON: %v (%q)", err, out)
	}
	if resp.Status != "ok" {
		t.Fatalf("status = %q", resp.Status)
	}
	// Run must echo the request id back so a caller can correlate responses.
	if resp.RequestID != "req-1" {
		t.Errorf("request_id = %q, want req-1", resp.RequestID)
	}
	if resp.APIVersion != sdkgo.APIVersion {
		t.Errorf("api_version = %d", resp.APIVersion)
	}
	if resp.Value == nil || resp.Value.Value != "value-for-db/password" {
		t.Errorf("value = %+v", resp.Value)
	}
	// Run fills in a default TTL so plugins need not think about caching.
	if resp.Metadata == nil || resp.Metadata.TTLSeconds <= 0 {
		t.Errorf("expected default response metadata, got %+v", resp.Metadata)
	}
}

func TestRunRejectsVersionMismatch(t *testing.T) {
	out, err := runDemo(t, "", []string{"resolve"}, requestJSON(t, 99, "x"))
	if err == nil {
		t.Error("a version mismatch should exit non-zero")
	}
	var resp sdkgo.Response
	if jsonErr := json.Unmarshal([]byte(out), &resp); jsonErr != nil {
		t.Fatalf("expected a structured error on stdout, got %q", out)
	}
	if resp.Status != "error" || resp.Error == nil || resp.Error.Code != "version_mismatch" {
		t.Errorf("unexpected response: %+v", resp)
	}
}

func TestRunRejectsMalformedRequest(t *testing.T) {
	out, err := runDemo(t, "", []string{"resolve"}, "{not json")
	if err == nil {
		t.Error("a malformed request should exit non-zero")
	}
	var resp sdkgo.Response
	if jsonErr := json.Unmarshal([]byte(out), &resp); jsonErr != nil {
		t.Fatalf("expected a structured error on stdout, got %q", out)
	}
	if resp.Error == nil || resp.Error.Code != "invalid_request" {
		t.Errorf("unexpected response: %+v", resp)
	}
}

// A *PluginError from Resolve must reach the caller with its code intact;
// anything else is reported as an internal error.
func TestRunPropagatesPluginError(t *testing.T) {
	out, _ := runDemo(t, "plugin_error", []string{"resolve"}, requestJSON(t, sdkgo.APIVersion, "missing"))
	var resp sdkgo.Response
	if err := json.Unmarshal([]byte(out), &resp); err != nil {
		t.Fatalf("got %q", out)
	}
	if resp.Error == nil || resp.Error.Code != "E_NO_SUCH_SECRET" {
		t.Fatalf("plugin error code was lost: %+v", resp.Error)
	}
	if !strings.Contains(resp.Error.Message, "missing") {
		t.Errorf("plugin error message was lost: %q", resp.Error.Message)
	}
}

func TestRunWrapsPlainError(t *testing.T) {
	out, _ := runDemo(t, "plain_error", []string{"resolve"}, requestJSON(t, sdkgo.APIVersion, "x"))
	var resp sdkgo.Response
	if err := json.Unmarshal([]byte(out), &resp); err != nil {
		t.Fatalf("got %q", out)
	}
	if resp.Error == nil || resp.Error.Code != "internal" {
		t.Errorf("expected an internal error, got %+v", resp.Error)
	}
}

func TestRunUnknownSubcommand(t *testing.T) {
	if _, err := runDemo(t, "", []string{"frobnicate"}, ""); err == nil {
		t.Error("an unknown subcommand should exit non-zero")
	}
}

func TestRunNoSubcommand(t *testing.T) {
	if _, err := runDemo(t, "", nil, ""); err == nil {
		t.Error("no subcommand should exit non-zero")
	}
}

// --- pure constructors -------------------------------------------------------

func TestOkResponse(t *testing.T) {
	r := sdkgo.OkResponse("hello")
	if r.Status != "ok" || r.Value == nil || r.Value.Type != "string" || r.Value.Value != "hello" {
		t.Errorf("got %+v", r)
	}
}

func TestOkResponseTTL(t *testing.T) {
	r := sdkgo.OkResponseTTL("hello", 90*time.Second)
	if r.Metadata == nil || r.Metadata.TTLSeconds != 90 {
		t.Errorf("got %+v", r.Metadata)
	}
}

func TestPluginErrorImplementsError(t *testing.T) {
	var err error = sdkgo.NewError("E_X", "boom", true)
	if err.Error() != "boom" {
		t.Errorf("Error() = %q", err.Error())
	}
}
