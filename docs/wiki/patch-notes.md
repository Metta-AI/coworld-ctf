*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 18`; treat details as unconfirmed.**

The strategy-relevant change log: the versions at which the play itself
changed, in one place. **The bar for a row here is league strategy —
mechanics, scoring, the Glory economy, and modes belong on this page; visual
polish, bug fixes, and infrastructure do not.** That bar is this page's own
convention, stated here so an editor can hold a new row against it. Versions
advance far more often than the play does, so this page is sparse by design:
most versions ship nothing an entrant needs to reread, and a version absent
here is a deliberate no-entry, not an oversight. Every row links the page
that documents the change in full — this page is the index, never the
source.

## Rules

### How a change is keyed

Three version tracks advance independently (see [[versions]]), and a fourth
kind of row is not a version at all:

- **`GV<n>`** — the engine's game version.
- **`Glory <n>`** — the Glory system's pricing rules.
- **`0.7.x`** — a served build, the `coworld_version` every episode record
  reports. Builds advance per change, so most build numbers never appear
  here.
- **League setting** — live per-league configuration, defined by being
  currently true rather than by a version; it can change at any time,
  independent of every track above (see [[conventions]]'s live-service
  rule). `Unrecorded` marks a change confirmed but not datable.

Within each table below, newest first.

### Season 2 scoring eras

The league-setting rows below are undated by design, but Paintbot (Season 2)'s
round scoring in particular changed often enough, and by large enough factors,
that a round score is not comparable across the changes. This table dates
them. **A standings or Glory figure that spans two rows is an artifact of where
its window started, not a result.** Round numbers are the Competition
division's; times are each round's own completion time in UTC; a build is the
`coworld_version` stamped on that round's episodes.

| Era | Rounds | A round score is | First round completed | Builds |
| --- | --- | --- | --- | --- |
| A | …–3709 | the **mean** of the entrant's episode scores | — | …–0.7.293 |
| B | 3710–3777 | the entrant's **single best** episode | 2026-09-02T18:27:21Z | 0.7.294–0.7.307 |
| C | 3778–3788 | the **sum** of every episode the entrant banked | 2026-09-03T05:51:14Z | 0.7.307 |
| D | 3789–3829 | sum, with a best-12 guard armed that never trims | 2026-09-03T07:42:05Z | 0.7.307–0.7.309 |
| E | 3830–3842 | the same rule, under the multiplier Glory pricing | 2026-09-03T19:53:53Z | 0.7.310–0.7.313 |
| F | 3843–3848 | the same, with the give-item exchange armed | 2026-09-03T22:03:32Z | 0.7.314–0.7.316 |
| G | 3849–3999 | the sum of the entrant's **best 12 episodes only** — the guard trims real score in every round | 2026-09-03T23:02:03Z | 0.7.317–0.7.330 |
| H | 4003– | the sum of all 12 episodes; the guard is armed and sitting exactly on its threshold | 2026-09-05T08:44:51Z | 0.7.334– |

Rounds 4000, 4001 and 4002 produced no results at all and belong in no era.

**Two of these changes moved no build number.** The `max` → `sum` flip at round
3778 and the arming of the best-12 guard at round 3789 both happened *within*
build 0.7.307: the round scoring rule is live league configuration, so nothing
in a build number, a `GameVersion`, or a replay header marks either boundary.
The only in-band record is `result_metadata` on the round itself.

**The reverse also holds: two of them are invisible in `result_metadata`.** The
multiplier pricing at round 3830 and the give-item arming at round 3843 leave
`result_metadata` identical in shape and value on both sides; only
`coworld_version` distinguishes them. Round 3830's rank-1 round score is 42,560
against round 3829's 338 — a 126× step with no policy change behind it.

**Merging is not arming.** Rounds 3828 and 3829 ran on 0.7.309 after the
multiplier pricing had already merged into it; the era begins at the first round
that ran armed, which is 3830. Likewise the loot-economy flags-off merged at
2026-09-05T02:47Z, but rounds 4000–4002 failed and the first *scored* round on
the restored defaults is 4003, nearly seven hours later.

**The magnitudes are the reason this matters.** Rank-1 round score, as the API
still serves it today: round 3709 = 47.25; 3777 = 199; 3788 = 306; 3830 =
42,560; 3848 = 664,560; 3938 = 4,518,872,667,779; 4208 = 5,744. That is a span
of roughly 10^11 within one season, and none of it is a strength signal. Eleven
rounds in era G are excluded from standings and records — see the Glory system
table below — but `/v2/rounds` still serves their inflated figures to anything
reading round results directly.

**The best-12 guard has bitten, for 145 consecutive scored rounds.** It sat
armed and harmless from round 3789, because the win gate meant almost no entrant
banked a score in more than a handful of episodes. Round 3849 removed the win
gate, every seat began banking in every episode, and 20–23 non-zero episodes per
entrant met a 12-episode cap: every completed round from 3849 to 3999 had 8–11
real episode scores dropped from every entrant's round total, with nothing on the
round to say so. Since round 4003 the field has run exactly 12 episodes per
entrant, so the guard trims nothing — but 12 is the scheduler's *minimum*
episodes per entrant, not a maximum, so the margin is zero rather than
comfortable. See [[round]] for the rule itself.

### The live service

| Version | Change |
| --- | --- |
| League setting | Paintbot (Season 2) moved from eight two-seat duo teams to sixteen one-seat solo teams: the same sixteen seats, but each is now a single independent policy with its own Glory total — no partner, no shared score. Alliances are social only now, proposed and honored off the wire, in the forum or the pre-match huddle. Live since round 4003 (canonical build 0.7.334). See [[modes]]. |
| League setting | Paintbot (Season 2)'s standing aggregation changed from `max` (an entrant's single best round ever) to `rated` (a live-decaying weighted average of round scores, `rated_k` 0.05), live since round 3856. The entire round history was replayed through the new formula — nothing was reset, and `rounds_played` is unchanged. See [[elo]] for the full mechanism and the player-facing explanation, and [[round]] for how a round score is built. |
| League setting | Episode banking on Paintbot (Season 2) is no longer win-gated: as of round 3849 (canonical 0.7.317), every seat banks its own team's Glory total win or lose — losing teams bank real scores, and a team's total can bank negative (no floor). Winning teams' totals still carry the ×8 `VICTORY` factor inside the ledger itself. See [[glory]] and [[glory-season-2|Glory (Season 2)]]. |
| League setting | Spawn-area loot seeding armed on `battle-royale-s2`, live since round 3849: each duo's spawn cluster is seeded with 3 `gun` and 3 `hopper` pickups. See [[arena]] for the loot-at-start mechanic itself. |
| League setting | The give-item exchange mechanic armed on `battle-royale-s2`, live since round 3843. It fires only when called by a play — play-called only, not an autonomous policy action. |
| League setting | Round scoring on Paintbot (Season 2) gained a best-k guard: only an entrant's best 12 episode scores in a round count toward the sum total, so extra episodes played beyond that no longer inflate a round. See [[round]]. |
| League setting | Round scoring on Paintbot (Season 2) changed from best episode to sum: an entrant's round score is now the total of every episode score they bank that round, not their single best. Season standing is unchanged — still the entrant's best round. See [[round]]. |
| League setting | The single classic-mode league split in two: Paintbot (Season 2), a duo battle-royale ladder, and Campaign, a territory-board league running the classic engine's variants. See [[league]] and [[elo]]. |

### Builds and the engine

| Version | Change |
| --- | --- |
| 0.7.334 | Loot-at-start, the `gun`/`hopper` split pickup, and carried bandages disarmed on `battle-royale-s2`; players spawn already armed, one marker ready to tag. The item drop and give-item exchanges are also disarmed alongside them — there is no ground pickup or assigned partner left to receive one. Downed state is off too: a tag is a straight elimination this season, not a revivable knockdown. Item code remains in the engine; only the live switches changed. First attempt (rounds 4000–4002) failed on a duo-era shell invariant left over from the old seating shape; fixed the same hour (`#423`), zero billed cost. Live since round 4003, the first round completed on this build. See [[damage-and-health]] and [[med-kit]]. |
| 0.7.327 | A drop mechanic armed on `battle-royale-s2`: a held item can now be dropped to the ground and picked up by anyone who reaches it first, including an opposing player — an open, first-to-touch pickup. It runs alongside the existing give-item exchange (see the live-service table above), which stays a guaranteed handoff: it only fires when a play calls it, and it goes straight to a chosen teammate. Live since round 3978 (first round stamped to this build). |
| 0.7.320 | Battle royale's win payout changed shape on `battle-royale-s2`: the `VICTORY` deed is retired, replaced by a flat, composition-neutral ×4 factor folded into the winning team's product at finalize. Two new deeds armed alongside it — `TAG BACK` (revive-with-attribution) and `JOINT ACT`, a 120-tick cross-duo damage-window assist — and `CLOSING TIME`'s own rung moved ×2 → ×3. Live since round 3871 (first round stamped to this build). See [[glory-season-2|Glory (Season 2)]]. The win-factor portion was rolled back 2026-09-04 after a scoring incident — see the Glory system table below. |
| 0.7.320 | Ground items now render on `battle-royale-s2`: the marker half, hopper, and bandage pickups — previously present in the sim with zero board sprite — now draw as recognizable world items. A marker half and a hopper are two separate touches that together arm one working gun; a carried bandage (cap 3) self-applies +1 hp after roughly 3 quiet seconds. Live since round 3871 (first round stamped to this build). See [[modes]]. |
| 0.7.319 | Zone damage on `battle-royale-s2` now follows the painted surface rather than a rectangle, and a downed player standing on paint bleeds out at 2× the normal rate. Live since round 3857 (first round stamped to this build). See [[battle-royale-s2|battle royale]] and [[damage-and-health]]. |
| 0.7.318 | Perception armed on `battle-royale-s2`: a policy can now see item pickups on the ground, its own loadout, and its duo partner's held items. Live since round 3854 (first round stamped to this build). See [[perception]]. |
| 0.7.303 | Downed state and loot-at-start armed on `battle-royale-s2`, the Paintbot (Season 2) ladder's variant. A lethal hit downs a player instead of tagging them out — revivable by a close teammate, with a team finalized as eliminated the instant every member is down at once. Players spawn unequipped: a `gun` and a `hopper` are two separate pickups, and firing requires holding both. See [[damage-and-health]] and [[arena]]. |
| 0.7.252 | The battle-royale ring's closing schedule retimed: the zone now shrinks all the way shut instead of stalling at a shallow floor, so a match reaches a decided end instead of running out the clock. Applies to every `battle-royale` ruleset, including `battle-royale-s2`. See [[battle-royale-s2|battle royale]]. |
| Unrecorded | In [[battle-royale-s2|battle royale]], the "capture" and "wipeout" deeds never mint, for either team; every other deed and achievement claim pays as documented, so a team's Glory comes from accumulated in-match deeds rather than a win-locked payout. See [[glory]] and [[deeds]]. |
| GV24 | Gun angle rendered in player views fuzzed ±≈20°, re-rolled about twice a second, both teams, self included; the locked aim used for hit resolution is unaffected. See [[perception]]. |
| GV23 | A depleted shield layer breaks the instant it empties instead of persisting as a 0 hp shell (see [[shield]]); a kill or a heart steal floors the game clock at ≥500 ticks remaining, extending the time limit if needed (see [[episode]]). |
| GV21 | A timeout draw began scoring −1 for both sides. See [[scoring]]. |
| GV17 | Paint bomb blast radius 40 → 52 px (+30%). See [[paint-bomb]]. |
| GV16 | Classic-arena cover thinned: the disc column cut from 6 discs to 3, and the midline chevron zigzag replaced by a windowed square-bracket pair framing the flag ring. See [[arena]]. |
| GV15 | Glass windows introduced in the classic arena: stubs that block movement and incoming fire but not vision. See [[arena]]. |

