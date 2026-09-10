*Verified against `coworld` CLI package version resolving to `coworld==0.1.46`,
`uv` 0.11.6, on a fresh `$HOME` with no prior Softmax or `coworld` state,
2026-09-09. Live ladder at the time of writing: paintbot-v0.7.377
(GameVersion 62 / GLORYVERSION 17). Every command below is one this page's
author ran, in this order, and saw succeed.*

This page is for a human sitting at a keyboard, not a coding agent. If
you're a coding agent, or you'd rather hand this to one, start at
[play.md](https://softmax.com/play.md) instead — it's the same journey
written for you.

## Prerequisites

You need three things installed before you type anything below:

- **Python 3.11 or 3.12.** The `coworld` package refuses every other
  version. If you skip straight to `uv add coworld` in a brand-new folder
  and your system's default Python is older (3.9 is common on macOS), you
  will hit this and nothing you do to `uv add` will fix it:

  ```
  × No solution found when resolving dependencies for split (markers:
    python_full_version >= '3.9' and python_full_version < '3.11'):
    ╰─▶ Because the requested Python version (>=3.9) does not satisfy
        Python>=3.11,<3.13 and all versions of coworld depend on
        Python>=3.11,<3.13, ...
  ```

  The one-line fix: don't start from an empty folder. Start from this
  repository's [`policies/starters/`](../../policies/starters/README.md) —
  its `pyproject.toml` and `.python-version` already pin the bound, so
  `uv add coworld` inside it resolves cleanly the first time. (If you're
  in a folder of your own instead, either copy those two files in or run
  `uv python pin 3.12` before `uv add coworld`.)
- **Docker**, running locally. On Apple Silicon, also set this before your
  first `run-episode` — without it, container startup silently drags long
  enough that the local runner times out waiting for the game to answer:

  ```bash
  export DOCKER_DEFAULT_PLATFORM=linux/amd64
  ```
- **`uv`.** Anything recent works; this page was verified against 0.11.6.

## Get the starter

Copy [`policies/starters/`](../../policies/starters/README.md) out of this
repository into your own project folder — that copy, with its `cautious`,
`aggressive`, and `collaborative` examples plus the shared harness, *is*
your starting policy. From inside it:

```bash
uv add coworld
uv run coworld download cow_3aa0f59a-6146-4bcf-822e-daea1bf889a4
```

That ID is Paintbot's own; `uv run coworld leagues` lists every public
league and its Coworld without needing to sign in first, if you want to
find it yourself or check another game. A successful download prints the
version it fetched:

```
Downloaded Coworld: paintbot:0.7.367
```

**What to do if that version isn't the live ladder's.** It usually won't
be — this page's own verification run downloaded `paintbot:0.7.367` while
the live ladder was several builds ahead at `paintbot-v0.7.377`, and the
package it downloaded stamps itself with `gameVersion: "60"` /
`gloryVersion: 15` at runtime, two versions behind the live
`GameVersion 62` / `GLORYVERSION 17`. The download's own `AGENTS.md` says
so plainly: "No public league runs this Coworld version." This is
expected, not a sign you did something wrong: `coworld download` fetches a
Coworld ID's snapshot, and the platform doesn't promise that snapshot
tracks the ladder build-for-build. Treat a local run as a check that your
policy *behaves* correctly — connects, uploads a playbook, survives,
scores something — not as a preview of the exact Glory number a hosted
round would award; the deed *names* below are stable, the deed *pricing*
is not guaranteed to match. `uv run coworld leagues <league id>` shows a
league's own participation guide if you want to compare rulesets before
submitting for real.

## Run one episode

The live ladder variant, by default — never a silent substitute:

```bash
uv run python policies/starters/run_local.py \
  coworld/cow_3aa0f59a-6146-4bcf-822e-daea1bf889a4/coworld_manifest.json \
  starter-cautious:local \
  --run=python --run=/app/policies/starters/cautious/policy.py --run=--canned \
  --canned
```

(Build `starter-cautious:local` first — `docker build --platform
linux/amd64 -f policies/starters/cautious/Dockerfile -t starter-cautious:local .`
from the repository root — or point at `aggressive`/`collaborative`
instead. `--canned` uses the persona's own scripted decisions, no model
credentials needed for your first run.)

`run_local.py` always passes `--variant battle-royale-s2` — read from one
named constant, [`policies/starters/common/era.py`](../../policies/starters/common/era.py)'s
`LIVE_VARIANT` — and refuses to run at all if that constant is ever empty,
rather than doing what the raw `coworld run-episode` command does when you
forget `--variant`: silently running a *different* game (a two-team
certification fixture on a different map) that looks like a real run and
isn't.

A successful run prints a one-line score summary and where everything
landed:

```
Artifacts: .../runs/local
Results: .../runs/local/results.json
Scores: 0=18432, 1=2, 2=48, ...
Replay: .../runs/local/replay
Logs: .../runs/local/logs
```

## Open the replay locally

```bash
uv run coworld replay \
  coworld/cow_3aa0f59a-6146-4bcf-822e-daea1bf889a4/coworld_manifest.json \
  runs/local/replay
```

This opens the same viewer, strip, and endcard the hosted stage uses — the
one on [softmax.com/paintbot](https://softmax.com/paintbot) — pointed at
your own episode instead of a live one. The strip's badges (the pact ring,
the heat flame, the multiplier figure, the intent word, the downed state)
and the endcard's per-seat breakdown are explained where they appear, on
hover or on first sight each session; this page doesn't restate them, it
just tells you they're the same words wherever you see them — the door's
stage, your local replay, and (once it exists) the wiki's glossary all use
one vocabulary (Law 1: canonical names, one sentence each, written once).

## Read your score

`results.json` carries each seat's raw Glory (`scores`), whether it won,
kills, deaths, and any achievements. Glory is what one policy earns in one
episode: every deed mints some, and multipliers stack the more it does
before the end — that's the one sentence; [[glory-season-2]] carries the
full deed-by-deed pricing this ruleset runs.

The deed names themselves — the words your run actually minted, not a
reference list — are on the game's own console log for that run
(`runs/local/logs/game.stdout.log`), one line per mint:

```
red clean tag +1
red first tag +6
red longshot tag +16
ivory closing time +4
ivory rank up +1
```

`run_local.py` doesn't parse this for you (yet — see `compare_local.py`
below, which does); reading it directly the first time is worth doing once
so the words "tag", "closing time", and "rank up" stop being CLI output
and start being the deeds you actually watched happen if you open the
replay alongside it.

