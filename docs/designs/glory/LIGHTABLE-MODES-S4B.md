# GLORY GRADIENT — Step S4b: ACHIEVEMENTS AS LIGHTABLE MODES

Program `25d9108e`. Follow-on to S5 (`RIG-SIMULATION.md`, PR #501, already landed at `0c4df1f8`),
dispatched in parallel with the S6 ship draft (PR #504) and deliberately independent of it — this
PR does not read, gate on, or assume #504's catalog-v3-default-ON work has landed. No
GLORYVERSION bump (still 17 as of this branch's rebase onto #504's ship, `8b7e78a7`,
which already carried it 16→17 for the unrelated catalog-v3-default-ON work — this PR does not
touch `glory.nim:301` a second time); no wire change; no settings POST; no deploy.

## Why (the evidence, not restated in full — see the cited docs)

- `CENSUS-2026-09-ACHIEVEMENTS.md`: 35 of 40 achievement slots (87.5%) mint zero. `treeGun`'s top
  tier (source name "Longshot", index 4) is the one real skill-gated jackpot — 69.18% of
  seat-episodes reach it, a FIRST-claim race decides 4.32% of all seat-episodes — named explicitly
  as "the model to generalize," not a gap to fill differently.
- `TOP-ATTRIBUTION.md`: achievements are 17.95% mean / 9.83% median of a top-decile score's
  log2-magnitude, classified as "a one-shot claim… more like a second placement ladder than a
  graded skill signal" — i.e., CONSTANT, not CHOSEN, in this program's own vocabulary.
- `RIG-SIMULATION.md` (S5): its own per-class breakdown puts ACHIEVEMENTS at 40.97% of a mid-band
  seat's magnitude and 24.80% of a top-band seat's — the single largest CONSTANT bucket in the
  whole catalog. Its own cap-hit ceiling sweep found a CLIFF, not a curve: 16/15.5/15/14.5 all
  read 0.0000%, then a jump straight to 6.0667% at 14.0, nothing between 12 and 14.
- `CATALOG-V3-DRAFT.md` §6 ("Modes lit by sets; jackpot lit before it pays") names the mechanism
  this PR builds: "take the achievement-tree 'bank of targets' shape… and add the two properties
  every [pinball] reference table has and we don't." §3's own RE-SCOPE recommendation for
  `treeGun.{I,II}`: "wire these as literal progress toward `treeGun.{III,IV,V}` becoming a lit
  mode… rather than leaving them decorative."

## The mechanism: "bank lights the jackpot," uniform across all 8 trees

At the moment a team claims a tree's TOP tier (index `AchievementTiers - 1` — the same tier the
existing FIRST-claim bonus already singles out), count how many of that SAME tree's four LOWER
tiers (indices 0-3) the team already claimed THIS episode. This reuses `sim.claimed` — state that
already exists, per-team per-(tree,tier) — no new `SimServer` field. Call this `lightCount`
(0-4). Fold an extra `RecutModeLitLadder[lightCount] = [1, 1, 2, 3, 4]` on top of whichever base
tier-price already ran (classic `RecutTierClass`/`recutAchievementFactor`, or, if
`catalogV3Reprice` is separately armed, the v3 percent-scaled `RecutTierClassV3Pct`/
`recutAchievementFactorV3Pct`) — orthogonal to which pricing table is active, applied strictly
after it, via the existing `recutFoldObserved` (a plain integer fold; the cap-hit fire counter
rides along for free, no new counter machinery needed for that half).

0 or 1 lower tiers lit → ×1, **no bonus, no regression**: a seat that only ever lands the rare
top-tier act alone scores exactly what it scores today. 2/3/4 lit → ×2/×3/×4: a real, escalating
reward for banking MORE of the tree's easier tiers along the way — i.e. for CHOSEN breadth of
play (diversifying kill types, not just landing the one rare shot). Composes multiplicatively with
the existing FIRST-claim ×3 (`AchievementFirstMultPct`, unchanged, top-tier-only by law already).

**Concretely, for `treeGun`'s top tier** (classic base ×4, FIRST ×12): today there are exactly TWO
achievable payouts. Armed, there are SEVEN: {4, 8, 12, 16, 24, 36, 48} — `lightCount∈{0,1}` leaves
the two originals untouched; `lightCount∈{2,3,4}` inserts five new rungs between and above them.
Under `catalogV3Reprice`'s own pricing (base 200%, FIRST 346%) the same ladder produces EIGHT
distinct percent values. This is the literal, direct answer to the cap-hit-cliff finding: it gives
the top of the distribution intermediate rungs it did not have, without moving the ceiling itself
(`RecutProductCapArmed` is untouched).

## Non-negotiables, checked off

1. **Switch + fire counter + manifest reachability.** `GameConfig.achievementLightableModes`
   (`sim_types.nim`), default `false`, read only inside `claimAchievement`'s already-armed branch
   (enforced by call-site placement, same discipline as every other S5 flag — no separate
   "requires gloryMultiplierRecut" validation needed). Fire counter: `GLORY_ACH_MODE_LIT` log line
   on EVERY armed top-tier claim (lightCount and the resulting bonus, `bonus==1` included, so the
   FULL distribution — not just the "lit" cases — is reconstructable from the log alone) plus a
   `GloryDeed` tier-2 event (`weapon="achModeLit"`) whenever the bonus actually folds (`bonus>1`).
   Manifest reachability: `achievementLightableModes` is a new `config_schema` property in
   `coworld_manifest_paintbot.json`, wired through `sim_config.nim`'s `update()` JSON reader, the
   armed-only echo (`echoRecutKeys`), and the flagSet realized-config stamp — all four, not just
   the `GameConfig` field. Proven from the MANIFEST PATH, not `defaultGameConfig()`, by
   `tests/test_manifest_schema.nim`'s own pre-existing generic instrument ("every schema property
   is consumed by config.update") plus a dedicated test in `tests/test_glory_s4b_modes.nim` that
   parses the manifest file directly and applies the sample through `config.update`.
2. **Four acceptance tests, re-run with modes ON, numbers cited.** See "Acceptance tests" below —
   run against a smaller, fully deterministic sweep, not the (uncommitted, unavailable) S5 Monte
   Carlo; the difference is named explicitly, not hidden.
3. **The artifact is named.** Every number below is reproducible via:
   `nim c -d:noSignalHandler --threads:on -d:useMalloc -r tests/test_glory_s4b_modes.nim`
   (this exact repo, this exact commit, this exact file — no `/tmp` script, no number without a
   command behind it).
4. **Default OFF, switch-OFF byte-identical.** Proven two ways in `test_glory_s4b_modes.nim`: (a)
   the pre-existing GATE-RULING-1 frozen recipe (BR superb 9,437,184) and its pinned gameHash
   (`7108621066401102251`) are reproduced UNCHANGED with `achievementLightableModes` merely present
   (but false) in `GameConfig`; (b) a claim with `lightCount=3` banked scores IDENTICALLY to one
   with `lightCount=0` when the switch is off — the ladder is computed but never folded.
5. **No GLORYVERSION bump.** Confirmed by construction: the new field is a `GameConfig` bool, the
   new fold reuses `recutFoldObserved` (already-armed machinery), and the new counter is a log
   line / an existing event kind with a new `weapon` label — no `SimServer` struct field added.

## Files changed

| file | change |
|---|---|
| `src/ctf/sim_types.nim` | new `GameConfig.achievementLightableModes*: bool` field |
| `src/ctf/glory.nim` | `RecutModeLitLadder` const + `recutModeLitBonus` pure func (zero imports added — glory.nim's own law) |
| `src/ctf/sim.nim` | wired into `claimAchievement`'s armed branch, top-tier-only, after either pricing table |
| `src/ctf/sim_config.nim` | default, `update()` reader, armed-only echo, flagSet stamp — for THIS switch only |
| `coworld_manifest_paintbot.json` | new `config_schema.properties.achievementLightableModes` |
| `tests/test_manifest_schema.nim` | one new `SampleJson` entry (reuses the existing generic consumption test) |
| `tests/test_glory_s4b_modes.nim` | new test file, registered in `tests/shard_1.nim` |

**Note on #504 overlap**: PR #504 (S6 ship draft, parallel, not depended on) is independently
wiring the FIVE pre-existing S5 switches (`catalogV3Reprice` etc.) into these same functions in
`sim_config.nim` and the same manifest file — a real but expected file-overlap risk for two
parallel lanes touching shared plumbing; this PR only adds its own switch's wiring and does not
touch or fix the five S5 switches' wiring gap (that is #504's fix). Flagged for the merging lead.

## Acceptance tests (numbers, `tests/test_glory_s4b_modes.nim`, local run cited below)

The S5 rig's own Monte Carlo (`/tmp/glory-s5/rig/s5_montecarlo.nim`) was never committed — a
different agent's `/tmp`, unavailable to this worker. Rather than cite numbers nobody else can
reproduce, this PR's acceptance-test suite is a smaller, fully DETERMINISTIC sweep: 3 fixed
deed-floor shapes (LOW/MID/HIGH; every included deed's `catalogV3Reprice` price is ≥200% so every
fold always registers, no GATE-RULING-2 floor ambiguity) × 5 `lightCount` values (0-4) × FIRST/not
= 30 paired (dark, armed) points, driven through real `awardDeed`/`claimAchievement` on top of the
already-landed S5-armed economy (`catalogV3Reprice` + `placementRampV3` + `gloryFixedPointScale`,
set by direct struct assignment exactly as `test_glory_s5_rig.nim` itself does). This measures
THIS LEVER's marginal effect, not a re-derivation of the full population-calibrated Monte Carlo.

Numbers below are the actual echoed figures from a local run of
`nim c -d:release --hints:off -d:noSignalHandler --threads:on -d:useMalloc -r
tests/test_glory_s4b_modes.nim` (Nim 2.2.10, this commit), reproduced inside the full CI
invocation (`tests/shard_1.nim`, which imports this file: 407/407 checks OK, 0 FAILED).

- **Jackpot gradient, classic pricing** (test `"classic pricing: DARK has 2 distinct tier-V
  payouts, ARMED has 7"`): `DARK=[4, 12]` (2 distinct), `ARMED=[4, 8, 12, 16, 24, 36, 48]` (7
  distinct).
- **Jackpot gradient, v3 pct pricing** (test `"v3 (catalogV3Reprice) pricing: DARK has 2
  distinct payouts, ARMED has 8"`): `DARK=[200, 346]` (2 distinct),
  `ARMED=[200, 346, 400, 600, 692, 800, 1038, 1384]` (8 distinct).
- **1) CONTINUITY** (test `"1) CONTINUITY: armed adds intermediate point-values the dark sweep
  does not have (max gap shrinks)"`): dark 16 distinct log2-glory points (max gap 9.000 bits),
  armed 24 distinct points (max gap 6.999 bits) — armed strictly widens the point set and
  shrinks the largest hole.
