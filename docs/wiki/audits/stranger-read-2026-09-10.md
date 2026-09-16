# Stranger read — run #1

- **Date:** 2026-09-10
- **Era at run time:** Live variant `battle-royale-s2`, Build tag
  `paintbot-v0.7.392`, GameVersion 63, GLORYVERSION 17 (per `docs/wiki/_era.md`).
- **Reader:** haiku-class model, fresh agent, no repo/memory context — given
  only `tools/wiki/stranger_read.md`'s prompt.
- **Result:** 10 fetches, 78 s, 7/8 correct.

Raw output below, as produced by the run (own-words answers, slug
citations, then the four brief reports, then the ordered slug list — see
`tools/wiki/stranger_read.md` for the prompt that produced this and the
rubric it was scored against).

```
1. What is this? Paintbot is a paintball-style battle royale where AI
   policies — not humans — pilot small robots called Cogs. A hit removes
   hit points; a Cog at zero HP is "tagged out." The round ends the instant
   one Cog is the last one standing. [main]

2. Why would I care? The wiki frames it as a testbed: you write your own
   "brain" (policy), drop it into the field to fight everyone else's, and
   every move it makes is on the record for you to watch and study. It
   doesn't pitch prizes or money — the payoff is watching your own policy
   perform. [main]

3. How does it work? It's a continuous loop, not one match: you write a
   policy, it plays episodes against the field around the clock, every
   notable thing it does ("deed") mints Glory, and your standing is a
   decaying average of your recent episodes rather than a single score.
   You can watch any episode's replay to see why it scored what it did.
   [main, episode]

4. What is happening right now? NOT ANSWERED BY THE WIKI for live numbers
   — I could not find any page showing a current round, current
   standings, or who's live right now. The wiki explains that a round is
   a scheduled batch of episodes and standings roll up recent rounds, but
   never shows current state; I expected a current standings/ladder page
   and there wasn't one — it likely exists on the platform, not in the
   wiki. [main, round, league]

5. How do I get in? Install the `coworld` CLI and download the game's
   coworld package, run a local episode against the bundled baseline
   (naming the ruleset explicitly), then package your own policy as a
   `linux/amd64` Docker image. To actually enter competition you upload
   that image and submit it to a league, which requires signing in with a
   GitHub account first — there's no email/password option. [build-and-submit]

6. What does winning take? Score comes from "deeds" — things your Cog
   does — each minting Glory, and multipliers stack the more of them you
   pull off before the episode ends; deeds multiply it up to ×8 VICTORY.
   Standing itself is a decaying average of your Glory across recent
   episodes, not your single best round. [glory, glory-season-2]

7. Who else is here? You compete inside leagues, organized into
   divisions, where a round is a batch of episodes scheduled for your
   division. Your "champion" isn't a title for winning — it's just the
   policy currently seated to represent you. I didn't find a live list of
   current opponents in the wiki itself. [league, round]

8. What just happened? There's a dedicated patch-notes page that logs the
   versions at which the actual play changed — that's where you'd look
   for recent rule or balance changes, as opposed to day-to-day wiki
   edits. [patch-notes]

Which page answered each question: Q1 main · Q2 main · Q3 main, episode ·
Q4 main, round, league (no live-state page found) · Q5 build-and-submit ·
Q6 glory, glory-season-2 · Q7 league, round · Q8 patch-notes.

Disagreements: none between two live pages directly — the only
disagreement-shaped thing I saw was each page's own staleness banner
("Verified against GV<old> / Glory<old> — the live game is GV63 /
GLORYVERSION 17"), which is the wiki flagging itself as behind, not two
pages contradicting each other.

Unexplained terms: sprite (used but never defined), pact (glossary says
what it is — an agreement not to fight — but never how or where one
forms), deeds, XP, ranks.

Where I felt lost: after reading `round` and `league`, looking for
anything showing the *current* state of the ladder — a live standings or
in-progress-round view. Nothing in the wiki pointed me anywhere next; I
had to conclude that page doesn't exist here.

Slugs read, in order: main, battle-royale-s2, glory, build-and-submit,
episode, round, patch-notes, glossary, glory-season-2, league.
```

## Scoring against the rubric (`tools/wiki/stranger_read.md`)

| Q | Verdict | Note |
| - | ------- | ---- |
| 1 | correct | matches rubric line |
| 2 | correct | matches rubric line |
| 3 | correct | matches rubric line |
| 4 | **partial** | correctly reports no live-state page exists; the "missing rung" |
| 5 | correct | full five-step sequence, GitHub OAuth called out |
| 6 | correct (shape) — **1 stale claim carried** | shape (deeds → Glory → multipliers → decaying standing) is right; "×8 VICTORY" is `glory-season-2`'s own stale claim (banner verifies GV52/Glory13 vs live GV63/Glory17), repeated without flagging it as possibly stale |
| 7 | correct | leagues/divisions/rounds/champion shape right; live opponent list absent, same gap class as Q4 |
| 8 | correct | matches rubric line |

**Stale claims:** `glory-season-2` — "deeds multiply it up to ×8 VICTORY" — banner verifies `GV52 / Glory 13` against a live `GV63 / Glory 17`.

**Missing rungs:** Q4 — no live-state (current round/standings) page anywhere in the wiki.
