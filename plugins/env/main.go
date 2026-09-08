// envee-plugin-env: simple key-value secret provider backed by a local JSON file.
//
// Stores secrets in $XDG_DATA_HOME/envee/secrets/env.json (mode 0600).
// Use `envee secret set KEY=VALUE` to manage entries (separate CLI command).
//
// Plugin protocol: see docs/adr/0007-plugin-protocol.md and pkg/sdk-go.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	sdk "github.com/baken667/envee/pkg/sdk-go"
)

const pluginName = "env"

func main() {
	sdk.Run(sdk.Plugin{
		Metadata: sdk.Metadata{
			Name:         pluginName,
			Version:      "0.1.0",
			APIVersion:   1,
			Description:  "Local key-value secret store (envee secret set/unset/list)",
			Capabilities: []string{"secret"},
			Permissions: struct {
				Network    bool     `json:"network"`
				Filesystem []string `json:"filesystem"`
				Exec       []string `json:"exec"`
			}{
				Network: false,
				Filesystem: []string{
					"$XDG_DATA_HOME/envee/secrets/env.json",
				},
			},
		},
		Resolve: resolve,
	})
}

// store is a thread-safe in-process cache of the secrets file.
var (
	storeMu sync.RWMutex
	store   map[string]string
	loaded  time.Time
)

func storePath() (string, error) {
	dir := os.Getenv("XDG_DATA_HOME")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(dir, "envee", "secrets", "env.json"), nil
}

// loadStore reads the secrets file (with mtime cache).
func loadStore() (map[string]string, error) {
	storeMu.Lock()
	defer storeMu.Unlock()

	path, err := storePath()
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			store = map[string]string{}
			return store, nil
		}
		return nil, err
	}
	// Reload if mtime changed.
	if !loaded.IsZero() && info.ModTime().Equal(loaded) && store != nil {
		return store, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	m := make(map[string]string)
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	store = m
	loaded = info.ModTime()
	return store, nil
}

func resolve(ctx context.Context, req sdk.Request) (sdk.Response, error) {
	ref, _ := req.Spec["ref"].(string)
	if ref == "" {
		return sdk.Response{}, sdk.NewError("invalid_spec", "ref is required", false)
	}
	m, err := loadStore()
	if err != nil {
		return sdk.Response{}, sdk.NewError("internal", err.Error(), true)
	}
	v, ok := m[ref]
	if !ok {
		return sdk.Response{}, sdk.NewError("not_found",
			fmt.Sprintf("secret %q not found in env store", ref), true)
	}
	return sdk.OkResponseTTL(v, 15*time.Minute), nil
}
