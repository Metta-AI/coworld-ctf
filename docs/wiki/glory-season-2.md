*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

On the Paintbot (Season 2) league's `battle-royale-s2` ladder (see
[[modes]]), Glory prices deeds and achievements by multiplication, not
addition: every deed and every achievement claim folds a **factor** into a
single running **product** for the episode, starting from a seed of **1**.
This pricing table has been armed on that one ladder since round 3830
(build 0.7.310 and later) — every other paintbot-family ladder still runs
the additive pricing [[glory]] documents, unchanged. Since **GLORYVERSION
17** the factors are no longer restricted to whole integers: most deeds now
fold a **percent-scaled** multiplier, kept exact by an internal fixed-point
accumulator so a small nudge like ×1.15 registers instead of rounding away
to nothing. The table below is the current, **GLORYVERSION 18** (S8,
2026-09-09) shape of that pricing.

**The ladder itself changed shape underneath this pricing table.**
`battle-royale-s2` ran as eight two-seat duo teams when this page was first
written; it moved to **sixteen one-seat solo teams** on 2026-09-05 (build
0.7.334) and has stayed that way since — see [[battle-royale-s2]]. Every
rule below that used to describe a "duo" now resolves through a **pact**
instead: a live, mutual alliance between two or more solo teams (see
[[glossary]], "How a pact forms"), because no team here has a second seat
of its own any more. A team whose episode lands no factor above ×1 banks
exactly the seed, 1; a superb episode's total climbs far higher purely from
how many above-and-beyond deeds land inside it, because an all-×1 episode
of ordinary tags can never move off the seed on its own.

## Stats

### The percent-scaled class table

| Deed (pop word) | Class multiplier | Pops (≥×2.00)? | Reachable on this ladder today |
| --- | --- | --- | --- |
| `SPRAYED` | ×1.00 | No | Yes — a true no-op, same as always |
| `BOMBED` | ×1.00 | No | Yes — a true no-op, same as always |
| `RANK UP` | ×1.00 | No — paid as power (see [[ranks]]), not score | Yes, but scoring-neutral |
| shield soak (blank pop word) | ×1.60 | No — structurally excluded from the pop, any magnitude | Yes, ambient (per hit point absorbed) |
| clutch patch (blank pop word) | ×1.80 | No — structurally excluded from the pop, any magnitude | Yes |
| `TAG` | ×2.20 | **Yes** | Yes |
| `ESCORT` | ×2.00 | Yes | No — needs a flag/heart entity this map does not have |
| `ASSIST` | ×2.00 | Yes | Unlocked for battle royale at GLORYVERSION 17, but see Gaps — its trigger still needs a same-team helper, and no team here has one |
| `RESCUE` | ×2.00 | Yes | Same gap as `ASSIST` |
| `DUO DOWN` | ×2.00 (×2.12 on enemy ground) | Yes | Only when a kill downs one member of an active ≥2-team pact whose other member(s) are still alive |
| `TAG BACK` | ×2.00 (×2.12 on enemy ground) | Yes | Only reviving a downed **pact ally** — there is no duo partner to revive here any more |
| `JOINT ACT` | ×2.00 (×2.12 on enemy ground) | Yes | Only between two teams sharing an active pact, on the same 120-tick co-damage incident — see Rules |
| `POINT-BLANK` | ×2.50 | Yes | Yes |
| `PAYBACK` | ×4.00 | Yes | Yes |
| `CHASE` | ×4.00 | Yes | Yes |
| `FIRST!` | ×4.00 | Yes | Yes, once per episode |
| `STEAL` | ×4.00 | Yes | No — needs a flag entity |
| `PEEL` | ×4.00 | Yes | No — needs a flag entity and a live carrier |
| `LONGSHOT` | ×6.00 | Yes | Yes |
| `MULTI!` | ×6.00 | Yes | Yes |
| `DENIED!` | ×6.00 | Yes | No — needs a flag entity |
| `CAPTURE` | ×8.00 | Yes | No — needs a flag entity, and is disabled outright in every non-CTF ruleset regardless |
| `WIPEOUT` | ×8.00 | Yes | Only wipes an entire ≥2-team pact group with one kill — an ordinary un-pacted elimination never mints it |
| `LAST LIGHT` | ×8.00 | Yes | Yes — raised from ×4.00 at GLORYVERSION 17 |
| `BOUNTY` | ×9.00 | Yes | Yes |
| `CLOSING TIME` | ×1.20 | No | Yes — see note below |