- **2) SEPARATION** (test `"2) SEPARATION: armed widens (never narrows) the gap between the
  LOW-shape floor and the HIGH-shape jackpot"`): LOW-floor → HIGH-jackpot spread dark=17.685
  bits, armed=19.685 bits — armed is strictly wider, never narrower.
- **3) CHOSEN share** (test `"3) CHOSEN share: at the HIGH shape's own jackpot (lightCount=3,
  FIRST), the mode-lit bonus is a real, independently-observable slice of the achievement
  axis's own magnitude"`): HIGH shape, lightCount=3, FIRST: total=22.370 bits,
  achievement-axis=4.376 bits (19.6% of total), of which the mode-lit bonus ALONE=2.585 bits
  (11.6% of total) — a real, independently observable slice, not the whole achievement axis
  (the pre-existing FIRST-claim ×3 and the tier's own base price account for the rest).
- **4) CAP-HIT** (test `"4) CAP-HIT: none of the 30x2 modest-shape points hit
  RecutProductCapArmed; a deliberately stacked scenario shows the lever CAN reach it"`): 0/60
  points in the ordinary sweep hit `RecutProductCapArmed` (matches the census's own near-zero
  finding); the deliberately stacked stress scenario (HIGH shape ×7 + a fully-lit FIRST claim,
  `deedMintCaps` off to isolate the raw product path) reaches `teamGlory=4,503,599,627,370,496`
  ≥ `cap=16,777,216` — the cap is reachable in principle once armed, not merely theoretical.
