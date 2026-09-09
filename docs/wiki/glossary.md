*Verified against `paintbot-v0.7.377` (GV62 / GLORYVERSION 17), 2026-09-09 — see `docs/wiki/_era.md`.*

One line each for the words the strip, the endcard and the standings use.
These sentences are shared with the game client — the client renders the
same ones — so they are written here exactly once and quoted verbatim
everywhere else, per `docs/designs/THE_WHOLE.md` Law 1 ("one vocabulary, one
glossary"). Do not paraphrase these when linking to them; link the word,
don't restate the sentence.

## Terms

- **Glory** — "Glory is what one policy earns in one episode: every deed mints some, and the multipliers stack the more it does before the end."
- **deed** — "A deed is one thing a cog did that the game pays for."
- **multiplier** — "This number is the team's running multiplier; every pop stacks it."
- **pact** — "These two share a pact: they won't fight each other."
- **heat** — "Scoring fast; keeps climbing while it's hot."
- **intent** — "What this cog is doing right now."
- **downed** — "Downed — can still be rescued."
- **standing** — "Your standing is a decaying average of your recent episodes' Glory, not your best one."
- **round** — A round is a scheduled batch of episodes for one division;
  your round score is built from your episodes inside it, not from any
  one of them alone.
- **episode** — An episode is one complete match of Paintbot, start to
  finish — the thing you watch end to end on the stage.
- **division** — A division is a skill tier inside a league; a round is
  scheduled per division, never per league as a whole.
- **champion** — Champion does not mean winner: it means one of your
  policy versions is currently seated to compete for you in a league — a
  location, not a verdict.

## Standings labels

- **LEADER** — Marks the top row of a standings list: the entrant currently
  ranked #1 in that division.
- **"+N behind"** — How far this row's standing trails the leader's, in the
  same units as the standing column.
- **MOST LETHAL** — not yet defined by the game. No code path or existing
  page computing this award label was found; do not guess what it measures.
- **UNTOUCHABLE** — not yet defined by the game. Same gap as MOST LETHAL.
- **THE CLOSER** — not yet defined by the game. Same gap as MOST LETHAL.
- **POINT MACHINE** — not yet defined by the game. Same gap as MOST LETHAL.

## Gaps

- The four "LEAGUE LEADERS" award labels (MOST LETHAL, UNTOUCHABLE, THE
  CLOSER, POINT MACHINE) are shown live on the standings panel with no
  on-page definition anywhere found — not in this repo's code, not on any
  audited wiki page. `docs/designs/journey-map/jm-after.md` records the
  same gap from a real stranger run. Owning lane: Observatory epic (the
  panel that renders them) — see `docs/designs/THE_WHOLE.md` Stop 6.
- Whether "+N behind" is computed against the leader's standing or against
  some other reference row was not independently re-derived here; it
  follows directly from `LEADER`/`+N behind` appearing side by side in the
  live panel (`jm-after.md`), not from a code read.

## See also

- [[main]] — every use of these words on the front page links back here
- `docs/wiki/_era.md` — the live-ruleset record this page's banner is
  stamped from
- [[conventions]] — the wiki's own style rules, including the mechanic vs.
  chrome split these definitions follow

## Discussion

Whether a label should exist at all, or what it should measure, belongs on
[the forum](https://softmax.com/paintbot/forum) rather than here.
