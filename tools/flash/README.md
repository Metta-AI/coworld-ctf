# flash — the paintbot Battle Royale one-page-policy authoring loop

> **Deprecated since 0.7.253.** This authors the pre-Season-2 one-page policy
> surface retained for deprecated modes behind `allowDeprecatedModes: true`.
> Current policies upload and call WASM plays; start in
> [`policies/starters/`](../../policies/starters/README.md).

Turns an LLM into a policy AUTHOR, not a policy writer-of-Nim. A "policy
page" is a small JSON scoring sheet (spec: `SCHEMA.md`) that ranks a fixed,
named menu of INTENTS the engine offers a cog each tick — it never touches
the d-pad, the aim, or the 8-bit button mask directly. See `SCHEMA.md` §0 for
the STRATEGY -> INTENT -> ACTION layering, and
`docs/designs/ONE_PAGE_POLICY.md` for the original design rationale.

This tool exists so that **a page that fails validation never reaches
disk.** `flash author` asks a model for a page, validates it against the
real VM (`src/ctf/policy_page.nim`), and on failure feeds the exact
validation errors back to the model and retries — up to 3 total attempts —
before giving up loudly instead of writing something broken.

## Layout

- `SCHEMA.md` — the authoritative, LLM-facing spec: JSON shape, the full op
  whitelist, every legal `get`/`trait` path, and the hard rules. This file IS
  the prompt context `flash author` hands the model; keep it precise, not
  friendly.
- `prompt.md` — the system prompt template. Contains `{{SCHEMA}}` (filled
  with `SCHEMA.md`'s contents) and `{{BRIEF}}` (filled with the tactical
  situation passed on the command line).
- `flash.nim` — the CLI (see below).
- `playbook/` — the seed playbook: 6 hand-written, validated Battle Royale
  stances, doubling as the LLM's few-shot examples and the dashboard's
  starting roster. Two (`tight-trade.json`, `wide-intel.json`) hinge on the
  duo-partner mechanic; one (`point-blank-control.json`) is a deliberately
  WRONG-for-BR control card, kept so a future A/B has something to beat.
- `testdata/` — a deliberately broken fixture (an unknown `get` path) used
  to prove `flash validate` actually rejects bad pages, by name.

## Running it

Build/run the same way the other single-file tools under `tools/` do — there
is no nimble task wired up for this (there isn't one for any tool in
`ctf.nimble` today; it declares no `task`/`bin` entries at all, so this
follows the existing convention rather than introducing a new one):

```sh
# one-shot run (compiles to a temp binary each time)
nim r tools/flash/flash.nim -- <subcommand> [args]

# or build once, run many times
nim c -o:/tmp/flash tools/flash/flash.nim
/tmp/flash <subcommand> [args]
```

### `flash author "<brief>"`

Asks the LLM for one page scoped to `<brief>`, validates it, retries with
the validation errors appended to the conversation on failure (up to 3
attempts total), and on success writes `playbook/<name>.json` (`<name>`
taken from the validated page's own `"name"` field, or pass `--out <name>`
to override).

```sh
nim r tools/flash/flash.nim -- author "a duo that holds a hotspot and only breaks cover for a kill under half enemy hp"
nim r tools/flash/flash.nim -- author "..." --model gemini
nim r tools/flash/flash.nim -- author "..." --out my-page-name
```

Supported `--model` values: `claude` (default), `gemini`, `xai`. Each maps
to the matching adapter already in `src/ctf/ais/` (`claude.nim`/
`gemini.nim`/`xai.nim`) — this tool does not implement its own HTTP client,
it reuses those. `openai.nim` and `bedrock.nim` exist in that directory too
but have a different return-type shape and are not wired up here.

Required environment variable per adapter (unset means `flash author` fails
fast with a clear message instead of an HTTP 401):

| `--model` | env var |
| --- | --- |
| `claude` (default) | `CLAUDE_KEY` |
| `gemini` | `GEMINI_KEY` |
| `xai` | `XAI_KEY` |

### `flash validate <file.json>`

Parses and validates one page against the real VM. Prints `OK` and exits 0,
or prints `FAIL` plus every validation error (one per line) and exits 1.
This is the CI gate — wire it into a pre-merge check over any page a human
or an LLM proposes adding to the playbook.

```sh
nim r tools/flash/flash.nim -- validate tools/flash/playbook/tight-trade.json
```

### `flash lint <dir>`

Validates every `*.json` file in `<dir>` (defaults to `playbook/`) and
prints a `NAME / STATUS / DOC` table. Exits 1 if any page fails.

```sh
nim r tools/flash/flash.nim -- lint tools/flash/playbook
```

## Status of the real-LLM path

`flash author`'s repair loop (extract JSON from the reply, validate, feed
errors back, retry) is implemented and exercised against the real
`src/ctf/policy_page.nim` VM, but the actual network call was **not**
exercised end to end in this environment — `CLAUDE_KEY`/`GEMINI_KEY`/
`XAI_KEY` are all unset here. `flash author "..."` correctly fails fast with
`ERROR: CLAUDE_KEY is not set -- cannot call claude.` rather than attempting
(and silently mis-failing) a network call. Set one of the env vars above in
a shell that has network access to exercise the full loop.
