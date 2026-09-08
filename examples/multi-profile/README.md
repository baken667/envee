# Multi-profile example

Demonstrates dev/staging/prod environments with profile-specific overrides,
inheritance, and required-var validation.

## Select a profile

```bash
# Default (from `profile = "dev"` in envee.toml)
envee eval bash

# Via env var
ENVEE_PROFILE=prod envee eval bash

# Via flag (highest priority)
envee --profile=staging eval bash
```

## What's special here

- `extends = ["common"]` — profiles can share base values.
- `required = [...]` — when `prod` is active, missing vars fail the eval.
- `DATABASE_PASSWORD` is sourced from Vault in `staging` and `prod` (requires the `envee-plugin-vault` plugin).

## Try it

```bash
cd examples/multi-profile
envee trust
envee --profile=prod eval bash 2>&1
# Expected: errors about STRIPE_API_KEY being missing
```

## See also

- ADR-0010 (profiles) — full design
- ADR-0009 (secrets) — how secret plugins are invoked