`CLOSING TIME`'s live base is gated on the same live-service switch that
governs the BR win factor, `TAG BACK`, and `JOINT ACT` below: with that
switch off it would price ×1.10 instead. The switch has stayed armed on
this ladder since the 2026-09-04 incident fix, so ×1.20 is what has fired
on every round since.

Pop words and log names, and every deed not listed above, are [[deeds]]'s
own table. A team kill ("own paint") is not a class factor at all — it
divides the running product instead; see "Friendly fire" below.

### Achievement, placement, and win pricing

| Rung | Multiplier | Notes |
| --- | --- | --- |
| Tier I / Tier II achievement claim | ×1.00 | No first-claim distinction under this table |
| Tier III achievement claim | ×2.00 | No first-claim distinction under this table |
| Tier IV achievement claim, any team, first or not | ×2.50 | Raised from ×1.05 at GLORYVERSION 18 (lead ruling R4, keeps the ladder monotonic under the raised ceiling below) |
| Tier V achievement claim, not first | ×3.00 | Raised from ×2.00 at GLORYVERSION 18 (lead ruling R5) |
| Tier V achievement claim, first team to claim it | ×3.46 | Unchanged since GLORYVERSION 17 (`sqrt(12)`, the recovered formula's own value) — still strictly above Tier IV and Tier V non-first, so first claim still beats every non-first claim at every tier |
| Tier-completion bonus (armed on this ladder) | ×1 / ×1 / ×2 / ×3 / ×4 | Folds on top of a team's Tier V claim, keyed to how many of that SAME tree's other four tiers the SAME team already claimed this episode: 0 or 1 lower tiers banked → no bonus; 2, 3, or 4 → ×2 / ×3 / ×4. Armed at GLORYVERSION 18 |
| `FINAL 8` placement | ×1.15 | Raised from ×1.00 ("Ladder B", owner decision 2026-09-10) |
| `FINAL 4` placement | ×1.30 | Raised from ×1.00 |
| `FINAL 2` placement | ×1.60 | Raised from ×1.30 |
| BR win factor, this ladder's shape (16 one-seat teams) | ×8.00 | Not a deed — a flat, composition-neutral fold at the episode's finalize step, entirely replacing the retired `VICTORY` deed |

The BR win factor is keyed by the winning team's own seat count: a 1-seat
winner folds ×8.00, a 2-seat (duo) winner would fold ×4.00 instead. Since
every team on this ladder seats exactly one player, ×8.00 is what fires on
every decisive round today; the ×4.00 duo rate is dormant machinery left
over from the ladder's own duo era, not a live outcome here. None of the
three placement rungs reach the ×2.00 pop line, by design — see "The popup
law" below.

### Other multipliers, carried over

| Property | Value | Notes |
| --- | --- | --- |
| Episode seed | 1 | Unchanged |
| Heat ladder | ×1 / ×5 / ×14 / ×36 | Raised from ×1 / ×2 / ×4 / ×8; cumulative embers 1 / 2 / 4 reach each rung above ×1, 11-ember cap, sheds 2 embers per quiet window, an 11.25s window before one closes |
| Ally-stack ladder (now pact-gated) | ×1 / ×5 / ×7.5 / ×12.5 / ×20 / ×32.5 | For 1 through 6+ teams in context; only a team sharing an active pact with the minting team counts toward this — a co-engaged team with no pact contributes nothing |
| Territory rung shift | +2% to +6%, multiplicative | Replaced the classic flat +1-rung shift; the exact percentage depends on the deed's pre-recut classic class (2 → +6%, 3 → +4%, 4 → +3%, 6 → +2%, 8 → +2%). Still exempts every classic ×1 common — `TAG`, `POINT-BLANK`, `SPRAYED`, `BOMBED`, shield soak, and clutch patch never shift, on any ground — even though four of those six now carry a real multiplier of their own |
| Carrier hold multiplier | ×2 | Unchanged; structurally unreachable on this ladder's flagless map |
| Friendly-fire divisor | ÷2 per incident | This ladder's rate (16-solo, no respawns); CTF instead halves once per two incidents. Uncapped either way |
| Mint-cap product ceiling | 2,097,152 (reported) | Raised from 16,384 at GLORYVERSION 18; sized against a real 5,456-seat-episode cohort so it binds roughly 0.31% of the time |
| Product overflow guard | 2^62 (~4.6 × 10^18) | A deeper saturation ceiling underneath the mint cap; effectively unreachable either way, unchanged |
| Per-deed mint budget (armed on this ladder) | `TAG BACK` 3, `JOINT ACT` 6, `DUO DOWN` 4, shield soak 3 | Per episode, per team-in-context — every mint past the budget still fires, pops, and counts, but folds nothing further into the score. Every other deed is bounded some other way already (a scarce enemy life, a one-shot latch, and so on), so it needs no budget |

## Rules

### A running product, not a running sum

Every glory-earning fact on this ladder computes one factor — a whole
integer under the frozen table, a percent under the armed one above — and
that factor multiplies directly into the episode's single running product
for the earning team. In log space this makes an episode's score exactly a
sum of log-factors. The scorer that turns a team's total into that
episode's platform score is not win-gated: every seat banks its own team's
running product, win or lose — losing teams bank real scores, and a bad
enough total banks negative, with no floor. Winning is priced inside the
product instead, through the flat BR win factor described above, rather
than by a gate on who banks. See [[glory]] for the seat-level banking
rules.

### Ordinary play is neutral — for exactly two deeds

Only `SPRAYED` and `BOMBED` are still true no-ops: multiplying the running
product by ×1.00 leaves it untouched. `TAG` and `POINT-BLANK` are no longer
commons — since GLORYVERSION 17 they price at ×2.20 and ×2.50, real
multipliers that clear the ×2.00 pop line — and shield soak and clutch
patch now price at ×1.60 and ×1.80, real but sub-pop multipliers. `RANK UP`
stays priced at ×1.00 and, separately, is excluded from the popup path
entirely: it pays power (see [[ranks]]), not score, by a standing 2026-08-21
ruling. This still continues the standing achievements rule (Glory rewards
the exceptional, not the routine) — it is simply a smaller set of "routine"
acts than it used to be.

### Ground you're standing on shifts the price, not always the rung

A deed minted on enemy ground — the same nearest-home-pedestal ownership
signal [[glory]]'s site gradient already reads — climbs a small multiplicative
premium instead of the classic table's flat +1 integer rung: +6% for a
deed whose pre-recut classic class was 2, +4% for class 3, +3% for class
4, +2% for class 6 or 8. **This never applies to any of the six classic ×1
commons, on any ground** — not even the four (`TAG`, `POINT-BLANK`, shield
soak, clutch patch) that now carry a real multiplier of their own; only
deeds whose classic class was already 2 or higher get the territory
premium. Every team's home pedestal exists on this ladder's map the same
way it does everywhere else, so the signal is live here even though the
ladder has no flag to steal.

### Heat and the carry multiplier ride along as percent factors

A deed's class (with the territory shift already folded in) is only the
first term. If the deed's Drama price is positive (the same gate [[deeds]]
and [[glory]] already document), the territory-shifted class is multiplied
by the heat ladder next, then by the carry multiplier if the minting team
currently holds an enemy flag, then by the ally-stack factor below — in
that order. **The carry multiplier is real code on this path but cannot
fire on `battle-royale-s2`'s own map: that map carries no flag entity at
all, so the "currently holding an enemy flag" check is always false
there.** It is documented here because it is part of the same live
pipeline, not because a team can ever collect it.

