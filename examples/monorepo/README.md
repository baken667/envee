# Monorepo example

Demonstrates config inheritance from a monorepo root down to subproject configs.

## Layout

```
monorepo/
├── envee.toml                       # monorepo-root: shared values
└── services/
    └── api/
        └── envee.toml               # API service: overrides + extensions
```

## Resolution order

When you `cd` into `monorepo/services/api/`, envee walks up the directory
tree and merges in priority order:

1. `monorepo/services/api/envee.local.toml` (highest, gitignored)
2. `monorepo/services/api/envee.toml` ← API service
3. `monorepo/services/api/envee.d/*.toml` (fragments)
4. `monorepo/envee.toml` ← monorepo root
5. `~/.config/envee/config.toml` (global defaults)

**Child wins on conflict** for scalar values; maps are deep-merged; arrays
are replaced (so you can fully override `_.path` per service).

## Try it

```bash
cd examples/monorepo/services/api
envee trust
envee resolve
# → contains both MONOREPO_ROOT (from root) and SERVICE_NAME=api (from here)
```