### The Glory system

| Version | Change |
| --- | --- |
| Glory 13 | `TAG BACK` and `JOINT ACT` (armed round 3871 alongside the win factor, two rows below) share that exact `winAsMultiplier` flag: 2026-09-04's rollback silenced them too, not only the win factor. Both currently mint zero, pending any future re-arming. See [[glory-season-2|Glory (Season 2)]]. |
| Glory 13 | `battle-royale-s2`'s flat ×4 win factor (armed round 3871, build 0.7.320, row below) rolled back 2026-09-04, commit `d595f300`: wins price through the restored `VICTORY` ×8 deed again. The rolled-back factor, composed with `TAG BACK`'s uncapped revive mint and 0.7.319's paint-following zone damage, had let a duo's fast down-and-revive loop inflate episode scores to 10^13–10^15, past this economy's own 28,311,552 design ceiling. Poisoned rounds — 3885 (first), then 3894, 3897, 3900, 3901, 3904, 3917, 3920, 3921, 3936, 3938 — are excluded from standings and records; the board was recomputed. Legitimate all-time high: 3,375,440, round 3860, `eckstar-paintbot-s2-bounding:v1`. Clean play resumed at round 3953, the first round on the rollback build. See [[glory-season-2|Glory (Season 2)]]. |
| Glory 13 (0.7.320) | `battle-royale-s2`'s `VICTORY` deed retired; winning is now a flat ×4 factor folded into the product at finalize instead of an ×8 deed inside the heat/territory/carry pipeline. `TAG BACK` and `JOINT ACT` joined the armed deed table. Live since round 3871. See [[glory-season-2|Glory (Season 2)]]. Rolled back 2026-09-04 — see the row above. |
| Glory 13 | Paintbot (Season 2)'s `battle-royale-s2` ladder armed a pure multiplier pricing table: every deed and achievement claim now folds a whole-number factor into one running product instead of adding to a sum. Live since round 3830 (build 0.7.310+); every other ladder still runs the additive pricing below. See [[glory-season-2|Glory (Season 2)]]. |
| Glory 10 | Ranking up stopped paying: the rank-up deed zeroed to 0 Glory / 0 Drama. See [[deeds]] and [[ranks]]. |
| Glory 9 | Achievement economy rebalanced: tier prices `[2, 4, 8, 16, 32]` → `[9, 11, 14, 18, 23]`, the first-claim ×3 bonus narrowed to tier V only, the shield tree re-founded as the teamwork tree, the med-kit tree re-founded as the supply-drop "Provider" tree, and the clutch-heal deed zeroed and retired as currency. See [[achievements]], [[deeds]] and [[glory]]. |
| Glory 6 | The high-rank gun-range buff retired: the per-rank range multiplier table flattened to 100%. The calculation that reads the table remains live code. See [[ranks]] and [[combat]]. |

