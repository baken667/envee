# Security Policy

## Reporting a vulnerability

Report privately through GitHub's
[private vulnerability reporting](https://github.com/baken667/envee/security/advisories/new)
rather than opening a public issue.

Please include what you can: affected version or commit, a config or `.env`
that reproduces it, the shell involved, and the impact you observed. A working
proof of concept is welcome but not required.

There is no bounty programme.

## Threat model

envee's premise is that **a config file is data, not code.** `direnv`'s
`.envrc` is a shell script, so loading one is arbitrary code execution by
design; `envee.toml` is TOML, and the values in it must never be able to
execute anything.

That gives three properties worth attacking:

1. **Values are inert.** `envee eval <shell>` produces shell code that the
   hook feeds to `eval`. No value from `envee.toml`, from a `.env` loaded via
   `_.file`, or from a secret plugin may escape its quoting and become a
   command. Escaping is round-tripped through real bash, zsh and fish in
   `internal/shell`.

2. **Nothing is applied without approval.** Every config file that
   contributes to the resolved environment must be trusted — including
   `envee.local.toml`, `envee.d/*.toml`, configs in parent directories and the
   global config. A config may not set `ENVEE_*` variables, because envee
   exports its output into your shell and a config that could configure envee
   would be configuring it everywhere else too.

3. **Trust is content-addressed.** Approval is bound to the SHA-256 of the
   file. Editing a trusted file revokes its trust until you approve it again.

Things that are explicitly **not** in the threat model:

- An attacker who can already run code as you. envee is not a sandbox.
- Plugins. `envee-plugin-*` executables on your `$PATH` run with your
  privileges by design; envee mediates which secret a config may request, not
  what a plugin does. `envee check` tells you which plugins a config would
  invoke without invoking them, and `envee trust` lists them before you
  approve.
- Secret values in process memory or in your shell's environment. envee
  redacts values marked `redact = true` in its own output (`status`, `diff`);
  it cannot stop a program you run from reading `$DATABASE_PASSWORD`.
- `_.source`, which runs a shell script by design. It is off unless a config
  you trusted asks for it, and `envee trust` shows it.

## Supported versions

Pre-1.0: only the latest release is supported. There is no published release
yet, so there is nothing to back-port to.

## Verifying a release

Release artifacts are signed keylessly with [Sigstore](https://sigstore.dev).
There is no public key: the signature is bound to the GitHub Actions workflow
that produced it and recorded in the Rekor transparency log. Each release's
notes carry the exact `cosign verify-blob` invocation for that tag.
