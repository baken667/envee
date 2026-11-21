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
   `src/shell/escape.zig`. Variable *names* are not escaped, so they are
   restricted instead: a name that is not an identifier is refused, whatever
   file it came from.

2. **Nothing is applied without approval.** Every config file that
   contributes to the resolved environment must be trusted — including
   `envee.local.toml`, `envee.d/*.toml`, configs in parent directories and the
   global config. A config may not set `ENVEE_*` variables, because envee
   exports its output into your shell and a config that could configure envee
   would be configuring it everywhere else too; the shell hook's own
   `__envee_*` variables are reserved for the same reason.

3. **Trust is content-addressed.** Approval is bound to the SHA-256 of the
   file. Editing a trusted file revokes its trust until you approve it again.

   What the hash covers is the config, **not the files it loads**. A `.env`,
   JSON or TOML file named by `_.file` can change after approval without a
   new `envee trust`, the same as with direnv's `dotenv`. Its values are
   inert (property 1), and it may not set the variables a shell or the
   dynamic loader runs as code (`PROMPT_COMMAND`, `BASH_ENV`, `PS0`–`PS4`
   and zsh's `PROMPT` family, `FPATH`, `fish_function_path`, `LD_PRELOAD`,
   `DYLD_*`, ...) or the ones that tell envee where its trust store is
   (`HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`); the full list is `runsCode`
   in `src/directive.zig`. That list is a mitigation, not a boundary: a
   variable that some *program* treats as code (`GIT_SSH_COMMAND`,
   `NODE_OPTIONS`, `ENV`) is still accepted, and so is a file value that a
   template in `envee.toml` copies into such a variable. Treat a `_.file`
   you do not control the way you would treat the config itself.

Things that are explicitly **not** in the threat model:

- An attacker who can already run code as you. envee is not a sandbox.
- Plugins. `envee-plugin-*` executables on your `$PATH` run with your
  privileges by design; envee mediates which secret a config may request, not
  what a plugin does. `envee check` tells you which plugins a config would
  invoke without invoking them, and `envee trust` lists them before you
  approve.
- Secret values in process memory or in your shell's environment. envee
  hides values marked `redact = true`, and every value that came from a
  secret plugin, in its own output (`status`, `resolve`, `diff`); it cannot
  stop a program you run from reading `$DATABASE_PASSWORD`. `envee eval` and
  `envee exec` carry the real values, because that is their job.

## Supported versions

Pre-1.0: only the latest release is supported; fixes are not back-ported.

## Verifying a release

Release artifacts are signed keylessly with [Sigstore](https://sigstore.dev).
There is no public key: the signature is bound to the GitHub Actions workflow
that produced it and recorded in the Rekor transparency log. Download
`checksums.txt`, `checksums.txt.sig` and `checksums.txt.pem` from the release
and run:

```bash
cosign verify-blob --certificate checksums.txt.pem \
  --signature checksums.txt.sig \
  --certificate-identity-regexp 'github.com/baken667/envee' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  checksums.txt
```

Then check the archive against it: `shasum -a 256 -c checksums.txt --ignore-missing`.