*Worked example:* a `LONGSHOT` kill (class ×6.00) landed on enemy ground
(classic class 3 → +4% → ×6.24) by a team sitting at 5 cumulative embers —
which now maxes the heat ladder at ×36.00, since the current thresholds
reach that rung at 4 embers, not 10 — with no pact-linked ally in context
(stack ×1.00): 6.24 × 36.00 × 1.00 = 224.64. That single kill folds a
factor of ×224.64 into the running product. The same shot would have
folded only ×16 under the ladder's original integer table and thresholds —
both the percent-scaled classes and the retuned heat cadence pushed a hot
streak's ceiling much higher.

### Stacking is still Fibonacci-shaped, now pact-gated

The ally-stack factor climbs ×1 / ×5 / ×7.5 / ×12.5 / ×20 / ×32.5 for 1
through 6+ teams in context (clamped at both ends), the same Fibonacci
shape as before (1, 2, 3, 5, 8, 13) scaled ×2.5. **What counts as "in
context" changed underneath the ladder's move to solo teams: a
co-engaged team only counts toward this factor if it shares an active,
mutual pact with the minting team.** A co-engaged team with no pact
contributes nothing — raw co-engagement between un-pacted teams ("jackal"
damage) was measured contaminating this factor before the gate was added,
and now exits entirely. Exactly which pacts count and how the window opens
and closes is still being refined — see `## Gaps`.

