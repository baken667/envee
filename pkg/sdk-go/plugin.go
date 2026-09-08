// Package sdkgo provides a Go SDK for writing envee plugins.
//
// Plugins are external executables named "envee-plugin-<name>" that
// communicate with envee via JSON over stdin/stdout. This SDK hides the
// protocol details and lets you focus on your plugin's logic.
//
// Example usage:
//
//	package main
//
//	import (
//	    "context"
//	    sdk "github.com/baken667/envee/pkg/sdk-go"
//	)
//
//	func main() {
//	    sdk.Run(sdk.Plugin{
//	        Metadata: sdk.Metadata{
//	            Name:        "my-plugin",
//	            Version:     "0.1.0",
//	            APIVersion:  1,
//	            Capabilities: []string{"secret"},
//	        },
//	        Resolve: func(ctx context.Context, req sdk.Request) (sdk.Response, error) {
//	            secret, err := lookupSecret(req.Spec)
//	            if err != nil {
//	                return sdk.Response{}, err
//	            }
//	            return sdk.OkResponse(secret), nil
//	        },
//	    })
//	}
//
// Build and install:
//
//	go build -o envee-plugin-myplugin .
//	sudo mv envee-plugin-myplugin /usr/local/bin/
//
// Then in envee.toml:
//
//	[env]
//	MY_SECRET = { secret = { source = "myplugin", ref = "..." } }
package sdkgo

// APIVersion is the current plugin protocol version.
const APIVersion = 1
