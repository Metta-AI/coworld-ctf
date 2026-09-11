# Live ruleset record — the one place these numbers are written

Not a wiki page (leading underscore; `render_era_banner.py` reads it, and it
should not be published to `https://softmax.com/paintbot/wiki` as a
sidebar entry). This is Law 2 of `docs/designs/THE_WHOLE.md`: "era truth is
sourced, never typed" — every page's banner is stamped from this file, and
no other page in this repo's `docs/wiki/` should hard-code the numbers
below. If a value here changes, edit this file once; the banner script
propagates the staleness warning everywhere else automatically.

Each field is a single fenced line so the script can parse it with a plain
regex; do not reflow these into prose.

**Second consumer, not just the banner script:** `policies/starters/common/era.py`
mirrors the Live variant / Build tag / GameVersion / GLORYVERSION fields
below as Python literals (a beginner's standalone copy of
`policies/starters/` ships without `docs/`, so it cannot parse this file
at import time). When you change a value here, also update `era.py` to
match — `policies/starters/common/test_era.py` (wired into CI as the
`era-tripwire` job) asserts the two agree, so forgetting fails the PR
rather than drifting silently.

- **Date recorded:** 2026-09-11
- **Live variant:** `battle-royale-s2`
- **Build tag:** `paintbot-v0.7.397`
- **GameVersion:** 63
- **GLORYVERSION:** 18
- **Era note:** GLORYVERSION 18 (#538, 1b92ec46): GLORY GRADIENT S8 — mint-
  cap ceiling 2^21, achievement Tiers IV/V retuned, tier-completion bonus
  armed, PLACEMENT LADDER B; scoring only, GameVersion unchanged.
- **Standing rule:** Standing is a decaying average (an EMA, aggregation
  mode `rated`) of your recent rounds' scores, `rated_k` 0.05 — not a
  running total and not your single best round.
- **Season leg transform:** `none` (not armed). The Glory lane is arming a
  `signed_log2` transform with `rated_k` retuned to 0.025 as of today's
  date above — treat that as in-flight, not yet the live rule, and re-read
  this file rather than trusting a cached copy of this sentence before
  citing either number.

## Why this file, not a wiki page

The live-service values above (variant, standing rule, transform) can move
on a settings POST with no engine version bump — see the live wiki's
`[[conventions]]` page, "Live-service note" convention. `GameVersion` and
`GLORYVERSION` move on a deploy. All four are one fact each, recorded once
here; every other page in this repo's `docs/wiki/` states the *rule* in
words (`docs/wiki/glossary.md`'s "standing" line, for example) without
repeating the `rated_k` constant — this file is the only one that should
contain the literal number `0.05` or `0.025` for that constant. If you are
about to type `rated_k` followed by a number anywhere else in this repo's
`docs/wiki/`, stop and link here instead.

## What the banner script does with this

`tools/wiki/render_era_banner.py` reads `GameVersion` and `GLORYVERSION`
above, scans every other `docs/wiki/*.md` page's first line for its own
`Verified against ... GV<n> ... Glory <n>` (or `GV<n> / Glory <n>`) stamp,
and — when that page's stamped pair is older than the pair above — inserts
one line immediately after the page's own stamp:

> **Verified against `<page's own stamp>` — the live game is
> `GV63 / GLORYVERSION 18`; treat details as unconfirmed.**

The page's own original stamp line is never edited or removed — the
banner is additive, so a re-verification still has the old stamp to diff
against. A page whose stamp matches or is newer than this file's pair is
left untouched (no banner line added).
