## What and why

<!-- What changes, and what problem it solves. Link the issue if there is one. -->

## Checklist

- [ ] `go test -race -shuffle=on ./...` passes
- [ ] `golangci-lint run` is clean
- [ ] New user-facing errors have a code in `docs/errors.md` and an exit-code mapping
- [ ] Anything emitted into shell code has a round-trip test in `internal/shell`
- [ ] Commands that apply directives gate on `ensureTrusted`
- [ ] Conventional commit subject (`feat:`, `fix:`, ...)
