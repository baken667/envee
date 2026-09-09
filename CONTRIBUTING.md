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

Zig 0.16.0 exactly — `build.zig.zon` pins it and CI installs that version.

```bash
zig build                        # ./zig-out/bin/envee and envee-plugin-env
zig build test --summary all     # unit tests
zig fmt --check src build.zig
zig build release                # every release target into zig-out/release/
make examples                    # static-check every example config
```

Before pushing, the same things CI will run:

```bash
zig fmt --check src build.zig
zig build test --summary all
zig build release
(cd pkg/sdk-go && go test ./...)   # only if you touched the Go SDK
```

Look up std APIs in the installed standard library, not from memory: 0.16
moved a lot (`std.Io`, explicit `io` parameters, unmanaged containers).

```bash
grep -rn "pub fn createFile" "$(zig env | sed -n 's/.*"lib_dir": "\(.*\)",/\1/p')/std/Io/Dir.zig"
```

## House rules

**Errors.** Every user-facing error goes through `errs.fail(...)` with a
stable code, a hint and a doc link (`src/errs.zig`). New codes go in
[docs/errors.md](docs/errors.md) and get an exit-code mapping in
`errs.Code.exitCode`.

**Unimplemented commands must fail.** A command that prints "not implemented"
and exits 0 makes scripts and CI pass vacuously. Use `notImplemented(...)` in
`src/cli/root.zig` and mark the command `.hidden = true`.

**Shell escaping.** Anything emitted into shell code needs a round-trip test
in `src/shell/escape.zig` that runs a real shell and compares bytes. A value
from a `.env` must never be able to execute.

**Trust.** Any command that applies directives must go through
`context.resolveEnv`, which checks every file that contributed to the config
— not just the first — before anything with side effects runs.

**No dependencies.** The standard library is enough so far (TOML parser,
OpenSSH key parsing, JSON, ed25519 all included). A `build.zig.zon`
dependency needs a note in the PR describing why.

**Comments explain why.** Doc comments and inline comments say what a reader
could not work out from the code: the reason, the trade-off, the bug it
prevents. Tests are named as sentences describing the behaviour.

**Windows is experimental.** It must compile (`zig build release` covers it);
it does not have to pass tests yet. Use `src/perms.zig` for file modes.

## Commits

Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`,
`test:`). The release changelog is generated from them, so the subject line is
what users read. Explain *why* in the body; the diff already shows *what*.

## Branches

`main` is what users install. `staging` is the integration branch, and it is
where work lands first.

```
feature branch  →  PR into staging  →  (accumulate)
                →  tag vX.Y.Z-rc.N  →  staging tap  →  verify
                →  PR staging into main  →  tag vX.Y.Z
```

Both branches run the full CI suite on push and on pull requests. Open pull
requests against `staging` unless you are promoting a verified release
candidate.

## Releasing

Maintainers only.

A tag triggers `.github/workflows/release.yml`: `zig build release` builds
every target, the workflow packs archives, writes `checksums.txt`, signs it
with keyless cosign, publishes the GitHub release and pushes the Homebrew
formula to the tap. Pre-release tags (`-rc.N`, `-beta.N`, `-alpha.N`) go to
[`baken667/homebrew-tap-staging`](https://github.com/baken667/homebrew-tap-staging)
and are marked as pre-releases; stable tags go to the production tap.

Cut tags with `make tag`, never by hand. It tags the head of the right
branch only when no pull request into that branch is still open, and the
release workflow refuses a tag that is not reachable from that branch. Both
exist because v0.4.0 and v0.4.1 were tagged on a pre-merge head and published
the previous implementation under a new number.

```bash
make tag V=0.4.3-rc.1                     # from staging, after the PR is merged
brew install baken667/tap-staging/envee   # exercise it for real
make tag V=0.4.3                          # from main, after staging is promoted
```

The formula template lives in `packaging/homebrew/envee.rb.tmpl`; the
workflow fills in the version and per-archive checksums.

A tag can never be moved once pushed: users verify archives against the
signed `checksums.txt` of that tag. If a release is wrong, ship the next
patch version.
