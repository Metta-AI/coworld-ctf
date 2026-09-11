*Verified against [[versions|GV52 / Glory 13]].*

**Verified against `GV52 / Glory 13` — the live game is `GV63 / GLORYVERSION 17`; treat details as unconfirmed.**

On the Paintbot (Season 2) league's `battle-royale-s2` ladder (see
[[modes]]), Glory no longer prices deeds by addition at all: every deed and
every achievement claim folds one whole-number **factor** into a single
running **product** for the episode, starting from a seed of **1**. This
pricing table has been armed on that one ladder since round 3830 (build
0.7.310 and later) — every other paintbot-family ladder still runs the
additive pricing [[glory]] documents, unchanged. A team whose episode lands
no factor above ×1 banks exactly the seed, 1; a superb episode's total climbs into the
millions purely from how many above-and-beyond deeds land inside it, because
an all-×1 episode of ordinary tags can never move off the seed on its own.

## Stats

### The integer rung ladder

| Rung | Deeds |
| --- | --- |
| ×1 | `TAG`, `SPRAYED`, `BOMBED`, `POINT-BLANK`, `RANK UP`, "shield soak" and "clutch patch" (both blank-pop-word log names), Tier I, Tier II |
| ×2 | `FIRST!`, `ESCORT`, `ASSIST`, `CHASE`, `PAYBACK`, `RESCUE`, `DUO DOWN`, `TAG BACK`, `JOINT ACT`, Tier III, Tier IV |
| ×3 | `LONGSHOT`, `MULTI!`, `CLOSING TIME` |
| ×4 | `BOUNTY`, `STEAL`, `PEEL`, `LAST LIGHT`, Tier V |
| ×6 | `DENIED!` |
| ×8 | `CAPTURE`, `WIPEOUT`, `VICTORY` |

Pop words and log names, and every rung not listed above (the team-kill
penalty is a division, not a rung — see below), are [[deeds]]'s own table.
**Five of the rows above — `DUO DOWN`, `TAG BACK`, `JOINT ACT`, `CLOSING
TIME`, and `LAST LIGHT` — are deeds that exist only under this armed
pricing table and only in `battle-royale-s2`; [[deeds]]'s own count does
not include them.** `VICTORY`, an ×8 deed, was retired as of round 3871
(canonical build 0.7.320), when winning briefly stopped minting a deed at
all and was instead priced by a flat win factor folded directly into the
product at the episode's finalize step. That flat factor was rolled back
2026-09-04 after a scoring incident — see `## Rules` below for the factor,
the incident, and the rollback — and `VICTORY` is back in this table
because it mints again exactly as it did before round 3871.
`CLOSING TIME`'s own rung, which also moved in the 3871 build (×2 → ×3),
was not part of the rollback and stays at ×3. `TAG BACK` and `JOINT ACT`
were not so lucky: both mint only when `winAsMultiplier` is armed — the
exact flag the rollback turned off — so both currently mint zero
alongside the retired win factor they arrived with; the ×2 rung above is
their price if and when a future re-arming restores it, not their price
today. See `## Rules` for what each of the remaining new deeds fires on,
and for which of the flag-dependent rungs above (`CAPTURE`, `STEAL`,
`PEEL`, `DENIED!`, `ESCORT`) can never actually mint on this ladder's map.

### Other multipliers, carried over

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Episode seed | 1 | — | The running product's starting value; a no-deed episode scores exactly this |
| Ally-stack ladder | ×1 / ×2 / ×3 / ×5 / ×8 / ×13 | — | Keyed to 1–6+ teammates in context (Fibonacci, not linear) — see `## Rules` |
| Territory rung shift | +1 rung | — | Enemy-ground kills only; never applies to a ×1 common — see `## Rules` |
| Heat ladder | ×1 / ×2 / ×4 / ×8 | — | Same thresholds, decay, and ember cap as the additive economy — see [[glory]] |
| Carrier hold multiplier | ×2 | — | Same drama-deed gate as [[glory]]'s carry multiplier; structurally unreachable on this ladder's flagless map — see `## Rules` |
| Achievement first-claim bonus | ×3 | — | Tier V only, both teams, unchanged from [[glory]] |
| Friendly-fire divisor | ÷2 per incident | — | This ladder's rate (duos, no respawns) — see `## Rules` |
| BR win factor | ×8 `VICTORY` deed | — | Restored 2026-09-04 (commit `d595f300`) after a flat ×4 finalize-step factor, armed round 3871, was rolled back — see `## Rules` |
| BR product ceiling | 28,311,552 | — | The highest reachable product under this table's own maximum rungs; not itself enforced as a cap — the rolled-back ×4 win factor's interaction with an uncapped revive loop let real episodes reach 10^13–10^15 before the 2026-09-04 fix, see `## Rules` |
| Product overflow guard | 2^62 (~4.6 × 10^18) | — | A saturation ceiling, not an economy cap; unreached under any measured episode |