### Five deeds exist only on this ladder, and four of them now require a pact

`DUO DOWN` (×2.00), `TAG BACK` (×2.00), `JOINT ACT` (×2.00), `CLOSING TIME`
(×1.20), and `LAST LIGHT` (×8.00) mint only under this armed pricing table,
and only in `battle-royale-s2`:

| Deed | Multiplier | Fires on |
| --- | --- | --- |
| `DUO DOWN` | ×2.00 | A kill that downs one member of an active ≥2-team pact while at least one other member of that pact is still alive |
| `TAG BACK` | ×2.00 | Reviving a downed **pact ally**, uncapped up to the mint budget above — minted to the tagger, from the same `Revived` event the downed state (see [[damage-and-health]]) already emits |
| `JOINT ACT` | ×2.00 | Two teams that share an active pact both land a qualifying hit on the same victim inside a 120-tick cross-team damage window — every contributing seat mints once per incident, priced at the victim's site. A `×3.00 JOINT ACT` pop (the enemy-ground-shifted price) does not mean three participants; the number is the class factor, never a headcount |
| `CLOSING TIME` | ×1.20 | A kill landed while the shrinking zone's closing phase is actively running |
| `LAST LIGHT` | ×8.00 | A kill landed at or past the zone's last authored shrink phase |

None of these five require a pact except `DUO DOWN`, `TAG BACK`, and
`JOINT ACT` — `CLOSING TIME` and `LAST LIGHT` price off the zone clock
alone, the same as before the ladder moved to solo teams. On a lone,
un-pacted solo team, `DUO DOWN`/`TAG BACK`/`JOINT ACT` simply never mint:
there is no partner to revive, no ally to co-damage with, and no pact
group to down or wipe.

### Which of the classic rungs can actually mint here

