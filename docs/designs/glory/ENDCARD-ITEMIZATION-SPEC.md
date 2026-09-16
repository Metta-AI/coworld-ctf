# Endcard per-player itemization — SPEC ONLY

Program `25d9108e` (GLORY GRADIENT), step S6. **This document is a
specification, not an implementation.** No endcard code, no wire schema, and
no client bundle changes ship in this PR or any PR this document is part of.

**Ownership**: the endcard surface belongs to the journey lane (epic
`16d081ab`), gated "ONE BUNDLE AUTHOR AT A TIME" through the lead — the S2
gate-open ruling (2026-09-09) is explicit that "S4/S6 must not author
endcard changes unilaterally." This document exists so the journey lane has
a concrete starting brief instead of a one-line ask, and so the lead's gate
has something specific to approve or redirect. Nobody should read a line of
Nim or TypeScript changing because of this file.

## What the design calls for

Today's endcard shows one number per player/team: the **match glory
roll-up** (the final `teamGlory` total, described in RULES.md's "Season 2
glory scoring" section). It is a total with no breakdown — a player who
scored 40 points from three big tags and a player who scored 40 points from
one lucky finish-line credit see the identical card.

The design ask (lead ruling, gap 3, 2026-09-09): "endcard work = per-player
ITEMIZATION on top of the existing MATCH GLORY roll-up." Concretely, each
player's (or team's, in solo BR where a player IS a team — see "attribution"
below) card should expand the single total into a short, ordered list of
**what contributed to it**, each row carrying:

- a **player-facing category label** — never an internal deed symbol. No
  `dHonorableKill`, `dLongshotKill`, `dDuoDown`, `RecutClassTable`, no
  "deed-points." The doctrine this project already holds itself to
  elsewhere applies here without exception: labels are the perception API,
  and this is the most player-visible label surface the game has.
- a **count** — how many times that category fired this match.
- its **contribution** to the total — either an absolute glory amount or a
  share of the total, whichever the journey lane's own layout work finds
  reads better on a small card; this spec does not prescribe the exact
  visual (bar, number, or both).

### Proposed category vocabulary (a starting list, not a ruling)

Matching the player-facing vocabulary already used in RULES.md and the
catalog-v3 rules text this PR adds:

| category label | rolls up |
| --- | --- |
| Tags | ordinary kill-class tags (the bulk of most players' totals) |
| Hot streak bonus | the heat-rung multiplier on a tag |
| Contested ground | the enemy-territory rung shift |
| Squad assist | the teammates-in-range stack multiplier |
| Ally revive / assist | tagging a downed ally back in, or covering the revive |
| Allied takedown / wipe-out | a kill that downs or wipes an allied enemy GROUP, not just one team |
| Finish bonus | the last-8 / last-4 / final-2 placement milestones |
| Survival bonus | the new continuous survival-duration trickle (S6, if it ships) |
| Win bonus | the win factor at finalize |
| Team-kill penalty | the friendly-fire division — shown as a **drain cue**, not a normal pop (see below) |

This table is illustrative, sized to what a player can act on next time, not
to how many internal `Deed` enum values exist (there are dozens; a card with
dozens of rows is not an itemization, it is a dump). The exact grouping is a
call for whoever implements this, informed by which categories actually
carry non-trivial share in real games (the S1 census and S5 rig's own
per-class breakdowns, both already measured, are a reasonable starting
weight).

**The drain cue** (named, not designed, in the S4 freeze notes): a category
that REDUCES the total — today only the friendly-fire division — needs its
own distinct, muted visual treatment in the pop vocabulary, distinct from a
normal "+N" pop, so a player can tell "this hurt my score" from "this helped
it" at a glance. This spec flags the need; the exact visual is the journey
lane's to design.

## Where it lives

Proposed home: **nested directly under each player/team's existing
match-glory total on the endcard**, not a separate screen or a required
click-through — an itemization nobody opens is not legible. A collapsed
default with an expand affordance is a reasonable compromise if card density
is a concern; that is a layout call, not a scoring one.

A related but SEPARATE surface — a live, in-match HUD strip echoing the same
drain-cue vocabulary during play, not just at the endcard — was also named
in the S4 freeze notes as a likely future home. This spec does not cover it;
it is mentioned only so the journey lane does not design the endcard version
in a way that forecloses a later HUD echo using the same category
vocabulary and the same wire data.

## What it needs from the wire — the actual gap

This is the part worth writing down carefully, because the naive assumption
("just read the existing per-deed counters") does not hold. Traced against
the real engine (`src/ctf/sim.nim`, `src/ctf/sim_types.nim`,
`src/ctf/glory.nim`) as of this PR's base:

1. **Glory is a TEAM stat, not a player stat.** `teamGlory`/`gloryProduct`
   (`sim_types.nim`) are indexed by `Team`, never by seat/player. In a
   16-solo BR game a team IS one player, so this is moot; in CTF or a
   multi-cog squad (`cogsPerTeam` > 1), an itemization that is
   player-accurate — not just team-accurate — needs an INTRA-team
   attribution the engine does not durably track today.
2. **The existing "audit" counters are whole-episode, not even per-team.**
   `deedCounts*: array[Deed, int]` and `deedGloryMass*: array[Deed, int]`
   (`sim_types.nim`, "GLORY AUDIT: ... Not in gameHash — audit telemetry
   only") sum every mint from every team in the whole episode into one
   array. They cannot back a per-TEAM breakdown, let alone a per-PLAYER
   one, as they stand — they answer "how many times did X fire this
   match," never "for whom."
3. **`awardDeed`'s own earner argument is explicitly cosmetic, not
   durable.** `awardDeed*(sim, team, deed, x, y, times, byIndex, fxActor,
   stackK)` (`sim.nim`) takes a `byIndex` — "the EARNER" — but its own doc
   comment is direct: *"`byIndex` is the EARNER and is cosmetic only: it
   moves the score pop, never the money."* It drives the live floating
   "+Ng" pop and nothing else — not hashed, not summarized, not present at
   finalize. A second, separate `fxActor` parameter feeds a private toast
   wire (`GameConfig.allowCosmeticFx`) and is wired at only **two** call
   sites in the whole engine (the kill-deed mint in `killPlayer`, and
   `dCapture` in `checkWinCondition`) — every other deed family (placement
   milestones, achievement claims, the survival credit, pact-scope
   marquees) mints with no actor at all.
4. **The raw event stream is the best source available today, and it is
   still incomplete.** Some deed families already emit a `GloryDeed`
   tier-2 event carrying a real `source` seat index (ordinary kills via
   `killPlayer`, and S5's own cap-hit/pact-scope-marquee events) — a
   client could reconstruct a partial per-player breakdown for THOSE
   families with zero engine change, by aggregating the existing wire.
   But placement milestones and the survival credit are inherently
   TEAM-level facts (the whole team crosses a milestone or survives
   together) with no single "actor" to attribute to a player at all — at
   best these attribute to the team, never a specific teammate — and
   achievement claims mint through `awardDeed` with no actor parameter
   populated, so they are invisible to any client-side reconstruction.

**Conclusion**: closing this gap for real needs one of two engine-side
choices — (a) a durable, per-seat breakdown emitted at finalize, mirroring
the existing realized-config stamp's own idiom (an events-summary-row field
plus a game-over-log line, `stampRealizedConfig`'s own home), or (b)
promoting `byIndex`/`fxActor` from cosmetic-only to a durable, comprehensive
per-mint attribution wired at every call site, not just two. Both are real
engine changes with their own GameVersion/wire-schema questions — **neither
is this document's to decide.** This spec's job is only to name the gap
precisely enough that whoever picks up the implementation does not
discover it three weeks in: "per-player itemization" cannot be built from
what the wire carries today without picking (a) or (b) first, and that
choice belongs at the lead's gate, not to a unilateral implementation PR.

## What this document explicitly does not do

- Does not add, rename, or remove any `GameConfig` field, wire key, or
  `SimServer` struct field.
- Does not touch `static-replay-viewer/` or any endcard client code.
- Does not choose category groupings, visual treatment, or the (a)/(b)
  attribution-mechanism question above — those are implementation calls for
  whoever the lead's gate assigns this to (journey lane, per epic
  `16d081ab`'s own ownership of the endcard surface).