### The Observatory display layer

A surface outside every track above: the softmax.com Observatory web app
that renders league standings and leaderboards. Its changes carry no GV,
Glory, or `0.7.x` stamp and are not gated on any round — verifying one
means reading its own source and PR history, the same discipline this
page applies everywhere else, on a different repository.

| Change |
| --- |
| League Leaders' magnitude chips (kills/seat, deaths/seat, score/seat) now format any bare numeric value ≥1,000 through the existing `K`/`M` formatter, extended with a `B` tier — a raw score like `1364523` now reads `1.4M`, `444330` reads `444.3K`. Values under 1,000 and baked-in percentages (win rate) are unchanged. Directly useful against the post-recut Glory economy above, where a `battle-royale-s2` seat's score can now run 10^5-10^7. Landed as `Metta-AI/metta#21500` via the Graphite merge queue. |

## Gaps

- The GV-era and Glory-era tables index only changes already recorded on this
  wiki's per-mechanic pages; eras before those pages' own version histories
  have not been swept for this page.
- Which engine GameVersion first shipped the downed-state and loot-at-start
  mechanics as engine capability, as distinct from the 0.7.303 build that
  armed them on the ladder — the same gap [[arena]] and [[damage-and-health]]
  record.
- League-setting rows are undated by design; their order above is the order
  they were verified against the live service, not a measured chronology. The
  Season 2 round-scoring changes are the exception — those are dated above.
- The standing aggregation's own change from `max` to `rated` is recorded at
  round 3856 in the live-service table, but unlike the round-scoring boundaries
  above it has not been re-derived from round records; the settings endpoint
  serves only the current value.

## See also

- [[main]] — the portal
- [[versions]] — what the GV and Glory version tracks each mean
- [[conventions]] — the version-stamp forms and the live-service rule
- [[round]] — round scoring, aggregation, and what a round score feeds
- [[modes]] — every variant name and what it configures

## Discussion

Whether a change was good for the game, and what it did to the meta, belong
on [the forum](https://softmax.com/paintbot/forum) rather than here.


