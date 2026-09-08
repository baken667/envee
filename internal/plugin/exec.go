// plugin/exec.go — the actual plugin invocation layer.
//
// ExecPlugin invokes an external `envee-plugin-<name>` binary.
package plugin

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ExecPlugin is the default implementation that calls an external binary.
type ExecPlugin struct {
	Name     string
	Path     string // absolute path to the binary
	Metadata Metadata
}

// NewExecPlugin finds an envee-plugin-<name> binary in PATH and returns
// a wrapper, or nil if not found.
func NewExecPlugin(name string) (*ExecPlugin, error) {
	binName := "envee-plugin-" + name
	path, err := exec.LookPath(binName)
	if err != nil {
		return nil, fmt.Errorf("plugin %q not found in PATH (looked for %q)", name, binName)
	}
	return &ExecPlugin{
		Name: name,
		Path: path,
	}, nil
}

// FetchMetadata runs `envee-plugin-X metadata` and parses the response.
func (p *ExecPlugin) FetchMetadata(ctx context.Context) (Metadata, error) {
	if p.Metadata.Name != "" {
		return p.Metadata, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, p.Path, "metadata")
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return Metadata{}, fmt.Errorf("metadata: %w", err)
	}
	var md Metadata
	if err := json.Unmarshal(out, &md); err != nil {
		return Metadata{}, fmt.Errorf("parse metadata: %w", err)
	}
	p.Metadata = md
	return md, nil
}

// ResolveSecret runs `envee-plugin-X resolve` with the given ref and
// returns the resolved value as a string.
func (p *ExecPlugin) ResolveSecret(ctx context.Context, source, ref string) (string, error) {
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
	}

	req := Request{
		APIVersion: 1,
		RequestID:  fmt.Sprintf("req-%d", time.Now().UnixNano()),
		Spec:       map[string]any{"ref": ref},
		Context: ReqContext{
			ConfigRoot: os.Getenv("ENVEE_CONFIG_ROOT"),
			Cwd:        os.Getenv("ENVEE_CWD"),
			Profile:    os.Getenv("ENVEE_PROFILE"),
			Env:        osEnvSlice(),
		},
	}
	body, err := json.Marshal(req)
	if err != nil {
		return "", err
	}

	cmd := exec.CommandContext(ctx, p.Path, "resolve")
	cmd.Stdin = bytes.NewReader(body)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		// Try to parse error response from stdout.
		var resp Response
		if jsonErr := json.Unmarshal(out, &resp); jsonErr == nil && resp.Error != nil {
			return "", fmt.Errorf("%s: %s", resp.Error.Code, resp.Error.Message)
		}
		return "", fmt.Errorf("plugin %s: %w", p.Name, err)
	}
	_ = source // (unused)
	var resp Response
	if err := json.Unmarshal(out, &resp); err != nil {
		return "", fmt.Errorf("parse resolve response: %w", err)
	}
	if resp.Status != "ok" {
		if resp.Error != nil {
			return "", fmt.Errorf("%s: %s", resp.Error.Code, resp.Error.Message)
		}
		return "", fmt.Errorf("plugin returned non-ok status: %s", resp.Status)
	}
	if resp.Value == nil {
		return "", nil
	}
	switch v := resp.Value.Value.(type) {
	case string:
		return v, nil
	case float64:
		return fmt.Sprintf("%g", v), nil
	case bool:
		return fmt.Sprintf("%t", v), nil
	default:
		// JSON-encode other types.
		b, _ := json.Marshal(v)
		return string(b), nil
	}
}

// ResolveScript is for plugin execution of scripts (Phase 3 placeholder).
func (p *ExecPlugin) ResolveScript(ctx context.Context, source string, spec map[string]any) (map[string]string, []string, error) {
	return nil, nil, fmt.Errorf("script resolution not implemented yet (T3.6)")
}

// osEnvSlice returns the current process env as a map[string]string.
func osEnvSlice() map[string]string {
	out := make(map[string]string)
	for _, kv := range os.Environ() {
		for i := 0; i < len(kv); i++ {
			if kv[i] == '=' {
				out[kv[:i]] = kv[i+1:]
				break
			}
		}
	}
	return out
}

// ExeName returns the conventional binary name for this plugin.
func ExeName(source string) string {
	if strings.HasPrefix(source, "envee-plugin-") {
		return source
	}
	return "envee-plugin-" + source
}

// discoverFromPath walks PATH and finds any envee-plugin-* binaries.
// DiscoverPaths returns the absolute paths of every executable named
// envee-plugin-* on $PATH, without running any of them.
func DiscoverPaths() []string { return discoverFromPath() }

// PluginName extracts "foo" from "/path/to/envee-plugin-foo".
func PluginName(path string) string { return pluginNameFromPath(path) }

func discoverFromPath() []string {
	var found []string
	pathDirs := filepath.SplitList(os.Getenv("PATH"))
	for _, dir := range pathDirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			name := e.Name()
			if !strings.HasPrefix(name, "envee-plugin-") {
				continue
			}
			info, err := e.Info()
			if err != nil {
				continue
			}
			if info.Mode()&0o111 == 0 {
				continue
			}
			found = append(found, filepath.Join(dir, name))
		}
	}
	return found
}
