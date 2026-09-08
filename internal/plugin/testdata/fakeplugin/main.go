// Command fakeplugin is a configurable envee plugin used by the tests in
// internal/plugin. Its behaviour is driven entirely by environment variables
// so a single binary can stand in for every failure mode a real plugin has.
//
// It is built by TestMain and installed on $PATH under several
// envee-plugin-<name> aliases.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"
)

func main() {
	mode := os.Getenv("FAKE_PLUGIN_MODE")

	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: fakeplugin <metadata|resolve>")
		os.Exit(2)
	}

	switch mode {
	case "exit_nonzero":
		fmt.Fprintln(os.Stderr, "fakeplugin: deliberate failure")
		os.Exit(1)
	case "garbage":
		fmt.Println("this is not json at all")
		return
	case "hang":
		time.Sleep(60 * time.Second)
		return
	}

	switch os.Args[1] {
	case "metadata":
		md := map[string]any{
			"name":         "fake",
			"version":      "9.9.9",
			"api_version":  1,
			"description":  "fake plugin for tests",
			"capabilities": []string{"secret"},
		}
		_ = json.NewEncoder(os.Stdout).Encode(md)

	case "resolve":
		body, _ := io.ReadAll(os.Stdin)
		var req struct {
			RequestID string         `json:"request_id"`
			Spec      map[string]any `json:"spec"`
		}
		_ = json.Unmarshal(body, &req)
		ref, _ := req.Spec["ref"].(string)

		resp := map[string]any{
			"api_version": 1,
			"request_id":  req.RequestID,
		}

		switch mode {
		case "error_response":
			resp["status"] = "error"
			resp["error"] = map[string]any{
				"code":        "E_NOT_FOUND",
				"message":     "no such secret: " + ref,
				"recoverable": false,
			}
		case "status_not_ok":
			resp["status"] = "degraded"
		case "null_value":
			resp["status"] = "ok"
		case "int_value":
			resp["status"] = "ok"
			resp["value"] = map[string]any{"type": "int", "value": 42}
		case "bool_value":
			resp["status"] = "ok"
			resp["value"] = map[string]any{"type": "bool", "value": true}
		case "json_value":
			resp["status"] = "ok"
			resp["value"] = map[string]any{"type": "json", "value": map[string]any{"a": 1}}
		default:
			resp["status"] = "ok"
			resp["value"] = map[string]any{"type": "string", "value": "resolved:" + ref}
		}
		_ = json.NewEncoder(os.Stdout).Encode(resp)

	default:
		fmt.Fprintln(os.Stderr, "unknown subcommand", os.Args[1])
		os.Exit(2)
	}
}
