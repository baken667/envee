# envee error codes

Every error envee emits carries a stable code. The code is what you should
search for and what tooling should match on — the wording of a message may
change between releases, the code will not.

Exit codes are grouped by category (see
[ADR-0017](adr/0017-error-ux.md)):

| Exit | Meaning |
|---|---|
| 0 | success |
| 1 | unclassified error |
| 2 | invalid usage |
| 3 | trust required |
| 4 | config error |
| 5 | plugin, daemon or network error |
| 6 | internal error |

---

<a id="e001"></a>

## E001 — Trust required

The config file has not been approved, or its contents changed since you
approved it. envee refuses to apply a config it has not been told to trust.

Run `envee trust` to review what the file does and approve it. Use
`envee check` first if you want a static analysis without approving anything.

A resolved config is usually merged from several files — `envee.toml`,
`envee.local.toml`, `envee.d/*.toml`, configs in parent directories, and the
global config. **Every one of them must be trusted.** The error names the
specific file that is not.

<a id="e002"></a>

## E002 — Config parse error

The TOML could not be parsed. The message carries the file, line and column.

<a id="e003"></a>

## E003 — Config validation error

The config parsed but is not valid. Common causes:

- a secret is missing `source` or `ref`
- `schema` names a version this build does not understand
- the config tries to set a reserved `ENVEE_*` variable. These configure envee
  itself; a config file may not set them, because envee exports its output
  into your shell and one project could otherwise change envee's behaviour
  everywhere else
- `envee check` found errors (or, with `--strict`, warnings)

<a id="e004"></a>

## E004 — Secret plugin error

A secret plugin was found but failed to resolve the reference.

<a id="e005"></a>

## E005 — Template render error

A `{{ ... }}` expression could not be rendered. Check the filter names and
that referenced variables exist.

<a id="e006"></a>

## E006 — WASM script error

A `_.script` module failed. (Scripts are not implemented yet.)

<a id="e007"></a>

## E007 — Cycle detected

Two or more variables reference each other through templates, so no
resolution order exists. `envee check` reports the exact cycle.

<a id="e008"></a>

## E008 — Required var missing

A variable marked `required = true` — or listed in a profile's `required` —
was not set by the time resolution finished.

<a id="e009"></a>

## E009 — Plugin not found

A secret references `source = "<name>"` but no `envee-plugin-<name>`
executable is on `$PATH`. `envee check` warns about this before you hit it at
eval time.

<a id="e010"></a>

## E010 — Trust denied

The file was explicitly denied with `envee deny`. Run `envee trust` to
approve it instead.

<a id="e011"></a>

## E011 — Daemon error

The `enveed` daemon could not be reached or returned an error.

<a id="e012"></a>

## E012 — File not found

A path referenced by `_.file`, `_.script` or `_.source` does not exist and was
marked required.

<a id="e013"></a>

## E013 — Permission denied

envee could not read or write a path — commonly the trust store under
`$XDG_DATA_HOME/envee` or a referenced env file.

<a id="e014"></a>

## E014 — Version incompatible

The config's `schema` requires a newer envee than the one running.

<a id="e015"></a>

## E015 — Network error

A plugin or update check could not reach the network.
