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

- **Date recorded:** 2026-09-18
- **Live variant:** `battle-royale-s2`
- **Build tag:** `paintbot-v0.7.397`
- **GameVersion:** 63
- **GLORYVERSION:** 18
- **Era note:** GLORYVERSION 18 (#538, 1b92ec46): GLORY GRADIENT S8 — mint-
  cap ceiling 2^21, achievement Tiers IV/V retuned, tier-completion bonus
  armed, PLACEMENT LADDER B; scoring only, GameVersion unchanged.
- **Standing rule:** Standing is a decaying average (an EMA, aggregation
  mode `rated`) of your recent rounds' scores, `rated_k` **0.02** (retuned
  down from 0.05, live since 2026-09-15) — not a running total and not
  your single best round. At this `rated_k`, a round's weight washes out
  by half after roughly 35 rounds scored.
- **Season leg transform:** live and armed since 2026-09-15: a round leg
  only banks if that seat's score was the top score (or tied for it) among
  the episode's scored seats — a loss banks zero regardless of margin —
  and what a won leg banks is a signed, sign-preserving log-base-2
  rescaling of the raw score, not the raw score itself. Doubling a raw
  score only adds one point to the banked leg; winning an episode you
  would otherwise have lost adds that whole banked amount. A round's score
  is the sum of an entrant's (up to 12) scored legs.
- **Round-score aggregation fix:** from round #5519 (2026-09-17) the
  round score above is a true sum of the scored legs; rounds before that
  date (back to the 2026-09-15 arm) silently divided the sum by the
  number of legs instead — standings from the two windows are not on the
  same scale.

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