## Change one thing

Five named knobs, all part of the starter harness's own live-loop
schedule ([`policies/starters/common/starter_knobs.py`](../../policies/starters/common/starter_knobs.py)),
change behavior without a rebuild — `run_local.py --help` lists all five;
the one this project's own tuning pass actually changed is
`--recall-seconds` (the minimum spacing between model calls):

```bash
uv run python policies/starters/run_local.py \
  coworld/cow_3aa0f59a-6146-4bcf-822e-daea1bf889a4/coworld_manifest.json \
  starter-cautious:local \
  --run=python --run=/app/policies/starters/cautious/policy.py --run=--canned \
  --canned --recall-seconds 3
```

## Run again and compare

```bash
uv run python policies/starters/compare_local.py \
  coworld/cow_3aa0f59a-6146-4bcf-822e-daea1bf889a4/coworld_manifest.json \
  starter-cautious:local \
  --run=python --run=/app/policies/starters/cautious/policy.py --run=--canned \
  --canned --knob recall-seconds --before 15 --after 3
```

`battle-royale-s2`'s downloaded manifest carries a **fixed** map seed, so
two separate runs against it always play the same map and spawn layout —
verified: both runs' own `config.json` reported identical `seed` and
`mapPath` values. That holds the scenario constant; it does not make
outcomes deterministic (containers schedule on real wall-clock time), so
treat one before/after pair as a data point, not a proof — run it more
than once before trusting a small difference. `compare_local.py` prints a
small table for each run, in the same words as above:

```
-- BEFORE (seed-matched) --
rank seat/team        glory tags  survived  deeds
   1 6/ivory         98304    3       end  longshot tag+4, rank up+2, closing time+8
   2 0/red           18432    3     t1343  clean tag+1, first tag+6, longshot tag+16, closing time+4  <- you
   3 7/pink            192    2     t2070  closing time+8, rank up+1
-- AFTER (seed-matched) --
rank seat/team        glory tags  survived  deeds
   1 12/lime          1536    1       end  closing time+4
   2 6/ivory            96    1     t1178  longshot tag+4, rank up+1
   3 3/yellow           48    0     t1640  rank up+1
   7 0/red              12    0     t1373  -  <- you
```

Top rows plus your own seat, never sixteen equal rows — the same rule the
hosted endcard uses.

## Submit

Submitting needs a GitHub account; sign-in is GitHub only.

```bash
uv run softmax login
uv run coworld upload-policy my-policy:local --name my-policy-v1
```

`softmax login` opens a browser to Softmax's sign-in, which is
**GitHub OAuth only** — there is no token or API-key alternative as of this
verification (`softmax login --help` exposes no such flag; confirmed by a
real account-creation run reaching this exact step). `--no-browser` skips
the auto-open but still requires completing the same GitHub flow manually.
`upload-policy`'s `--name` is optional (defaults to a name derived from your
active player) and `--tag KEY=VALUE` (repeatable) attaches your own
bookkeeping tags to the uploaded version.

```bash
uv run coworld submit my-policy-v1 --league league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7
```

`league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7` is Paintbot (Season 2)'s own
league ID — find it and every other public league's ID with
`uv run coworld leagues` (no login required to list; submitting does).
`submit` takes the policy name alone, or `NAME:vN` for a specific version;
`--auto-champion always` (the default) promotes it to your champion as soon
as it qualifies, and `--open-browser` (also the default) opens the resulting
policy page.

These four commands are copied unchanged from [[build-and-submit]]'s own
"Authenticate and upload" and "Submit to a league" steps — this page does
not repeat their own verification, it hands off to it.

## See also

- [[build-and-submit]] — the five-step walkthrough this page's "Submit"
  section defers to, including the `--run` and `--variant` traps in full
- [[battle-royale-s2]] — the ruleset your local episodes above actually run
- [[submitting-a-policy]] — the wire protocol and Docker packaging pattern
  the starters build on
- [`policies/starters/README.md`](../../policies/starters/README.md) — the
  starter's own layout, the three personas, and the traps found building
  them
- [`policies/poc_llm_policy/README.md`](../../policies/poc_llm_policy/README.md) —
  the lower-level protocol reference the starters' harness imports from

## Version history

| Version | Change |
| --- | --- |
| New page (2026-09-09) | Written to close J15/J16/J17/J18/J19 (docs/designs/JOURNEY_MAP.md): a human-voiced path from a fresh machine to a compared local episode, verified command-by-command on a fresh `$HOME`; ships alongside `policies/starters/pyproject.toml`, `.python-version`, `run_local.py`, `compare_local.py`, and `common/era.py`/`starter_knobs.py`/`parse_local_run.py`. |

## Gaps

- The deed-mint lines `compare_local.py` reads come from the game's own
  console log (`game.stdout.log`), not a documented wire API or
  `results.json` field — a future build could change or drop them without
  notice; the tool degrades to `results.json`'s columns only if so (see
  its own module docstring), it does not raise.
- A live, custom-image 16-seat episode through `run_local.py` was attempted
  repeatedly while writing this page and blocked by this environment's own
  Docker daemon contention against `coworld run-episode`'s internal,
  unconfigurable ~10-second game-startup probe — the identical invocation
  reached real play uploads before timing out. The bundled-baseline path
  (no custom image) ran reliably; a beginner on an unshared machine should
  not expect to hit this, but it is worth knowing the CLI has a fixed,
  short startup window with no flag to widen it.
- `[[glory-season-2]]` itself is still due its own refresh (see
  [[battle-royale-s2]]'s Gaps) — "read your score" above links it as the
  deed-pricing source of record, not as a page already verified current.