## Rules

### A running product, not a running sum

Every glory-earning fact on this ladder computes one whole-number factor —
never a fraction, never an addition — and that factor multiplies directly
into the episode's single running product for the earning team. In log
space this makes an episode's score exactly a sum of log-factors: the
exponential curve that used to be an emergent side effect of stacking
percentage bonuses is now the literal shape of the formula. As of round
3849 (canonical 0.7.317), the scorer that turns a team's total into that
episode's platform score is no longer win-gated: every seat banks its own
team's running product, win or lose — losing teams bank real scores, both
duo seats identically, and a bad enough total banks negative, with no
floor. Winning is priced inside the product instead, through the
`VICTORY` deed described below, rather than by a gate on who banks. See
[[glory]] for the seat-level banking rules.

### Winning: the flat factor's arming, the incident, and its rollback

As of round 3871 (canonical build 0.7.320), winning a `battle-royale-s2`
match stopped minting the `VICTORY` deed. In its place, the winning
team's running product was multiplied by a flat, deterministic **×4 win
factor** at the episode's finalize step, after every deed of the episode
had already minted. The factor was folded into the product outside
`recutFactor` entirely: it read no heat, no territory, no carry
multiplier, and no ally-stack factor, so its size did not depend on which
deeds a team happened to land on the way to the win — a stomp and a
last-second win banked the identical ×4. A losing team never received this
factor. The engine's own source tied the ×4 figure to a measured 23.2%
upset rate rather than a round number chosen for its own sake. The win
factor was mode-keyed at the code level — a separate, still-unarmed
constant is reserved for the classic (CTF) ladder's own eventual arming —
so this section describes `battle-royale-s2` only. Two new deeds armed in
the same build: `TAG BACK` (×2, reviving a downed duo partner, uncapped)
and `JOINT ACT` (×2, a 120-tick cross-duo assist window) — see the deed
table below.

**This produced a scoring incident.** Composed with 0.7.319's
zone-damage-follows-paint change, a duo could cycle a down-and-revive
loop roughly every 57 ticks inside the closing ring's paint, and each
cycle minted `TAG BACK`'s ×2 factor again into the running product. 24-27
such cycles in a single episode were enough to push the product to
10^13–10^15 — four to seven orders past this table's own 28,311,552
design ceiling (see `## Stats` above). The first poisoned round was
**3885**; eleven rounds in total carried at least one inflated episode
before the defect was caught and fixed: **3885, 3894, 3897, 3900, 3901,
3904, 3917, 3920, 3921, 3936, and 3938**.

**Fixed 2026-09-04.** The flat ×4 win factor (`winAsMultiplier`) is rolled
back, commit `d595f300`. `battle-royale-s2` wins price through the
restored `VICTORY` ×8 deed again — the code path that folds it into the
same heat/territory/carry pipeline as any other deed is back, exactly as
an earlier revision of this page described. The eleven poisoned rounds
were surgically excluded from standings and the board recomputed clean;
the same eleven are excluded from the platform's records and
all-time-high list. The legitimate all-time high stands at **3,375,440**,
round 3860, `eckstar-paintbot-s2-bounding:v1`. Clean play resumed at round 3953, the first round stamped to the rollback build — verified sane, with `winAsMultiplier` absent from its realized config.

A future re-arming of the flat win factor is expected, behind two
additional safeguards that have not shipped yet: disallowing a revive
while standing in zone-damage paint, and a per-episode cap on how many
times a single deed can mint.

### Ordinary play is neutral, not zero-weighted

A plain `TAG` and every other ×1 rung price at exactly 1: multiplying the
running product by 1 leaves it untouched, so ordinary kills and ordinary
competence do not move the score at all. Only above-and-beyond deeds do.
This continues the standing achievements rule (Glory rewards the
exceptional, not the routine) to its logical conclusion under a pure
multiplier: volume and win-rate live on [[elo]], and Glory measures density
of exceptional moments in one episode, not how many fights a team was in.

### Ground you're standing on shifts the rung, not the price

A deed minted on enemy ground — the same nearest-home-pedestal ownership
signal [[glory]]'s site gradient already reads — climbs one integer rung
higher than the identical deed on home ground: ×2→×3, ×3→×4, ×4→×5, ×6→×7,
×8→×9. **This never applies to a ×1 common, on any ground** — an ordinary
tag on enemy ground is still priced exactly like one on home ground; only
above-and-beyond deeds get the territory premium. Every team's home
pedestal exists on this ladder's map the same way it does everywhere else,
so the signal is live here even though the ladder has no flag to steal.

### Heat and the carry multiplier ride along as integer factors

