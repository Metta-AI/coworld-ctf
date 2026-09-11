# Stranger read — the wiki acceptance test

## Purpose

This test proves the *book* (`https://softmax.com/paintbot/wiki`) can, on its
own, answer the eight questions a newcomer actually asks — a reader with no
prior context, given only the live wiki API and nothing else, either finds a
correct answer or correctly reports that the wiki doesn't have one. It does
**not** test the *door* (the public `/paintbot` landing page, sign-up, or
play flow — that is `docs/designs/STRANGER_WALK.md`'s job), and it does not
test whether the wiki is *well written*, only whether the facts it states are
current and complete enough for a cold read to land on the right answer.

## The stranger prompt — verbatim

Keep this byte-for-byte except the two `<…>` placeholders (there are none in
the current prompt — every value below, including the API URL, is meant to
be sent exactly as written):

```
You are a STRANGER. You have never heard of Paintbot, Softmax, Coworld, or this project. You know nothing about it and you must not use anything you might already believe — only what you READ on one public wiki. You are answering eight questions a newcomer would ask, using ONLY that wiki.

# Hard rules
- **Read ONLY the live wiki.** Start at the front page: `GET https://softmax.com/api/observatory/v2/wikis/paintbot/pages/main` (plain `curl -s`, no auth). The JSON has the page body in a field — find it (`jq` it; look for `body`/`content`/`markdown`). You may follow `[[wikilinks]]` by fetching `…/pages/<slug>` for slugs you see on pages you have read. Do not open any other website, any file on this machine, any git repo, or any documentation outside that wiki API. Do not search the filesystem. If a question cannot be answered from the wiki, say "NOT ANSWERED BY THE WIKI" — that is a valid and important answer.
- Save every page you fetch to `/tmp/wiki-stranger/<slug>.md` and keep a list of the slugs you read, in order.
- Budget: at most 12 page fetches. Read the front page fully first.
- Answer in YOUR OWN WORDS (2–3 sentences each). Do not quote the wiki verbatim. For each answer, name the slug(s) it came from.

# The eight questions
1. What is this? (the game, in one breath — who plays, what the objective is, how a round ends)
2. Why would I care? (what's in it for someone like me, in the wiki's own framing)
3. How does it work? (the loop: what runs, how often, what produces a score)
4. What is happening right now? (is there a live league; how would I see the current state)
5. How do I get in? (the concrete first steps to enter — commands or pages, in order)
6. What does winning take? (how score/glory/standing is actually earned — the shape, not the constants)
7. Who else is here? (who am I competing against; how would I find them)
8. What just happened? (where would I learn about recent changes to the game or rules)

# Also report, briefly
- Which page answered each question (slug list).
- Any place where two pages DISAGREED with each other (quote the two claims, ≤1 line each, with slugs) — a stale page is exactly what this test is for.
- Any word or symbol you did not understand that the wiki never explained (list, ≤10).
- Where you felt lost: the first moment you did not know where to click next.

# Output
Plain text, under 60 lines: the eight numbered answers with slugs, then the four brief reports, then the ordered list of slugs you read.
```

## How to run it

1. Spawn a **haiku**-class model as a fresh agent, given that prompt above
   and **nothing else** — no repo, no memory, no prior transcript, no tools
   beyond `curl`/`jq`/a scratch directory.
2. Before launching, note the live era from `docs/wiki/_era.md` (Build tag,
   GameVersion, GLORYVERSION) and today's date — the run record needs both.
3. Let it run to completion or its own budget/give-up condition; do not feed
   it hints mid-run.
4. Save its raw output verbatim to `docs/wiki/audits/stranger-read-<date>.md`
   (create the `docs/wiki/audits/` directory the first time).
5. Score it against the rubric below and fold the verdict into that same
   audit file (or a short summary appended here, as `## Run #N record`).

## The judge rubric

One to two lines per question, naming what a **correct** answer must
contain, from the current truth on `main`:

1. **What is this?** — AI policies (not humans) pilot Cogs in a paintball
   elimination format; a hit removes hit points, zero HP is "tagged out",
   and the round ends when one Cog (today, one *seat*) is left standing.
   `docs/wiki/main.md` ("What is this").
2. **Why would I care?** — framed as a testbed to put your own policy
   ("brain") into the field against others and watch it fight, with every
   move on the record — not a prize/money pitch. `docs/wiki/main.md` ("Why
   would I care").
3. **How does it work?** — the loop, not a single match: write a policy →
   it plays episodes continuously against the field → deeds mint Glory →
   standing is a decaying average of recent episodes → replays show why.
   `docs/wiki/main.md` ("How it works").
4. **What is happening right now?** — the wiki has **no live-state page**
   (no current standings/current-round view); the correct answer either
   says so directly or answers "NOT ANSWERED BY THE WIKI" for the live
   numbers, while may still correctly describe the *mechanism* (a round is
   a scheduled batch of episodes) from `docs/wiki/main.md` ("How to read
   the ladder"). Claiming the wiki shows live standings is wrong.
5. **How do I get in?** — the concrete CLI sequence in order: install the
   `coworld` CLI and download the coworld, run a local episode (naming
   `--variant`), package a `linux/amd64` Docker image, then
   `upload-policy`/`submit`, which requires GitHub OAuth sign-in.
   `docs/wiki/build-and-submit.md` (all five numbered steps).
6. **What does winning take?** — the *shape*: deeds mint Glory, multipliers
   stack the more a cog does, and standing is a decaying average (an EMA)
   of recent episodes' Glory, never a single best round or running total.
   A correct answer should not assert a specific live multiplier constant
   as current fact. `docs/wiki/main.md` ("How scoring works") and
   `docs/wiki/_era.md` (standing is `rated`-mode EMA; the exact `rated_k`
   is a live-service number that moves independently of this page).
7. **Who else is here?** — entrants compete inside leagues, not single
   episodes; a round is a scheduled batch of episodes for a division, and
   "champion" names a current roster, not a winner. No live opponent list
   exists in the wiki — same live-state gap as Q4, so partial credit is
   expected here too. `docs/wiki/main.md` ("How to read the ladder").
8. **What just happened?** — the strategy-relevant change log is a
   dedicated page (`patch-notes`, linked from `main`'s "Competition, in
   depth" table) that records the versions at which play itself changed.
   `docs/wiki/main.md` ("Competition, in depth").

**Scoring.** Each answer is one of: **correct** (matches the rubric line,
in the reader's own words), **partial** (gets the shape right but misses or
garbles a piece), **wrong** (contradicts the rubric line), or
**NOT-ANSWERED** (the reader said the wiki doesn't cover it). A run must
additionally surface, as two explicit lists:

- **Stale claims** — any answer that is only correct because it repeated a
  wiki page's own out-of-date claim; name the slug and quote the claim.
- **Missing rungs** — any question that scored NOT-ANSWERED because no wiki
  page covers it at all; that is a real gap in the book, not a reader
  failure.

## Run #1 record (2026-09-10, GV63 / paintbot-v0.7.392 / GLORYVERSION 17)

Full raw output: `docs/wiki/audits/stranger-read-2026-09-10.md`.

**7 of 8 correct** in the reader's own words. **Q4 PARTIAL** — no live
state in the wiki; rung 4 confirmed missing (the reader wrote: "expected a
current standings/ladder page… exists on the platform, not in the wiki").
**Q6 carried one stale claim** — "deeds multiply it up to ×8 VICTORY", read
from `glory-season-2`, whose own banner verifies only `GV52 / Glory 13`
against a live `GV63 / Glory 17`. Disagreements found: only the banner
staleness warnings themselves (pages verified at old GV numbers vs. the
live `GV63`), no two live pages contradicted each other directly.
Unexplained terms: *sprite* (never defined), *pact* (glossary states what
it is but never how or where one forms), *deeds*, *XP*/*ranks*. Lost at: no
live ladder page anywhere in the wiki. Pages read, in order: `main`,
`battle-royale-s2`, `glory`, `build-and-submit`, `episode`, `round`,
`patch-notes`, `glossary`, `glory-season-2`, `league` — 10 fetches, 78 s.

## Open items this run produced

- **Rung 4** — the wiki needs some page (or an explicit "see the platform,
  not the wiki" pointer) for "what's happening right now" / live state.
- **Re-trace `glory-season-2`** — its banner still verifies `GV52 / Glory
  13` against a live `GV63 / Glory 17`; the ×8 `VICTORY` claim is the
  concrete stale fact Q6 caught.
- **Re-trace `ranks`** — flagged stale by the same GV52/GV63 gap; not
  independently re-checked by this run.
- **Glossary entries** for "sprite" (undefined anywhere) and for *how* a
  pact forms (the glossary defines *what* a pact is but not the mechanism).
