# Secrets example

Demonstrates how to use secret manager plugins. You'll need at least one
plugin installed to actually resolve secrets; otherwise `envee resolve`
will show the unresolved references.

## Install a plugin

```bash
brew install baken/tap/envee-plugin-op    # 1Password
brew install baken/tap/envee-plugin-aws   # AWS
brew install baken/tap/envee-plugin-vault # HashiCorp Vault
```

## Sign in to your secret manager

```bash
op signin my.1password.com     # 1Password
aws sso login --profile dev   # AWS
vault login                   # Vault
```

## Try it

```bash
cd examples/secrets
envee trust
envee resolve
```

Without a plugin installed, you'll see:
```
[envee] ERROR [E009]: secret plugin not found.
[envee]   source:  op
[envee]   plugin:  envee-plugin-op
[envee] HINT:  Install with: brew install baken/tap/envee-plugin-op
```

## Security

- All secrets are marked `redact = true` by default — they don't appear in
  `envee status` or `envee resolve` (without `--show-secrets`).
- Cache lives in OS keychain (Keychain on macOS, libsecret on Linux).
- TTL = 15 min by default; re-resolve with `envee invalidate --secret=<name>`.
- Audit log (opt-in via `ENVEE_AUDIT=1`) records who resolved what, but never the value.