A deed's rung is only the first term. If the deed's Drama price is positive
(the same gate [[deeds]] and [[glory]] already document), the territory-
shifted rung is multiplied by the heat ladder next, then by the carry
multiplier if the minting team currently holds an enemy flag, then by the
ally-stack factor below — in that order. **The carry multiplier is real
code on this path but cannot fire on `battle-royale-s2`'s own map: that map
carries no flag entity at all, so the "currently holding an enemy flag"
check is always false there.** It is documented here because it is part of
the same live pipeline, not because a duo can ever collect it.

*Worked example:* a `LONGSHOT` kill (rung ×3) landed on enemy ground
(→×4) by a team sitting at 5 cumulative embers (heat ×4), with no other
teammate in context (stack ×1): 4 × 4 × 1 = 16. That single kill folds a
factor of 16 into the running product.

### Stacking now grows Fibonacci, not linearly

When more than one teammate participates in the same moment, the ally-stack
factor climbs `1, 2, 3, 5, 8, 13` for `1` through `6` teammates in context
(clamped at both ends) rather than a flat per-head increment — a simple ×k
rule through 3 participants, diverging steeper above it while staying whole
and increasing. **On this duos ladder, "teammates in context" cannot mean a
literal same-team headcount — a team is only two seats.** It instead counts
every allied duo currently sharing the moment with you, so this ladder's
biggest single-event factors are only reachable through multiple duos
acting together, not a lone duo however skilled. Exactly which duos count
and how that window opens and closes is still being refined — see
`## Gaps`.

### Five deeds exist only on this ladder

`DUO DOWN` (×2), `TAG BACK` (×2), `JOINT ACT` (×2), `CLOSING TIME` (×3),
and `LAST LIGHT` (×4) mint only under this armed pricing table, and only
in `battle-royale-s2`. `TAG BACK` and `JOINT ACT` armed alongside the win
factor above, in the same build (round 3871, canonical 0.7.320), on the
exact same `winAsMultiplier` flag — so both are dark again too, at zero,
following that flag's 2026-09-04 rollback (see `## Stats` above);
`CLOSING TIME`'s rung moved from ×2 to ×3 in that same build:

| Deed | Rung | Fires on |
| --- | --- | --- |
| `DUO DOWN` | ×2 | A kill that leaves the victim's whole two-seat team dead |
| `TAG BACK` | ×2 | Reviving your downed duo partner, uncapped — minted to the tagger, from the same `Revived` event the downed state (see [[damage-and-health]]) already emits |
| `JOINT ACT` | ×2 | A second, distinct duo lands a qualifying hit on a victim already being damaged by another duo, inside a 120-tick cross-duo damage window — every contributing seat mints once per incident, priced at the victim's site |
| `CLOSING TIME` | ×3 | A kill landed while the shrinking zone's closing phase is actively running (raised from ×2) |
| `LAST LIGHT` | ×4 | A kill landed at or past the zone's last authored shrink phase |

`VICTORY` does not appear in this deed table because it is not one of the five deeds unique to this ladder — it lives in the integer rung ladder in `## Stats` above, at ×8. See `Winning: the flat factor's arming, the incident, and its rollback` above for the deed's own round-3871 retirement and 2026-09-04 restoration.

### Which of the classic rungs can actually mint here

Several rungs on the integer ladder above price a deed this ladder's own
map cannot produce, because `battle-royale-s2` carries no flag entity at
all: `STEAL`, `PEEL`, `DENIED!`, and `ESCORT` each need a flag or a flag
carrier that never exists here. `CAPTURE` needs that same flag and is also
disabled outright in every duos ruleset — the same gate [[glory]] already
documents. `ASSIST` and `RESCUE` are CTF-only outright (see [[deeds]]) and
never mint on any duos ladder. `WIPEOUT` — "the entire enemy team
eliminated" — is likewise disabled in every duos ruleset; `DUO DOWN` above
is this ladder's own equivalent of that same moment for a two-seat team.

### Friendly fire divides the running product, uncapped

A team-kill is not a rung at all — it advances a division counter instead.
On this duos ladder, every single team-kill incident halves the team's
running product; other paintbot-family modes with respawns instead halve
theirs once per two incidents. Neither rate has a cap or a floor: the
division compounds without limit, by design, because a two-seat team with
no respawns loses far more to one friendly-fire incident than a larger
roster that can recover. Because this is a division rather than an integer
rung, a badly-behaved episode's final reported score can land on a
non-whole number even though every rung along the way was a whole integer —
the platform's integer score reports the floor of that division, while the
exact value is kept losslessly underneath.

## Version history

