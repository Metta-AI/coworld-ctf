*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

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
- **sprite** — A sprite is the game's basic drawable object: every cog,
  dropped item, planted flag, pickup, and on-screen readout is one sprite
  (or a small stack of them), each carrying its own id and, for anything
  that needs one, a short text label. A policy's own view is built from
  exactly the same list a human's screen renders from — it receives
  labelled sprite objects once a tick, never pixels.
- **survival credit** — A living seat's running Glory compounds on its own,
  with no tag or claim needed: every 30 seconds it stays alive, its team's
  product folds another ×1.02. That alone compounds to roughly ×1.16 over
  a typical episode. It rides alongside placement, not in place of it — a
  seat that survives longer both climbs the placement ladder and banks
  more of this credit — but it shows no popup or rail event of its own
  today.

*Era: the "sprite" entry above traced against `paintbot-v0.7.392` (GV63 /
GLORYVERSION 17), 2026-09-11 — see `docs/wiki/_era.md`.*

## How a pact forms

A pact is mutual or it does not exist: it forms only in the instant both
teams are naming each other as allies at the same time. One team alone
naming the other does nothing observable — there is no invitation-and-accept
step. The moment both sides are naming each other, the pact is live
immediately, with no delay.

It ends just as abruptly. Dropping the other team from your own naming, or
landing a damaging hit on your pact ally, dissolves the pact the same
instant — no grace period, and no permission needed from the other side
either way.

Naming an ally in the pre-match huddle chat does not by itself make a pact:
the game only counts naming that is still current once the match is under
way, so an alliance only discussed in the huddle has to still be named after
kickoff to actually take effect.

The only live signal a spectator gets is on the broadcast strip: a team
currently in a pact shows a colored ring around its life indicator, tinted
to its partner's color. There is no separate cue for the moment a pact forms
or breaks — only whether that ring is showing right now.

*Traced against `paintbot-v0.7.392` (GV63 / GLORYVERSION 17), 2026-09-11 —
see `docs/wiki/_era.md`.*

## Standings labels

- **LEADER** — Marks the top row of a standings list: the entrant currently
  ranked #1 in that division.
- **"+N behind"** — How far this row's standing trails the leader's, in the
  same units as the standing column.
- **MOST LETHAL** — The policy with the most tags per seat-game held, among
  policies with at least 8 games played.
- **UNTOUCHABLE** — The policy with the fewest tags taken per seat-game
  held, among policies with at least 8 games played.
- **THE CLOSER** — The policy with the highest win rate, among policies
  with at least 8 games played (a policy's seats share one verdict).
- **POINT MACHINE** — The policy with the highest mean recorded score per
  seat-game held, among policies with at least 8 games played.

*Era: these four are computed by the paintbot-superlatives reporter
(`reporters/paintbot-superlatives/app.py`) in the metta monorepo, read at
`origin/main` commit `a0cbf6d024` (2026-09-09).*

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
