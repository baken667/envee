// plugin/dispatcher.go — multi-source resolver.
//
// The Dispatcher is what directive.Apply consumes. It looks up the right
// plugin for each `_.secret.<NAME>` directive based on its `source` field.
package plugin

import (
	"context"
	"sync"
)

// SecretResolver is a minimal interface for plugins that resolve secrets.
// We use this instead of the full Plugin interface so that mocks in tests
// are easy to write.
type SecretResolver interface {
	ResolveSecret(ctx context.Context, source, ref string) (string, error)
}

// Dispatcher resolves secrets by looking up the right plugin for each source.
type Dispatcher struct {
	mu      sync.RWMutex
	plugins map[string]SecretResolver
}

// NewDispatcher creates a Dispatcher with the given plugins, keyed by source.
func NewDispatcher(plugins map[string]SecretResolver) *Dispatcher {
	return &Dispatcher{plugins: plugins}
}

// ResolveSecret dispatches to the plugin for the given source.
func (d *Dispatcher) ResolveSecret(ctx context.Context, source, ref string) (string, error) {
	d.mu.RLock()
	p, ok := d.plugins[source]
	d.mu.RUnlock()
	if !ok {
		return "", &PluginLookupError{Source: source}
	}
	return p.ResolveSecret(ctx, source, ref)
}

// PluginLookupError is returned when a plugin for the requested source is not registered.
type PluginLookupError struct {
	Source string
}

func (e *PluginLookupError) Error() string {
	return "plugin not found for source: " + e.Source
}

// DiscoverAndLoad scans PATH for envee-plugin-* binaries and creates a Dispatcher.
func DiscoverAndLoad(ctx context.Context) (*Dispatcher, error) {
	binaries := discoverFromPath()
	plugins := make(map[string]SecretResolver, len(binaries))
	for _, bin := range binaries {
		name := pluginNameFromPath(bin)
		if name == "" {
			continue
		}
		p, err := NewExecPlugin(name)
		if err != nil {
			continue
		}
		if _, err := p.FetchMetadata(ctx); err != nil {
			continue
		}
		plugins[name] = p
	}
	return NewDispatcher(plugins), nil
}

// pluginNameFromPath extracts "foo" from "/path/to/envee-plugin-foo".
func pluginNameFromPath(path string) string {
	base := path
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			base = path[i+1:]
			break
		}
	}
	const prefix = "envee-plugin-"
	if len(base) <= len(prefix) {
		return ""
	}
	return base[len(prefix):]
}