Several rungs on the class table above price a deed this ladder's own map
cannot produce, because `battle-royale-s2` carries no flag entity at all:
`STEAL`, `PEEL`, `DENIED!`, and `ESCORT` each need a flag or a flag carrier
that never exists here. `CAPTURE` needs that same flag and is also
disabled outright in every non-CTF ruleset — the same gate [[glory]]
already documents. `WIPEOUT` can mint here, but only through a pact: a
kill that leaves an entire opposing pact group of two or more teams with
zero living players. An ordinary elimination of an un-pacted solo team
never mints it — there is no "entire team" bigger than one seat for a lone
kill to empty. `ASSIST` and `RESCUE` had their classic-only gate lifted for
battle royale at GLORYVERSION 17, but both still require a same-team
helper in their own trigger condition; since no team on this ladder seats
more than one player, neither has a live path to mint here today — see
`## Gaps`.

### Friendly fire divides the running product, uncapped

A team kill is not a class factor at all — it advances a division counter
instead. On this 16-solo ladder, every single team-kill incident halves
the team's running product; other paintbot-family modes with respawns
instead halve theirs once per two incidents. Neither rate has a cap or a
floor: the division compounds without limit, by design. Because this is a
division rather than a class factor, a badly-behaved episode's final
reported score can land on a non-whole number even though every fold along
the way was exact — the platform's integer score reports the floor of
that division, while the exact value is kept losslessly underneath.

### The popup law: only ×2.00 and up

A minted deed only floats a "hero" popup — the big on-screen callout — if
its final, fully-folded multiplier is ×2.00 or higher; the client enforces
this in the replay renderer itself, not the sim. Nothing smaller ever pops
as a hero callout, and a true ×1.00 never pops at all. This is why all
three placement rungs (`FINAL 8`/`FINAL 4`/`FINAL 2`, ×1.15/×1.30/×1.60)
stay quiet marks fed to the score meter rather than visible moments: the
ceiling-move re-fold that chose those exact numbers screened every
candidate ladder against this same ≥×2.00 line, on the owner's own ruling
that "nothing under 2x" should ever pop, "especially not 1x that gives you
nothing." Shield soak and clutch patch are excluded from popping
altogether, at any magnitude, independent of this rule. Placement and
tier-completion milestones are also drawn at the earning team's own home
pedestal rather than at the spot the milestone was actually crossed —
working as designed, but easy to misread as a bug if the zone has already
moved elsewhere on the map.

### Mint caps and the product ceiling

Four deeds have no natural limit on how many times they can mint in one
episode for one team-in-context: `TAG BACK`, `JOINT ACT`, `DUO DOWN`, and
shield soak. Each carries its own per-episode budget (see the table
above) — the first `cap` mints fold their factor into the product
normally, and every mint after that folds nothing further, though the deed
still mints, pops, and counts everywhere else. Underneath that, the
product itself saturates at a hard ceiling (2,097,152 reported) rather
than growing without bound; a deeper, effectively unreachable overflow
guard (2^62) sits below that as a second line of defense. Both exist
because an earlier version of this ladder had neither: a revive-and-bleed
loop repeatedly minted `TAG BACK` inside the zone's closing damage, and
without any budget or a meaningfully-sized ceiling, real episodes reached
scores nine orders of magnitude past the ladder's own intended top end
before the defect was caught — see "Winning" below.

### Winning: from a stochastic deed to a flat, seat-keyed fold

As of round 3871 (canonical build 0.7.320), winning a `battle-royale-s2`
match stopped minting the `VICTORY` deed. In its place, the winning team's
running product is multiplied by a flat, deterministic win factor at the
episode's finalize step, after every other deed of the episode has already
minted — composition-neutral by design: it pays no heat, no territory, no
carry multiplier, and no ally-stack factor, so its size does not depend on
which deeds a team happened to land on the way to the win. A losing team
never receives it. Two new deeds armed in the same build: `TAG BACK` and
`JOINT ACT` (see the marquee table above). **This produced a scoring
incident:** composed with a same-build change to zone damage, a duo could
cycle a down-and-revive loop roughly every 57 ticks inside the closing
ring's paint, and each cycle minted `TAG BACK`'s factor again into the
running product. 24-27 such cycles in a single episode were enough to push
some episodes' products nine orders of magnitude past this table's own
intended ceiling. The first poisoned round was **3885**; eleven rounds in
total carried at least one inflated episode before the defect was caught
and fixed: **3885, 3894, 3897, 3900, 3901, 3904, 3917, 3920, 3921, 3936,
and 3938**.

