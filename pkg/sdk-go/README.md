# envee plugin SDK (Go)

Write envee plugins in Go in 30 lines.

## Quick start

```go
package main

import (
    "context"
    sdk "github.com/baken667/envee/pkg/sdk-go"
)

func main() {
    sdk.Run(sdk.Plugin{
        Metadata: sdk.Metadata{
            Name:         "my-plugin",
            Version:      "0.1.0",
            APIVersion:   1,
            Capabilities: []string{"secret"},
        },
        Resolve: func(ctx context.Context, req sdk.Request) (sdk.Response, error) {
            ref, _ := req.Spec["ref"].(string)
            secret, err := lookupSomewhere(ref)
            if err != nil {
                return sdk.Response{}, sdk.NewError("not_found", err.Error(), true)
            }
            return sdk.OkResponse(secret), nil
        },
    })
}
```

Build:
```bash
go build -o envee-plugin-myplugin .
sudo mv envee-plugin-myplugin /usr/local/bin/
```

Use in `envee.toml`:
```toml
[env]
MY_SECRET = { secret = { source = "myplugin", ref = "..." } }
```

## Protocol

The plugin binary is invoked as `envee-plugin-<name> <subcommand>`:

| Subcommand | Input | Output |
|---|---|---|
| `metadata` | (none) | JSON Metadata |
| `resolve` | Request JSON on stdin | Response JSON on stdout |

Exit code: 0 = success, non-zero = error (response still written to stdout for parsing).

## Error codes

- `auth_required` — user needs to authenticate
- `not_found` — secret not found
- `permission_denied` — access denied
- `network_error` — no connectivity
- `invalid_spec` — bad request
- `internal_error` — bug in plugin
- `quota_exceeded` — rate limit

## License

MIT
