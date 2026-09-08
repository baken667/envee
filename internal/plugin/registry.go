// Package plugin implements the envee plugin discovery and execution layer.
//
// Plugins are external executables named envee-plugin-<name>. They communicate
// with envee via JSON over stdin/stdout. See docs/adr/0007-plugin-protocol.md.
package plugin

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Plugin is an interface representing a discovered secret/tool provider.
type Plugin interface {
	// Name returns the plugin's short name (e.g., "op").
	Name() string
	// Metadata returns the cached metadata for this plugin.
	Metadata() Metadata
	// Resolve runs the plugin's resolve subcommand and returns the result.
	Resolve(ctx context.Context, req Request) (Response, error)
}

// Metadata is the JSON returned by `envee-plugin-X metadata`.
type Metadata struct {
	Name         string   `json:"name"`
	Version      string   `json:"version"`
	APIVersion   int      `json:"api_version"`
	Description  string   `json:"description"`
	Capabilities []string `json:"capabilities"`
	Permissions  struct {
		Network    bool     `json:"network"`
		Filesystem []string `json:"filesystem"`
		Exec       []string `json:"exec"`
	} `json:"permissions"`
}

// Request is the JSON body sent to a plugin's resolve subcommand.
type Request struct {
	APIVersion int            `json:"api_version"`
	RequestID  string         `json:"request_id"`
	Spec       map[string]any `json:"spec"`
	Context    ReqContext     `json:"context"`
}

// ReqContext is the context block of a Request.
type ReqContext struct {
	ConfigRoot string            `json:"config_root"`
	Cwd        string            `json:"cwd"`
	Profile    string            `json:"profile"`
	Env        map[string]string `json:"env"`
}

// Response is the JSON body returned by a plugin's resolve subcommand.
type Response struct {
	APIVersion int            `json:"api_version"`
	RequestID  string         `json:"request_id"`
	Status     string         `json:"status"`
	Value      *Value         `json:"value,omitempty"`
	Metadata   *RespMetadata  `json:"metadata,omitempty"`
	Error      *PluginError   `json:"error,omitempty"`
}

// Value is the resolved value from a plugin.
type Value struct {
	Type  string `json:"type"`  // "string" | "int" | "bool" | "json"
	Value any    `json:"value"`
}

// RespMetadata describes the resolved value.
type RespMetadata struct {
	ResolvedAt time.Time `json:"resolved_at"`
	TTLSeconds int       `json:"ttl_seconds"`
	Source     string    `json:"source"`
}

// PluginError represents an error response from a plugin.
type PluginError struct {
	Code       string `json:"code"`
	Message    string `json:"message"`
	Recoverable bool  `json:"recoverable"`
}

// Registry holds the set of discovered plugins.
type Registry struct {
	mu      sync.RWMutex
	plugins map[string]Plugin
}

// NewRegistry returns an empty Registry.
func NewRegistry() *Registry {
	return &Registry{plugins: make(map[string]Plugin)}
}

// Discover searches for plugins in PATH and $XDG_DATA_HOME/envee/plugins/.
//
// Each candidate is a binary named envee-plugin-<name>. Successful metadata
// fetches register the plugin in the registry.
func (r *Registry) Discover(ctx context.Context) error {
	// PATH-based discovery
	if path, err := exec.LookPath("envee-plugin-op"); err == nil {
		// Smoke-test discovery for known plugin names.
		_ = path
	}

	// Walk PATH for envee-plugin-*
	pathDirs := filepath.SplitList(os.Getenv("PATH"))
	for _, dir := range pathDirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			name := e.Name()
			if !strings.HasPrefix(name, "envee-plugin-") {
				continue
			}
			pluginName := strings.TrimPrefix(name, "envee-plugin-")
			if e.IsDir() {
				continue
			}
			// Check executable bit
			info, err := e.Info()
			if err != nil {
				continue
			}
			if info.Mode()&0o111 == 0 {
				continue
			}
			fullPath := filepath.Join(dir, name)
			p := &execPlugin{name: pluginName, path: fullPath}
			if md, err := p.fetchMetadata(ctx); err == nil {
				p.metadata = *md
				r.mu.Lock()
				r.plugins[pluginName] = p
				r.mu.Unlock()
			}
		}
	}
	return nil
}

// Get returns the plugin with the given name, or nil if not found.
func (r *Registry) Get(name string) Plugin {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.plugins[name]
}

// List returns the names of all discovered plugins.
func (r *Registry) List() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	names := make([]string, 0, len(r.plugins))
	for n := range r.plugins {
		names = append(names, n)
	}
	return names
}

// execPlugin is the default implementation backed by an external binary.
type execPlugin struct {
	name     string
	path     string
	metadata Metadata
}

func (p *execPlugin) Name() string     { return p.name }
func (p *execPlugin) Metadata() Metadata { return p.metadata }

// fetchMetadata invokes `envee-plugin-X metadata` and parses the JSON output.
func (p *execPlugin) fetchMetadata(ctx context.Context) (*Metadata, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, p.path, "metadata")
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	var md Metadata
	if err := json.Unmarshal(out, &md); err != nil {
		return nil, err
	}
	return &md, nil
}

// Resolve invokes the plugin with the resolve subcommand.
func (p *execPlugin) Resolve(ctx context.Context, req Request) (Response, error) {
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
	}

	body, err := json.Marshal(req)
	if err != nil {
		return Response{}, err
	}

	cmd := exec.CommandContext(ctx, p.path, "resolve")
	cmd.Stdin = bytesReader(body)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return Response{}, err
	}

	var resp Response
	if err := json.Unmarshal(out, &resp); err != nil {
		return Response{}, err
	}
	return resp, nil
}

// bytesReader returns an io.Reader for the given bytes.
func bytesReader(b []byte) io.Reader {
	return &bytesReaderImpl{b: b}
}

type bytesReaderImpl struct {
	b []byte
	i int
}

func (r *bytesReaderImpl) Read(p []byte) (int, error) {
	if r.i >= len(r.b) {
		return 0, io.EOF
	}
	n := copy(p, r.b[r.i:])
	r.i += n
	return n, nil
}

// scanStderr captures and logs stderr output from a plugin process.
//
// Reserved for future use; currently we forward stderr directly.
func scanStderr(rdr io.Reader) {
	s := bufio.NewScanner(rdr)
	for s.Scan() {
		fmt.Fprintln(os.Stderr, "[plugin]", s.Text())
	}
}