**Fixed 2026-09-04** (commit `d595f300`): the win factor was rolled back
and `VICTORY` briefly minted again, while a durable fix — the per-deed
mint budgets and the tightened product ceiling described above — was
built. The eleven poisoned rounds were surgically excluded from standings
and the board recomputed clean; the legitimate all-time high at that point
stood at **3,375,440**, round 3860. The win factor, `TAG BACK`, and
`JOINT ACT` were all re-armed once the mint budgets shipped (2026-09-04)
and have stayed armed since — they are not "pending a future re-arming," as
an earlier revision of this page described. `JOINT ACT` gained its own
independent gate five days later (GLORYVERSION 15, 2026-09-09): it now
requires an active mutual pact between the two co-damaging teams, closing
the un-pacted "jackal" co-fire loophole. The win factor itself became
mode- **and team-size**-keyed shortly after (v14 sizing package): a 1-seat
winning team folds ×8.00, a 2-seat (duo) winner folds ×4.00. Because the
ladder itself moved from duo teams to sixteen solo teams on 2026-09-05,
×8.00 — not ×4.00 — is the number that has actually fired on every
decisive round since. An earlier revision of this page also stated that
`CLOSING TIME`'s rung bump was permanent and independent of the win-factor
flag; reading the source shows it is gated on that exact same flag, and
has simply stayed on since 2026-09-04 without needing a further flip.

## Version history

