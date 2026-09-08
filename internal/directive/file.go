// file.go — implementations of _.file directive (dotenv/json/yaml/toml).
package directive

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
	"github.com/baken667/envee/internal/config"
	"github.com/baken667/envee/internal/dotenv"
	"github.com/baken667/envee/internal/errs"
	"gopkg.in/yaml.v3"
)

// ApplyFile loads a single file directive and emits its variables via the
// `set` callback. The callback is invoked once per (key, value) pair.
//
// The path is resolved relative to configRoot unless absolute.
//
// Supported formats (per FileRef.Format):
//   - "dotenv" (default) — key=value format
//   - "json"            — top-level object {"KEY": "value", ...}
//   - "yaml" / "yml"    — top-level mapping
//   - "toml"            — top-level [env] table or flat keys
func ApplyFile(ctx context.Context, configRoot string, ref config.FileRef, set func(key, value string)) error {
	if ref.Path == "" {
		return errs.New("E003", "_.file entry missing path").
			WithContext("directive", "_.file")
	}

	path := ref.Path
	if !filepath.IsAbs(path) {
		path = filepath.Join(configRoot, path)
	}

	// Check existence.
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			if ref.Required {
				return errs.New("E012", "file not found").
					WithContext("path", path).
					WithContext("required", "true").
					WithHint("Create the file or set `required = false` in the _.file directive.")
			}
			// Not required: skip silently.
			return nil
		}
		return errs.Wrap(err, "E012", "read failed").WithContext("path", path)
	}

	// Dispatch to format-specific parser.
	format := strings.ToLower(ref.Format)
	if format == "" {
		format = detectFormat(path)
	}

	var kv map[string]string
	switch format {
	case "dotenv", ".env", "":
		kv, err = parseDotenv(data, ref.Expand)
	case "json":
		kv, err = parseJSON(data)
	case "yaml", "yml":
		kv, err = parseYAML(data)
	case "toml":
		kv, err = parseTOMLFile(data)
	default:
		return errs.New("E003", "unknown file format").
			WithContext("format", ref.Format).
			WithContext("path", path)
	}
	if err != nil {
		return errs.Wrap(err, "E002", "parse failed").
			WithContext("path", path).
			WithContext("format", format)
	}

	for k, v := range kv {
		set(k, v)
	}
	return nil
}

// detectFormat returns the file format based on extension.
func detectFormat(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".env", "":
		return "dotenv"
	case ".json":
		return "json"
	case ".yaml", ".yml":
		return "yaml"
	case ".toml":
		return "toml"
	}
	return "dotenv" // best guess
}

func parseDotenv(data []byte, expand bool) (map[string]string, error) {
	if expand {
		return dotenv.ParseWithExpansion(string(data))
	}
	return dotenv.Parse(string(data))
}

func parseJSON(data []byte) (map[string]string, error) {
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	return flatten(raw), nil
}

func parseYAML(data []byte) (map[string]string, error) {
	var raw map[string]any
	if err := yaml.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	return flatten(raw), nil
}

// parseTOMLFile parses a TOML file with optional [env] table.
//
// If the top level has [env], it uses that. Otherwise it flattens all
// top-level keys.
func parseTOMLFile(data []byte) (map[string]string, error) {
	var raw map[string]any
	if _, err := toml.Decode(string(data), &raw); err != nil {
		return nil, err
	}
	if envTable, ok := raw["env"].(map[string]any); ok {
		return flatten(envTable), nil
	}
	return flatten(raw), nil
}

// flatten converts a nested map[string]any into a flat map[string]string
// using dot-notation for nested keys.
//
//   {"app": {"name": "x"}} → {"app.name": "x"}
//   {"items": [1, 2, 3]}   → {"items": "[1 2 3]"}  (best effort)
func flatten(in map[string]any) map[string]string {
	out := make(map[string]string)
	flattenInto(out, "", in)
	return out
}

func flattenInto(out map[string]string, prefix string, in any) {
	switch v := in.(type) {
	case map[string]any:
		for k, val := range v {
			key := k
			if prefix != "" {
				key = prefix + "." + k
			}
			flattenInto(out, key, val)
		}
	case []any:
		parts := make([]string, len(v))
		for i, item := range v {
			parts[i] = fmt.Sprintf("%v", item)
		}
		out[prefix] = strings.Join(parts, " ")
	default:
		if prefix == "" {
			return // skip top-level scalars
		}
		out[prefix] = fmt.Sprintf("%v", v)
	}
}
