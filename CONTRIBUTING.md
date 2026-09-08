# Contributing to envee

Thanks for taking a look. Issues and pull requests are both welcome.

## Before a large change

Open an issue first. Architecture decisions live in [docs/adr/](docs/adr/) —
if your change contradicts one, say so in the issue; ADRs are meant to be
superseded, not worked around silently.

Worth reading before you start:

- [ADR-0004](docs/adr/0004-trust-model.md) — the trust model
- [ADR-0015](docs/adr/0015-versioning.md) — versioning
- [ADR-0017](docs/adr/0017-error-ux.md) — error codes and exit codes
- [SECURITY.md](SECURITY.md) — the threat model

## Development

```bash
make build        # ./bin/envee and ./bin/enveed
make test         # unit tests
make test-race    # with the race detector
make lint         # golangci-lint (v2 — `brew install golangci-lint`)
make examples     # static-check every example config
```

Before pushing, the same three things CI will run:

```bash
go test -race -shuffle=on ./...
golangci-lint run
gofmt -l .
```

To exercise the release pipeline without publishing anything:

```bash
# goreleaser must be v1.x; v2 rejects this repo's config schema.
make release-snapshot
cat dist/homebrew/Formula/envee.rb
```

CI runs the same snapshot on every pull request, so a release-config mistake
surfaces on the PR rather than on a tag.

## House rules

**Errors.** Every user-facing error is an `*errs.Error` with a stable code, a
hint and a doc link. New codes go in [docs/errors.md](docs/errors.md) and get
an exit-code mapping in `internal/cli/root.go`.

**Unimplemented commands must fail.** A command that prints "not implemented"
and exits 0 makes scripts and CI pass vacuously. Use `notImplemented(...)` and
mark the command `Hidden: true`.

**Shell escaping.** Anything emitted into shell code needs a round-trip test in
`internal/shell/escape_roundtrip_test.go` that runs a real shell and compares
bytes. A value from a `.env` must never be able to execute.

**Trust.** Any command that applies directives must gate on `ensureTrusted`,
which checks every file that contributed to the config — not just the first.

**No new dependencies** without a note in the PR describing why the standard
library is not enough.

**Watch the `go` directive.** `go get` raises it to whatever a new dependency
demands, which silently drops users on older toolchains. `golang.org/x/crypto`
and `golang.org/x/sys` are pinned for exactly this reason — the current
releases require Go 1.26. CI fails if `go.mod` outpaces the toolchain it
builds with; raising the minimum Go version is a deliberate compatibility
decision, not a side effect of adding a dependency.

## Commits

Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`,
`test:`). The release changelog is generated from them, so the subject line is
what users read. Explain *why* in the body; the diff already shows *what*.

## Releasing

Maintainers only. Tag `vX.Y.Z` on `main`; the Release workflow builds, signs
and pushes the Homebrew formula. Pre-release tags (`-rc.N`, `-beta.N`,
`-alpha.N`) go to the staging tap instead.

Note that a tag can never be moved once pushed: `sum.golang.org` notarises the
module at that version permanently, and re-tagging breaks
`go install ...@vX.Y.Z` for everyone with an unfixable checksum mismatch. If a
release is wrong, ship the next patch version.