| Version | Change |
| --- | --- |
| GLORYVERSION 18 (S8, 2026-09-09) | Mint-cap ceiling raised 16,384 → 2,097,152 reported. Achievement Tier IV ×1.05 → ×2.50, Tier V non-first ×2.00 → ×3.00 (Tier V first-claim ×3.46 unchanged, still tops the ladder). Tier-completion bonus (×1/×1/×2/×3/×4, keyed to how many of a tree's lower tiers the same team already claimed) armed. Placement `FINAL 8`/`FINAL 4`/`FINAL 2` raised ×1.00/×1.00/×1.30 → ×1.15/×1.30/×1.60 ("Ladder B", owner decision 2026-09-10) — all three stay below the ×2.00 pop line by design. Scoring only, no wire change. |
| GLORYVERSION 17 (S6, 2026-09-09, live since build r4611) | The whole class/tier/heat/stack/territory table moved from whole-integer factors to the percent-scaled table this page now documents: `TAG` ×1 → ×2.2, `POINT-BLANK` ×1 → ×2.5, shield soak ×1 → ×1.6, clutch patch ×1 → ×1.8, `LAST LIGHT` ×4 → ×8, ally-stack scaled ×2.5, territory shift a flat +1 rung → +2%–6% multiplicative, placement `FINAL 8`/`FINAL 4` raised off a pure ×1.00 marker to ×1.00/×1.00/×1.30 with a continuous survival credit. Also ungated `ASSIST`/`RESCUE` for battle royale (see Gaps for why neither actually mints here yet) and retargeted `DUO DOWN`/`WIPEOUT` to pact scope. |
| GLORYVERSION 15 (2026-09-09) | `JOINT ACT` gated to require an active mutual pact between the two co-damaging teams — unpacted third-party co-fire ("jackal" damage) now mints nothing. |
| 2026-09-05 (build 0.7.334, no GLORYVERSION change) | `battle-royale-s2` itself moved from eight two-seat duo teams to sixteen one-seat solo teams — see [[battle-royale-s2]]. Every deed and rule on this page that used to refer to a "duo" now resolves through a pact instead, since no team here has a second seat any more. |
| Unrecorded (GLORYVERSION 14 era) | Rolled back 2026-09-04 (commit `d595f300`): the flat win factor armed round 3871 is retired and re-armed with a durable per-deed mint budget and a tightened product ceiling, closing the `TAG BACK` revive-loop incident described in "Winning" above. The win factor, `TAG BACK`, and `JOINT ACT` have stayed armed ever since. |
| Unrecorded | Winning `battle-royale-s2` stopped minting the `VICTORY` deed, verified live as of round 3871 (canonical build 0.7.320): the win became a flat, composition-neutral factor folded into the product at finalize, outside the heat/territory/carry pipeline entirely. Two deeds armed in the same build: `TAG BACK` and `JOINT ACT`. |
| Unrecorded | The win gate on episode banking removed, verified live as of round 3849 (canonical 0.7.317): every seat banks its own team's running product win or lose — losing teams bank real scores, negative totals are possible (no floor). |
| Glory 13 (0.7.310+) | The pure-multiplier pricing table armed live on Paintbot (Season 2)'s `battle-royale-s2` ladder, beginning round 3830 — a live-service arming, not a change to the engine's own default (every other ladder keeps running [[glory]]'s additive pricing). |

## Gaps

- Whether `ASSIST` and `RESCUE` can ever actually mint on this 16-solo
  ladder is a live open question, not just a historical one: their
  classic-only gate was lifted for battle royale at GLORYVERSION 17, but
  reading the source shows their own trigger predicate still requires a
  literal same-team helper (not a pact ally), and no team here seats more
  than one player. This is read from source, not verified against a live
  replay that actually tries to satisfy it.
- Exactly which allied teams count toward the ally-stack factor in a given
  moment, and how that window opens and closes, is not finalized.
- Whether `JOINT ACT` mints correctly when three or more pact-linked teams
  contribute to the same 120-tick incident (does every seat from every
  team mint, or only the qualifying pair) has not been checked against a
  live replay — this page reads the mint predicate from source. A separate
  measurement (39 real episodes, 531 mints) found the sim never mints
  `JOINT ACT` before roughly tick 800 and no incident has ever had more
  than two simultaneous contributors in that sample, and that a pop's
  multiplier is the class factor, never a participant headcount — a
  natural but wrong reading of e.g. a "×3.00 JOINT ACT" pop.
- Whether a `CAPTURE`/`WIPEOUT`-style deed ever gets a further "hot vs
  cold" split for how contested it was is unresolved — nothing in the
  armed table above does this today.
- The achievement Drama column's own rescale is untouched by this pricing
  table and remains a separate, unresolved question.
- How often ordinary deeds actually land on enemy vs. home ground under
  this ladder's live traffic has not been measured; that the six classic
  commons never shift rung is verified by reading the pricing code, not by
  field measurement.
- Whether a jump to this much larger score scale resets, re-derives, or
  simply supersedes any record set before this table was armed has not
  been decided.
- Which of [[achievements]]'s 8 trees are actually reachable on a flagless
  16-solo map has not been audited on this page.

## See also

- [[glory]] — the additive pricing table this page's classes replace on
  one ladder only
- [[deeds]] — the full per-deed pop words, log names, and triggers this
  page's classes price
- [[achievements]] — the 8 trees and 5 tiers the Tier I–V rungs above price
- [[round]] — how an episode's score rolls into a round and a season
  standing
- [[modes]] — what `battle-royale-s2` configures
- [[battle-royale-s2]] — this ladder's own ruleset: sixteen solo seats, the
  closing zone, combat, and how a round ends
- [[elo]] — what a round score feeds where a ladder runs one
- [[scoring]] — match reward, kept separate from Glory
- [[versions]] — what the GV/Glory stamp means
- [[conventions]] — the version-stamp format and the live-service rule

## Discussion

Whether the multiplier economy rewards the right kind of play, and any
episode-score distributions you've tracked yourself, belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