| Version | Change |
| --- | --- |
| Unrecorded | Rolled back 2026-09-04 (commit `d595f300`): the flat ×4 win factor armed round 3871 is retired, and `battle-royale-s2` wins price through the restored `VICTORY` ×8 deed again. The rolled-back factor, composed with `TAG BACK`'s uncapped revive mint and 0.7.319's paint-following zone damage, had inflated 11 rounds' episode scores to 10^13–10^15 via a 57-tick revive loop (first poisoned round 3885; also 3894, 3897, 3900, 3901, 3904, 3917, 3920, 3921, 3936, 3938). All 11 are excluded from standings and from the platform's records/all-time-high list; the board was recomputed. Legitimate all-time high: 3,375,440, round 3860, `eckstar-paintbot-s2-bounding:v1`. `TAG BACK` and `JOINT ACT` share the exact same `winAsMultiplier` gate as the win factor and went dark with it — both currently mint zero, pending any future re-arming. See `## Rules` above. |
| Unrecorded | Winning `battle-royale-s2` stopped minting the `VICTORY` deed, verified live as of round 3871 (canonical build 0.7.320): the win became a flat, composition-neutral ×4 factor folded into the product at finalize, outside the heat/territory/carry pipeline entirely. Two deeds armed in the same build — `TAG BACK` (×2, revive-with-attribution) and `JOINT ACT` (×2, a 120-tick cross-duo damage-window assist) — and `CLOSING TIME`'s own rung moved ×2 → ×3. Superseded by the row above: the flat factor was rolled back 2026-09-04, and the ×8 `VICTORY`-deed description in the row below (which predates this row) is current again. |
| Unrecorded | The win gate on episode banking removed, verified live as of round 3849 (canonical 0.7.317): every seat banks its own team's running product win or lose — losing teams bank real scores, negative totals are possible (no floor). (The ×8 `VICTORY` factor this row originally described was briefly retired between rounds 3871 and 2026-09-04 — see the two rows above — and is live again now.) |
| Glory 13 (0.7.310+) | The pure-multiplier pricing table armed live on Paintbot (Season 2)'s `battle-royale-s2` ladder, beginning round 3830 — a live-service arming, not a change to the engine's own default (every other ladder keeps running [[glory]]'s additive pricing). |

## Gaps

- Whether a friendly-fire incident should count differently for downing a
  teammate (see [[damage-and-health]] for the downed state itself, already
  live on this ladder) versus that teammate later failing to recover, is an
  open design question — today every incident counts once, uniformly.
- Precisely which allied duos count toward the ally-stack factor in a given
  moment, and how that window opens and closes, is not finalized.
- Whether a `CAPTURE`/`WIPEOUT`-style deed ever gets a further "hot vs cold"
  split for how contested it was is unresolved — nothing in the armed table
  above does this today.
- The achievement Drama column's own rescale is untouched by this pricing
  table and remains a separate, unresolved question.
- `TAG BACK` and `JOINT ACT`, like `CLOSING TIME` and `LAST LIGHT` before
  them, carry no specced Drama price — held at 0 in the engine's own
  pricing table and flagged there as an open drama-column item rather
  than a resolved design choice. Zero Drama also means neither deed can
  climb heat or take the carry multiplier; only the territory shift can
  move either off its ×2 base.
- Whether `JOINT ACT` mints correctly when three or more duos contribute
  to the same 120-tick incident (does every seat from every duo mint, or
  only the qualifying pair) has not been checked against a live replay —
  this page reads the mint predicate from source, not from a played
  match.
- How often ordinary deeds actually land on enemy vs. home ground under this
  ladder's live traffic has not been measured; that commons never shift
  rung is verified by reading the pricing code, not by field measurement.
- Whether a jump to this much larger score scale resets, re-derives, or
  simply supersedes any record set before this table was armed has not
  been decided.
- Which of [[achievements]]'s 8 trees are actually reachable on a flagless
  duos map has not been audited on this page.
- Whether and when the flat ×4 win factor re-arms behind the two
  safeguards named in `## Rules` (no revives in zone-damage paint; a
  per-episode mint cap) is not yet decided or scheduled.

## See also

- [[glory]] — the additive pricing table this page's rungs replace on one ladder only
- [[deeds]] — the full per-deed pop words, log names, and triggers this page's rungs price
- [[achievements]] — the 8 trees and 5 tiers the Tier I–V rungs above price
- [[round]] — how an episode's score rolls into a round and a season standing
- [[modes]] — what `battle-royale-s2` configures
- [[elo]] — what a round score feeds where a ladder runs one
- [[scoring]] — match reward, kept separate from Glory
- [[battle-royale-s2]] — this ladder's own ruleset, still undocumented
- [[versions]] — what the GV/Glory stamp means
- [[conventions]] — the version-stamp format and the live-service rule

## Discussion

Whether the multiplier economy rewards the right kind of play, and any
episode-score distributions you've tracked yourself, belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.

