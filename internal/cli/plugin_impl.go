package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"

	"github.com/spf13/cobra"

	"github.com/baken667/envee/internal/errs"
	"github.com/baken667/envee/internal/plugin"
)

// discoveredPlugin pairs a plugin binary with whatever its metadata handshake
// returned. Metadata is nil when the handshake failed -- that is worth showing
// rather than hiding, since a plugin that cannot answer `metadata` will not
// resolve secrets either.
type discoveredPlugin struct {
	Name     string           `json:"name"`
	Path     string           `json:"path"`
	Metadata *plugin.Metadata `json:"metadata,omitempty"`
	Error    string           `json:"error,omitempty"`
}

func discoverPlugins(cmd *cobra.Command) []discoveredPlugin {
	paths := plugin.DiscoverPaths()
	out := make([]discoveredPlugin, 0, len(paths))
	seen := make(map[string]bool, len(paths))

	for _, path := range paths {
		name := plugin.PluginName(path)
		if name == "" || seen[name] {
			continue // first match on $PATH wins, as with any executable
		}
		seen[name] = true

		d := discoveredPlugin{Name: name, Path: path}
		p, err := plugin.NewExecPlugin(name)
		if err != nil {
			d.Error = err.Error()
			out = append(out, d)
			continue
		}
		meta, err := p.FetchMetadata(cmd.Context())
		if err != nil {
			d.Error = err.Error()
		} else {
			d.Metadata = &meta
		}
		out = append(out, d)
	}

	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func runPluginList(cmd *cobra.Command, jsonOut bool) error {
	found := discoverPlugins(cmd)

	if jsonOut {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(found)
	}

	if len(found) == 0 {
		fmt.Println("No plugins found.")
		fmt.Println()
		fmt.Println("envee discovers executables named envee-plugin-<name> on $PATH.")
		fmt.Println("The bundled local store is available as: go install github.com/baken667/envee/plugins/env")
		return nil
	}

	fmt.Printf("%-14s %-10s %-5s %s\n", "NAME", "VERSION", "API", "DESCRIPTION")
	for _, d := range found {
		if d.Metadata == nil {
			fmt.Printf("%-14s %-10s %-5s %s\n", d.Name, "?", "?", "handshake failed: "+d.Error)
			continue
		}
		fmt.Printf("%-14s %-10s %-5d %s\n",
			d.Name, d.Metadata.Version, d.Metadata.APIVersion, d.Metadata.Description)
	}
	return nil
}

func runPluginInfo(cmd *cobra.Command, name string, jsonOut bool) error {
	for _, d := range discoverPlugins(cmd) {
		if d.Name != name {
			continue
		}
		if jsonOut {
			enc := json.NewEncoder(os.Stdout)
			enc.SetIndent("", "  ")
			return enc.Encode(d)
		}
		fmt.Printf("Plugin:      %s\n", d.Name)
		fmt.Printf("Path:        %s\n", d.Path)
		if d.Metadata == nil {
			fmt.Printf("Status:      metadata handshake failed: %s\n", d.Error)
			return nil
		}
		m := d.Metadata
		fmt.Printf("Version:     %s\n", m.Version)
		fmt.Printf("API version: %d\n", m.APIVersion)
		fmt.Printf("Description: %s\n", m.Description)
		if len(m.Capabilities) > 0 {
			fmt.Printf("Capabilities: %v\n", m.Capabilities)
		}
		fmt.Printf("Permissions:\n")
		fmt.Printf("  network:    %v\n", m.Permissions.Network)
		if len(m.Permissions.Filesystem) > 0 {
			fmt.Printf("  filesystem: %v\n", m.Permissions.Filesystem)
		}
		if len(m.Permissions.Exec) > 0 {
			fmt.Printf("  exec:       %v\n", m.Permissions.Exec)
		}
		return nil
	}

	return errs.New("E009", "plugin not found").
		WithContext("name", name).
		WithHint("Run `envee plugin list` to see what is discoverable, and make sure envee-plugin-" +
			name + " is executable and on $PATH.")
}