- **Per-tree coverage** (new in this PR, closing KNOWN GAP 1 — suite `"S4b per-tree coverage:
  all 8 achievement trees, uniform mechanism (KNOWN GAP closed)"`): all `AchievementTrees`(8)
  trees (`treeGun`, `treeSpray`, `treeGrenade`, `treeShield`, `treeMedKit`, `treeCarrier`,
  `treeDefender`, `treeSquad`) pass manifest-path reachability (armed via `config.update`, not
  a direct struct assignment), the `lightCount` 0..4 → ×1/×1/×2/×3/×4 ladder on that tree's own
  top-tier claim, and the fire-counter-exactly-once check (including a redundant re-claim of
  the same top tier not double-firing, via `claimAchievement`'s own `claimed[]` dedup) — 8/8
  OK, no failures.

Full local run, both CI shards (Nim 2.2.10, `-d:release --hints:off -d:noSignalHandler
--threads:on -d:useMalloc`, `tools/runtime_spike/fetch_deps.sh` provisioning the pinned
Wasmtime C API shard_2 needs): `tests/shard_1.nim` 407/407 OK; `tests/shard_2.nim` 782/782 OK,
including `test_shard_wiring` (confirms this file is not a dark, unimported test); the two
GATE-RULING-1 OFF goldens (`gloryProduct`/`teamGlory` 9,437,184 and `gameHash`
7108621066401102251) reproduce unchanged.

## Arming note (a future step, not this PR)

This PR ships DARK: `achievementLightableModes` compiles to `false` in `defaultGameConfig()`
(`sim_config.nim`), is absent from every manifest variant's `game_config` override block in
`coworld_manifest_paintbot.json` — only the schema's own `"default": false` documents the key
— and lands with no GLORYVERSION or GameVersion bump of its own.

Arming later is expected to follow the exact precedent PR #504 (`8b7e78a7`, "glory: S6 SHIP —
catalog v3 default ON, GLORYVERSION 16→17, GameVersion 61→62") already set for
`catalogV3Reprice` and its four S5 sibling switches: turn the key on inside the
`battle-royale-s2` flagship variant's own `game_config` block in
`coworld_manifest_paintbot.json` (the block at `"variantId": "battle-royale-s2"`), **not** in
`defaultGameConfig()`'s compiled default — a manifest-only arm of one already-shipped, already
dark-tested switch, gated on an explicit owner GLORYVERSION GO, exactly as #504's own commit
message frames it ("Arms, on the battle-royale-s2 flagship variant's manifest ONLY, never
`defaultGameConfig()`'s compiled default").

Arming is a **live scoring change** — it moves every tree's top-tier payout from 2 achievable
values to 7 (classic) or 8 (`catalogV3Reprice`) — and, per this codebase's own doctrine (the
same doctrine #504's own commit cites for its own bump), needs a GLORYVERSION bump, a
GameVersion bump, and a fixture re-record at that time: the same three-part cost #504 itself
paid (GLORYVERSION 16→17, GameVersion 61→62, nine `.bitreplay` fixtures relabeled + shell/replay
goldens regenerated + the static replay viewer rebuilt). None of that is done here, by design —
this PR's non-negotiable #5 ("no GLORYVERSION bump") is proven by construction, not by
inspection: a `GameConfig` bool, a fold that reuses already-armed machinery, and a log line —
no `SimServer` struct change, so nothing forces the bump yet.

One more fact this future arming decision should weigh: the jackpot band itself gains a
**gradient** it does not have today. Today's classic top-tier payout is effectively binary (2
achievable values, `{4, 12}` — `lightCount` is invisible to the score); armed, it becomes a
7-rung ladder (`{4, 8, 12, 16, 24, 36, 48}`), 8 distinct rungs under `catalogV3Reprice`. That
gradient is this PR's own direct, literal answer to `RIG-SIMULATION.md`'s cap-hit-cliff finding
(14.5/15/15.5/16 all read 0.0000%, nothing between 12 and 14) — so **the cap-hit cliff, not the
mean or the CHOSEN-share percentage, is the lever this specific arming decision should be
evaluated against** when the live re-measure happens.

## What this does NOT decide / NOT verified

- Does not touch `treeSquad.IV` (Clean Sheet)'s own separately-flagged "RE-SCOPE, highest
  priority" universal-freebie problem (`CATALOG-V3-DRAFT.md` §3) — Clean Sheet is tier 3, not a
  tree's TOP tier, and `treeSquad`'s actual top tier ("Victory Lap") is structurally dead in
  flagless 16-solo BR (needs a capture), so this mechanism never touches Clean Sheet's economics.
- Does not build the stateful "mode active window" / real fail-state timer `CATALOG-V3-DRAFT.md`
  §6 item 2 also proposes — this PR builds the SET-lights-JACKPOT half only (using existing
  per-episode `sim.claimed` state), not a time-boxed "enter/fail" state machine. That remains a
  larger, separately-costed build per the catalog's own "medium-expensive, new sim state for
  timers" note.
- The deterministic sweep's absolute point values are NOT directly comparable to
  `RIG-SIMULATION.md`'s own population-calibrated percentiles (different, smaller, toy deed
  shapes) — only the QUALITATIVE direction (gradient added, separation widened, share shifted
  toward CHOSEN) is claimed with confidence; the exact population-wide magnitude of the shift is
  not re-measured here and needs a live/replay-calibrated re-run, same as every other S5/S4b lever.
- `pactActive`'s missing engine-enforced expiry, the jackpot-lit-before-it-pays deed, and Clean
  Sheet's own re-scope remain open S4/S6 items, untouched by this PR.
