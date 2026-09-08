// Command demoplugin is a minimal plugin built on the SDK, used to drive
// sdkgo.Run end to end from the package tests.
package main

import (
	"context"
	"os"

	sdkgo "github.com/baken667/envee/pkg/sdk-go"
)

func main() {
	p := sdkgo.Plugin{
		Resolve: func(_ context.Context, req sdkgo.Request) (sdkgo.Response, error) {
			ref, _ := req.Spec["ref"].(string)
			switch os.Getenv("DEMO_MODE") {
			case "plugin_error":
				return sdkgo.Response{}, sdkgo.NewError("E_NO_SUCH_SECRET", "no secret named "+ref, false)
			case "plain_error":
				return sdkgo.Response{}, context.DeadlineExceeded
			}
			return sdkgo.OkResponse("value-for-" + ref), nil
		},
	}
	p.Metadata.Name = "demo"
	p.Metadata.Version = "1.2.3"
	p.Metadata.APIVersion = sdkgo.APIVersion
	p.Metadata.Description = "demo plugin"
	p.Metadata.Capabilities = []string{"secret"}

	sdkgo.Run(p)
}
