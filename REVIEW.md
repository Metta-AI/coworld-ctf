# BR launch review package

This is the guided read for Maxwell's final review of `maxwell/br-integrate`
before it merges to `main`. It covers ~150 commits on
`git log origin/main..origin/maxwell/br-integrate` (some content appears
under two hashes — a mapgen lane was committed once directly on this branch
and again on standalone `maxwell/br-mapgen`, then the two were reconciled by
merge commit `1ea2ae4`; both hashes point at the same work, and this doc
cites whichever is more legible). Every claim below is traced to a commit
hash, a test name, or a number lifted from a report or test file in this
tree. Anything I could not trace that far is marked **UNVERIFIED** rather
than asserted as fact — see the end-of-package list.

Dashboard: **http://127.0.0.1:21400/** — the coordinator's own "everything
watchable" page, current as of this writing. It links four live demos,
which this doc points to by name rather than re-deriving new ones.

---

## 1. The 16-team engine core

**What changed.** The engine's `Team` enum widened from 4 members to 16 (12
new BR-only colors after Yellow), three separate `[2,4]`-team gates moved to
accept 16, and a fixed-arity flag/pedestal spawn model grew a second,
independent spawn system: an N-point-per-team `spawnPoints` list that a
flagless map can author instead of a `teamAnchor`. On top of the widened
roster, the branch adds two new game mechanics — a no-respawn elimination
ruleset (`brMode`) and a shrinking rectangular kill-zone (`zonePhases`) —
and fixes two separate places where the bots' own perception silently
stayed capped at the old 4-color roster after the enum widened.

**The evidence.**
- **Team widening** — `6378493` ("Stage B: widen Team to 16 for BR play").
  Moved the `[2,4]` gates (`activeTeams`, `sim_config.validate`,
  `generateMapAttempt`), extended the exhaustive `case team` switches, and
  relocated several sprite/wire-ID pools that were packed 4-wide with only
  4–100 ID of headroom (carry hearts, flags, flag auras, planted flags,
  identity badges, endzone fades) before they'd have silently overlapped a
  neighboring pool at 16 teams — caught by the pools' own compile-time
  non-overlap `static: assert`s, not by a test. Verified live by
  `780d268`'s `tools/team16_smoke_probe.nim`, which runs the real
  init/step path and confirms all 16 teams dispatch `teamText`/
  `teamColor`/`teamEndzoneColor` with no `raiseAssert` catch-all hit, and
  pins the exact next boundary (`generateMapAttempt` still has no 16-team
  map shape at that point — that's section 2's job).
  `eb0f207` then found and fixed one *live* collision the WIP had flagged
  and deferred: `SpritePlayerFlagObjectBase` at `5009+ord(team)` walked
  onto two other pools' IDs once `Navy`/`Azure` (ord 12/14) existed —
  caught by `test_player_fog.nim`, which had hardcoded the literal object
  IDs `5009`/`5010` instead of the constant, so the relocation broke two
  checks (shard 3 red) until fixed to reference the constant.
- **Elimination** — `cd93881` ("Battle-royale elimination ruleset: no
  respawns, last team standing wins"). `config.brMode` forces lives to 0 on
  first death and skips the capture-elimination branch entirely, so
  flags/captures can never end a BR game — only wipe/last-team-standing
  can. 13 new tests in `tests/test_br_elim.nim` cover no-respawn, win-on-
  last-team at 2 and 4 teams, simultaneous-wipe draws, capture-as-no-op,
  and determinism (same seed twice → same winner + `gameHash`). Commit
  message states "Full existing suite (637 tests total) passes
  unmodified." `4db68b3` ("BR timeout is a strict TOTAL order: no draws")
  then closed the one gap `brMode` didn't: a clock-out tiebreak ordered by
  living-players → last-death-tick → kills → damage → seat, eliminating
  the passive-double-death draw pattern flagged from field study of
  reference BR replays (BR_MAPGEN.md §6.6).
- **Zone** — `14f5688` ("BR shrink zone: config-gated rectangular zone
  (§4.3), core mechanic + tests"). A `zonePhases: seq[ZonePhase]`
  GameConfig field (empty by default, byte-identical when unconfigured)
  drives an aspect-matched rectangle that shrinks about a per-game-drawn
  `zoneCenter`, dealing `dps` to anyone outside it on the same per-second
  cadence as puddle damage. `tests/test_zone.nim` (605 new lines) covers
  rect math, 200-seed center-draw bounds, monotone-z validation, damage
  cadence (inside/outside/shield-soak/lethal/dps=0), label grammar, and
  determinism. The zone's rectangle-not-circle shape and drawn (not
  fixed) center are direct doctrine calls — BR_MAPGEN.md §4.3 explains why
  a circle wastes ~47% of the board on a 1.874:1 aspect field, and why a
  fixed center would hand a permanent edge to central spawns.
- **Spawn subsystem** — `17ce525` ("BR spawn subsystem: flagless N-point
  spawnPoints on CtfMap"). Doctrine originally specified spawns as "16
  positions equally spaced on an inset rectangle ring" (BR_MAPGEN.md §1);
  Maxwell's later ruling superseded that with a jittered 4×4 grid across
  the whole field and explicitly deleted all spawn keep-away ("we banned
  that" — `ee9d428`, round 5). `0e16d13` then made the team↔spawn-group
  assignment rotate per episode (a hashed `(team+offset) mod groups`, so
  no team owns a grid cell across every episode on a map — closes the
  "measured per spawn, not per team" fairness precondition doctrine's
  §2.5/§3.1 rest on). `76a7af9` ("BR bridge: derive a map's team count
  from its spawn GROUPING") is the connective tissue: `CtfMap.teamCount()`
  previously only knew 2 (sides) or 4 (corners/plus) from `TeamLayout`, so
  a 16-team config was rejected with `"map seats 2 teams"` regardless of
  how many spawn points the map authored, until this commit added
  `CtfMap.spawnGroups` as the authoritative, replay-pinned source. 9 new
  tests in `tests/test_br_team_bridge.nim` (shard 1).
- **Perception fix, enemy side** — `a657df4` ("BR endgame: fix the
  hunt-override null — enemy perception was 4-color-capped"). Root-caused
  the stall BR_FINAL_MATCH_REPORT.md documented (two survivors, 599px
  apart, motionless for a 363-tick eligibility window): `bot.enemies` was
  fed by `TeamColorNames[0 ..< GameTeams]`, a hardcoded 4-entry array with
  `GameTeams` itself clamped to `[2,4]` — any of the 12 non-primary BR
  colors could never appear in *anyone's* threat scan, matching the final
  match's own combat log (only red/blue/green/yellow ever fired).
  Fixed with an unclamped `RealTeamCount` captured alongside the existing
  clamped `GameTeams`, and a 16-color `BrRosterColorNames` roster used only
  when `RealTeamCount > TeamColorNames.len`. Verified with a re-recorded
  match (`br-match-2-huntfix.bitreplay`): a primary-color bot logs
  `HUNTFIRE ... target=2026,560` where the target is a non-primary color's
  position — a track that could not have existed in `bot.enemies` before.
- **Perception fix, self side** — `86e053c` ("BR bot: fix own-color
  resolution past the 4-primary roster (bots never moved)"). A second,
  independent bug from the same root cause: `bot.myColor` resolution in
  `buildNavGrid` and `decide`'s self-marker confirmation loop both indexed
  the same 4-entry `TeamColorNames` via `GameTeams`, so any seat past
  Yellow could never confirm itself alive and sent **zero input for the
  whole match** — "not a passive bot: an invisible one to itself," per the
  commit message. Fixed via two shared helpers (`rosterColorCount()`/
  `rosterColor(i)`) used at both call sites and folded into the enemy-side
  fix so there's one ternary, not two. Verified against a fresh 16-duo
  recording (`br-match-showmatch-4242.json`): all 16 teams show real
  displacement (1737–13149px) and real shots fired (2–27) before
  elimination; **zero** teams under a 50px floor or with zero shots. The
  match's winner was `pink`, a non-primary color — cited in the commit as
  evidence the fix works, since the pre-fix bug made a primary-color win
  "close to guaranteed."
- **GV44 interaction** — `aaad18e` ("GV44 x BR: fix homeSlot's undefined
  layoutSides case, add the interaction test"). Rebasing onto `main`'s
  GV44 ("deal the homes" rotation) surfaced a real bug the line-based
  auto-merge introduced silently (a stale `team` identifier reference
  caught only by `nim check`, not the merge), plus a second, latent bug:
  `homeSlot`'s rotation math assumed `rot90Quarter` defines a real orbit,
  but a 16-team BR board reports `layoutSides` (the "no sides/corners"
  default) where `rot90Quarter` is a constant 0 — without a guard, every
  team's anchor could collapse onto Red's single point. This was inert
  only because BR's `spawnPoints` path bypasses `teamAnchor` in every
  consumer that currently reads it — "one new reader away from a real
  bug," per the commit. `tests/test_gv44_br_rotation.nim` pins the fixed
  contract: GV44's rotation is genuinely live on a 16-team map, `homeSlot`
  is identity there regardless, and BR seat placement is provably
  independent of it (re-run with several forced overrides, diffed
  seat-for-seat).

**How to see it.** The golden 16-team match at
`http://127.0.0.1:21404/loop.html?replay=golden.bitreplay` (dashboard-listed
as "LIVE — current engine (GV45)") shows all 16 duos moving, fighting, and
being eliminated — the direct visual confirmation that both perception
fixes hold. Test commands: `nim c -r tests/tests.nim` from the repo root
runs the full shard set including `test_br_elim.nim`, `test_zone.nim`,
`test_br_team_bridge.nim`, `test_br_spawn_points.nim`, and
`test_gv44_br_rotation.nim`.

---

## 2. Map generation

**What changed.** `tools/brmapkit.nim` (7659 new lines) is a **fork**, not a
patch, of the existing 2-team `mapkit.nim` — same generate/render/validate
loop and anti-confetti discipline, but with the symmetry/layout/team gates
dropped entirely in favor of full-board asymmetric authoring for 16 spawn
groups. It went through 13 numbered rounds plus 8 follow-up "instrument
fix" commits, each one a real design correction driven by a specific
rejected draw, not open-ended tuning. Full doctrine lives in
`docs/designs/BR_MAPGEN.md` on `maxwell/ladder-scout-tooling` (see §7 below
— that file is not present on this branch or on `main` yet).

**The evidence — round-by-round arc** (commit → what broke → what changed):
| round | commit | what it fixed |
|---|---|---|
| 1–3 | `9883596`/`8a3a30f`/`f285451`/`55fd8f6` | forked the tool, fixed off-field boundary sampling, added distribution gates + POI structures + items |
| 4 | `9282401`/`9c17888` | placement rework, POI pocket-clearance/geometry bugs |
| 5 | `ee9d428`/`279679e` | **spawns → jittered 4×4 grid, deleted spawn keep-away, uniform density** (Maxwell's rulings — "we banned that"). New density-uniformity gate (8×4 grid, empty-cell count) discriminates cleanly: 20 uniform-sampling seeds landed at 4–14 empty cells (mean 8.5) vs. a center-clustered probe's 15–20 (mean 17.8), zero overlap |
| 6 | `99acb65`/`d1acb1f` | keystone families — the intent layer (doctrine §2.4), floors calibrated against a cross-family corpus |
| 7 | `022653f`/`1076a8d` | **the subtractive reframe**: solid welded masses with rooms carved into them, replacing thin additive wall lines |
| 8 | `7429df1`/`f2d6bb2` | mass **quantity**: cover-permille + distance-to-cover gates, 3x the mass, stratified POI placement |
| 9 | `f636534`…`1ef1b40` | multi-room interiors, gate-avoidance, clip-not-drop, interior-connectivity repair |
| 10 | `c18853a`/`e40873d` | two new interior grammars (maze, branching cave) + a hard accessibility gate |
| 11 | `01c0631`/`475c6d2` | **accretion-grown complexes** replace solitary buildings (singles up to rare 12–16-unit fortresses); TERRAIN/THEME switches added (11b) |
| 12 | `1730c2f`/`9e76c39` + `76bdc1c`/`3f78512` | **the burrow requirement** (see below) |
| 13 | `3b7d74f`/`bdc95cf` | **feature ALL items — per-item gradient over site classes** (see below) |
| fixes 1–8 | `e640c5d`…`189c358` | see below |

**Round 12 — the burrow requirement, measured (`burrowPass`).** Maxwell's
hard gate: "every structure at every scale must read as solid mass that
rooms were DUG INTO — never drawn walls." Part 1 (`9e76c39`) root-caused
the negative reference (seed 601's "thin meandering walls, dangling stubs")
to `stampRoomMaze` drawing wall *rects* only where a passage was absent,
leaving a passage's whole shared edge open — inverted to floor-cavity-first
construction with explicit bounded-width bridges. Part 2 (`3f78512`) added
the actual measured gate, per connected wall component:
(a) thickness floor via chamfer-depth erosion, (b) no dangling stubs via
skeleton-endpoint depth walk, (c) enclosure — opening fraction capped to
declared gates only, (d) mass unity — every complex's units must weld into
**one** component, zero tolerance ("a compound counts as ONE mass").
**Discrimination proof**: `computeBurrow` FAILS on the historical seed-601
negative reference unchanged (`splitComplex=2`) and PASSES a fresh draw of
the *same seed* under the fixed generator (`splitComplex=0`). 100-seed
sweep: `burrowPass` 85/100, with connectivity/exit-rule/anti-confetti/
zone-viable/spec-size/item-coverage/POI-loot/full-access all 100/100 (no
regression on any pre-existing hard gate).

**Round 13 — feature ALL items, per-item gradient (`bdc95cf`).** Maxwell's
ruling on round 11's maps: "definitely the best yet! but they only have med
kits... create a gradient for each item type based on rooms then corners,
alleys, and exciting hotspots." A site classifier (ROOMS/CORNERS/ALLEYS/
HOTSPOTS, detected off the built geometry) feeds a weighted table per item
type (medkit 40/20/25/15, shield 25/10/25/40, grenade 15/25/40/20, spray
40/30/20/10 across rooms/corners/alleys/hotspots) plus hard rules the table
can't express (min separation, shield/grenade never co-locate, etc.).
**Discrimination proofs, both directly measured**: (1) swapping medkit's
and shield's point arrays in a passing spec drops shield/hotspot realized
occupancy from 40% (matching its declared share) to 6% (fails the 30pp
tolerance gate); (2) clustering one map's shields into a single patch moves
the per-spawn walk-graph-distance spread from stddev 341px (pass) to 990px
(fail) on the identical map. 100-seed sweep: item-gradient gate 90/100,
item-fairness gate 86/100, with every round-12 hard/soft gate holding at
*identical* numbers to round 12's own sweep (burrowPass still 85/100 —
"confirming item placement never touches map geometry").

**The instrument fixes (`e640c5d`…`189c358`, 8 commits).** These are fixes
to the *measurement tools themselves*, found by cross-checking rather than
trusted blindly: fix 1 (confetti prune was sampling a single centroid point
that can land outside a crescent shape's own concave notch, silently
deleting legitimate masses); fix 2 (four hand-built maps with a *known*
correct classification, independent of the classifier under test — a
classifier bug otherwise makes placement and validation agree even when
both are wrong); fix 3 (`generate` now refuses to write or echo a failing
map by default — previously it wrote unconditionally and only logged
`allPass=false` to stderr); fixes 4–8 (loud iteration-limit warnings, alley
candidates never landing on a wall, gate-mouth detection rebuilt on a
non-leaking flood, item sites snapping off real obstacle geometry, a
gate-mouth significance filter + shield budget ceiling).

**How to see it.** `http://127.0.0.1:21401/review/index.html` — the
dashboard's "Map generator review board," listed live, with contact sheets
for every round 1–13 including the burrow rebuild and the all-items
gradients. Test command: `nim c -d:release -o:/tmp/brmapkit
tools/brmapkit.nim && /tmp/brmapkit selftest` runs the golden geometry
tests from fix 2; `/tmp/brmapkit generate --seed <n> --keystone <name>`
reproduces any draw.

---

## 3. Items end to end

**What changed.** BR maps place four item types (medkit, grenade, shield,
spray) as neutral, un-team-keyed pools, sized to the draw (the showmatch
map: 33 medkits, 36 sprays, 14 grenades, 7 shields) — a very different
scale from the classic engine's fixed 2–4-point team pools. Wiring all four
through the engine, and then fixing the wire-ID collision that scale
caused, took five separate commits.

**The evidence.**
- **medkit** was already a neutral pool pre-BR; `5177cb0` fixed
  `resetMedKits` to gate on *any* authored pool (`> 0`) instead of
  requiring `>= 2`, matching the other three families' "any pool wins"
  rule — a latent inconsistency that never mattered for BR itself (which
  always authors far more than two) but is now uniform.
- **shield + spray** — `a201799` ("BR items: wire shieldSpawns/spraySpawns
  end to end"). Added `CtfMap.shieldSpawns`/`.spraySpawns` (`seq[MapPoint]`,
  same shape as `medKitSpawns`), spec JSON round-trip in `arena.nim`, a
  forwarding path in `br_spec_to_ctf.nim`, and the "map's own pool first,
  formula fallback" rule in `sim.nim`. Verified live in
  `BR_SHOWMATCH_REPORT.md`'s server log: `yellow picked up a spray can`,
  `yellow sprayed paint`, `red picked up a spray can`.
- **grenade, the last holdout** — `a5acd93` ("BR items: wire grenadeSpawns
  end to end, the last of the four item pools"). Grenades were a fixed
  `array[4, PickupSpawn]` everywhere, including the wire/replay format —
  a real engine type change, not a bridge-tool one, which is why it landed
  separately. `CtfMap.grenadeSpawns` and `SimServer.grenadeSpawns` both
  widened to `seq`. **Byte-identical proof**: resimulating the pre-existing
  `tests/fixtures/capture-seed1.bitreplay` (a classic 2-team map, recorded
  2026-08-11, well before this change) end to end reproduces all 5424
  recorded per-tick hashes exactly — the classic-formula fallback is
  untouched. Confirmed live: `tools/extract_events` shows grenade pickups
  at exact matches to the draw's authored `grenadeSpawns` list, and one
  point 6px off its authored coordinate — "the expected nearest-walkable
  nudge" (`placeWalkablePickups`).
- **The pool-id fix** — `535a375` ("BR item pools: rebase the four neutral
  pickup pools off their 4-team width"). `global.nim` had declared all four
  pickup object-id pools at width 4 (a ≤4-team holdover). At BR scale, `base
  + i` for `i` past the declared width wrote directly into the next pool's
  ID range — concretely, medkit index 10 collided with
  `RotDiamondObjectBase`, and spray index 20 collided with
  `SprayPaintCarryObjectBase` — two item families claiming the same wire
  object ID in one packet, so the client's per-id table kept only one and
  corrupted the other's sprite. Widened all four to a shared
  `NeutralItemPoolWidth=64` and relocated them to open wire space; the
  render loops now clamp to the pool width and `doAssert` if a map ever
  authors more, and the compile-time `BoardObjectPools` audit proves the
  layout is collision-free. Object IDs are presentation-only — `gameHash`
  never mixes them, only `spawn.present`/`respawnAt` — so this needed no
  GameVersion bump. Two new tests reproduce the exact historical collision
  against the pre-fix layout and confirm the fixed render loop stays
  collision-free at BR showmatch scale with a full 32-player roster
  carrying every item at once.
- **Guardrails found after wiring** — `d75363a` (`validateMap` now rejects
  a flagless, multi-spawn-group map outright if any of the four neutral
  pools is empty, naming which one — closing a gap where the classic
  fallback formulas would otherwise silently misbehave: grenades seating
  a fixed 4-corner formula no real BR map should hit, shields/sprays
  silently seating zero) and `c6a22c4` ("Ingest tests: authored spec pools
  win over the classic formula (positive path)") — five direct spec-key
  tests (`tests/test_item_pool_ingest.nim`) proving each of the four
  `reset*` procs actually places the map's authored pool, nudged to
  `sim.nearestWalkable`, in preference to its formula fallback: e.g.
  `"shieldSpawns: an authored pool is placed at nearestWalkable(authored),
  not the per-team formula"`, `"all four pools authored together on one
  map: every family wins independently"`.

**How to see it.** `tests/test_fx_pools.nim`: `"BR-scale item pools (33 med
kits, 36 spray cans, 14 grenades, 7 shields) never collide with each other
or any other object pool"` and `"med kits / shields / spray pickups /
grenade pickups assert rather than silently overflow their pool"` are the
two tests that pin this section directly — `nim c -r
tests/test_fx_pools.nim`. Visually: the golden match at
`http://127.0.0.1:21404/loop.html?replay=golden.bitreplay` shows pickups
from all four pools (per `test_br_golden_e2e.nim`'s own assertion, see
section 5).

---

## 4. Scoring

**What changed.** Pre-this-lane, `finishGame`'s reward logic only ever
scored the single last-standing team; every other team took a flat
loss regardless of how far it got, and `AchievementPacifist`/
`AchievementSpotless` could stack on a win with zero combat. This lane adds
a full 1..N placement rank, a reward schedule keyed to it, and an
engagement gate that closes the free-achievement hole — all gated behind
`brMode` so classic play is untouched.

**The evidence.**
- `3e69085` ("BR placement: rank-keyed loser reward, gated on engagement
  (§7.3)"). `brRankedTeams`/`brPlacements` generalize the existing maxTicks
  tiebreak's own total order (living → last death → kills → damage → seat)
  from "pick one winner" to "rank every seated team" — a pure function of
  already-hashed per-tick state, so nothing new enters `gameHash`. A
  losing team's reward becomes `lossReward + BrPlacementBonus[rank]`,
  clamped below the winner's own reward at every team count, and **gated on
  engagement evidence** (`attacksMade>0 or damageDealt>0` anywhere on the
  team) — no evidence, no placement credit, just the plain loss floor.
  The same gate applies to `AchievementPacifist`/`AchievementSpotless` in
  `brMode`; since a hit always requires its attacker to have fired first,
  `Pacifist` is unearnable in `brMode` by construction, while `Spotless`
  keeps its meaning but now also requires the team to have fought.
- `5ad5ffe` ("BR placement: unit tests for rank, engagement gate, and the
  achievement stack") — scripted mini-episodes covering full 1..16
  placement assignment (including a fully-tied field resolved only by the
  seat tiebreak), the engagement gate on both sides (zero-engagement 2nd
  place scores the plain floor; `damageDealt` alone without `attacksMade`
  still counts), monotone non-increasing reward by rank always strictly
  below the winner's, the 2-team clamp holding, `brMode:false` staying
  byte-identical to classic +1/-1, and hash discipline (same scripted
  episode run twice gives the same reward and hash).
- **The UNCALIBRATED flag.** `sim_types.nim`'s own doc comment on
  `BrPlacementBonus` states directly: *"UNCALIBRATED: this is a
  conservative placeholder shape (small, monotone, bounded well under a
  win), not a tuned one — the evidence phase (real BR replays) picks the
  actual numbers."* `docs/ENV_VARIATION.md` repeats the same language
  verbatim. This is a real, load-bearing caveat, not boilerplate: nothing
  in this branch calibrates the schedule against field data.

**How to see it.** `nim c -r tests/tests.nim` (shard 1) runs
`test_br_placement.nim`. `src/ctf/sim_types.nim`'s `BrPlacementBonus`
definition (grep `UNCALIBRATED`) is the flag itself — read it before citing
any placement number as tuned.

---

## 5. Test hardening

**What changed.** Three threads converge here: the owed GameVersion bump
(rules identity, not corruption avoidance), a from-scratch 16-team golden
end-to-end fixture (the launch-readiness audit's stated #1 gap — "nothing
in CI had ever stepped a 16-team sim"), and one real interaction bug the
GV44 rebase silently introduced and this lane caught.

**The evidence.**
- **GV44 interaction fix** — covered in section 1 (`aaad18e`); repeated
  here because it's a test-hardening artifact as much as an engine one:
  `tests/test_gv44_br_rotation.nim` is a genuinely new interaction test,
  not a re-run of either feature's own suite in isolation.
- **GV45 — the bump, and the refuted reason for it.** `c273120` ("Record
  the owed GameVersion bump, and REFUTE the reason given for it") is worth
  reading directly: it took GV44 temporarily, ran the suite, then
  *reverted* it, specifically to test the stated justification (BR_MAPGEN.md
  §6.2's prediction that widening `Team` 4→16 would silently misalign old
  keyframes via `array[Team, X]` fixed-width flatty fields). **It does not
  reproduce** — every GV43 fixture still loads, re-simulates, and hashes
  equal with the enum 16 wide, because keyframes are derived in-process and
  never cross a file boundary. The bump was taken later (`3a8df80`, GV45)
  for the honest reason instead: "a replay's version string should say so"
  — this build seats 16 teams, runs elimination, and closes a zone, none of
  which any earlier version's rules could produce.
- **Fixture re-record discipline.** `9b7cf37` explicitly *declined* to
  re-record fixtures under machine load this session ("1-minute load sat
  at 16–32 (14 cores)... a CPU-starved speed-16 recording drops its bots
  and produces a degenerate ending, which is how the GV42 draw-nokill
  fixture went wrong once already"), and waited for an idle window.
  `b33acf8` then re-recorded all **six** pinned fixtures (not just the four
  the native shards read — `gen-small-pits`/`gen-colossal-4team` are
  wasm-viewer-only and go stale silently otherwise), and checked each
  fixture's documented ending directly against the re-simulated event
  stream rather than assuming it: `capture-seed1` still ends in a capture
  at tick 6881 (winner blue), `wipe-lives1` still ends in a wipe,
  `draw-nokill` is still a genuine time-limit draw. **Zero re-pinning
  needed** — every existing hardcoded assertion already matched the fresh
  recording, "because classic 2-4 team play is provably unaffected by
  everything GV45 actually changed."
- **The 16-team golden's contracts** — `2043dd9` then `3f6f87b`.
  `tests/test_br_golden_e2e.nim` loads a real, bot-played 32-seat (16 duo)
  recording — deliberately not scripted inputs, because "a scripted-input
  test exercises the ENGINE's BR mechanics but never the POLICY's own
  perception of a wide roster, which is exactly where both defects this
  fixture is designed to catch actually lived" (the endgame stall and the
  own-color cap from section 1). It re-simulates hash-validated (raises on
  any mismatch) and asserts: a winner exists or a documented draw;
  eliminations are monotone; zone damage fired; pickups happened from all
  four authored pools; and — the permanent regression guard for the
  perception bugs — every one of 16 teams displaces beyond a floor
  (`MinDisplacementPx = 500.0`, set with wide margin under the recording's
  actual quietest team at ~1547px) and at least 12 of 16 fire a shot
  (`MinTeamsFiring = 12`, margin below the recording's actual 16/16).
  Recording it took **three attempts**, reported honestly rather than
  discarded quietly: seed 4242 first attempt passed every property except
  item pickups (the shield pool is genuinely sparse — 7 points on a
  3211×1713 board — and that take's real bot paths never crossed one);
  seed 1337 regressed further (no zone damage, resolved before the zone's
  early no-damage phase ended); seed 4242 re-run passed clean and was
  kept. A real test bug was found and fixed along the way: "eliminations
  are monotone" was reading the pre-`startGame` lobby frame (0 living
  players for every team) as a false "came back from the dead" for the
  rest of the episode — fixed by gating on `everAlive`, and the fix was
  verified against the discarded attempt-1 recording before being trusted
  on the kept one. Final numbers: 3673 ticks, winner `lime` (non-primary —
  the same regression-guard signal as the bot-fix commit's `pink` winner),
  all four item types picked up, 12 zone-damage events. Wired into shard 4
  only on the passing attempt (`tools/record_br_golden.sh`'s own design:
  "a recording that fails the suite is refused, never silently wired in as
  a bad golden").
- **Consolidation, not duplication.** `5324e9c` folded a second,
  gitignored verification recording (`br-showmatch2.bitreplay`, the
  hunt-fix evidence) into the same golden fixture rather than committing a
  second large binary asset for overlapping evidence — the hunt-fix
  property (in the final ≤4-alive-teams window, the eventual winner's
  distance to its nearest living enemy trends down, net convergence rather
  than frame-by-frame monotonicity) now lives as its own suite reading the
  one golden fixture.

**How to see it.** `nim c -r tests/tests.nim` from the repo root — 4
shards, all green per `3f6f87b`. A static count of `test "..."` blocks
across `tests/*.nim` in this tree comes to 765 (grep count, not a live run
— treat as an order-of-magnitude figure, not an authoritative pass count;
commit messages along the way cite live run totals of 707/707 OK at the
items-wiring stage and "4 shards green" at GV45/golden).

---

## 6. Zone paint — **PENDING**

**Status: not in this branch.** Everything BR_FINAL_MATCH_REPORT.md and
BR_SHOWMATCH_REPORT.md say about zone paint (`d8e958c`'s tide-cache fix,
the flat edge bars, the meniscus) describes the **old renderer** — flat
rect, hard edge, gloss circles, the version currently live on the golden
match at `http://127.0.0.1:21404/`. A separate, still-active lane
(`maxwell/br-paint2` → `maxwell/br-paint3`, and a further in-progress
lane not yet pushed as of this writing) rebuilt zone paint from scratch as
a physically-simulated fast-marching fluid front (Sethian's eikonal
solve over the floor domain, door-aware, once-per-episode field
construction instead of a per-tick rebuild) — a materially different
approach from anything described in the two match reports above, and it
has **not merged into `maxwell/br-integrate`**. The dashboard's own
"REBUILDING" tag on `http://127.0.0.1:21406/loop.html?replay=golden.bitreplay`
("Fast-marching fluid... the next thing to judge") and the frozen
`http://127.0.0.1:21405/index.html?replay=br-showmatch.bitreplay`
("the 'cheese' version you rejected") confirm this directly.

**The bar it needs to clear before landing — six machine checks**
(`tests/test_zone.nim`, "paint arrival honesty" + "fingering and
front-propagation causality" suites, run against the real tracked
showmatch map). As of the latest visible commit on the paint lane
(`a7879e9`, on `maxwell/br-paint3`, not on this branch):

| # | check | status as of `a7879e9` |
|---|---|---|
| 1 | painted(p) at tick T implies p is outside rect(T) — the honesty gate, zero tolerance beyond the corner-round bound | PASS |
| 2 | a dry outside cell's arrival never exceeds the flow-delay cap | PASS |
| 3 | the arrival field builds once per episode, never per-tick | PASS |
| 4 | no straight run > ~100px (open-field must show fingering, not a flat rect edge) | PASS (fixed in `a7879e9`; was 640px) |
| 5 | a room's own minimum arrival never beats its doorway band's minimum (door-first, not back-wall-first) | PASS (fixed in `a7879e9`) |
| 6 | Spearman rank correlation between arrival and aperture-weighted geodesic distance from the doorway, bar 0.8 | **OPEN** — best result on the real map: 1 room clears the depth filter, r=0.41 (right-signed, short of the bar) |

Per `a7879e9`'s own commit message: "Not patched further this pass —
flagging honestly rather than re-tuning the threshold to make it pass
without understanding the remaining gap." Full suite at that commit: 712
pass / 1 fail (check 6 only).

**What this means for launch.** Section 1–5 of this package do not depend
on zone paint's renderer — the mechanic (rect math, damage cadence,
elimination) is fully tested and merged; only its *visual* front-propagation
is still being replaced. If the paint lane is not ready by Maxwell's
review, the branch can ship with the current renderer described in
BR_FINAL_MATCH_REPORT.md (functionally correct, cosmetically a hard rect)
and the new paint front lands as a fast-follow — that is the coordinator's
own framing on the dashboard, not a claim this document is making
independently.

---

## 7. Known-open items and decisions Maxwell must make

1. **Glory-vs-placement scoring for v1.** BR_MAPGEN.md §1 states the
   design intent plainly: "Win | last group standing, **scored in glory**."
   What actually shipped on this branch is the placement-rank reward
   schedule from section 4 (`BrPlacementBonus`), which is explicitly
   **UNCALIBRATED** and is not glory at all — it's a small, monotone
   `sim_types.nim` reward table, not an integration with the platform's
   glory/achievement system used elsewhere. BR_MAPGEN.md §7 question 3
   also flags a real tension for whichever scoring model ships: field
   evidence from reference BR replays showed survival-derived scoring
   terms must cap or taper late, "in clock-capped games observed in the
   field, survival points outscored fighting and farming beat the final
   fight" — a glory-scored BR "must not reintroduce the farming vector
   through survival deeds." **Decision needed**: ship v1 on the
   uncalibrated placement schedule (as this branch does), or hold for
   glory integration first. This document takes no position on which is
   right.

2. **The doctrine doc is not on this branch — merge order matters.**
   `docs/designs/BR_MAPGEN.md` (the design document this whole package
   cites throughout — §2.1, §4.2, §4.3, §4.9, §6.2, etc.) lives **only** on
   `maxwell/ladder-scout-tooling`, not on `maxwell/br-integrate` and not on
   `main`. This is not a cosmetic gap: 20 files in this tree
   (`git grep -l BR_MAPGEN`, excluding this document itself) cite it by name
   and section number in their own comments and doc strings, including
   `src/ctf/sim_types.nim`, `sim.nim`, `sim_state.nim`, `sim_config.nim`,
   `arena.nim`, `global.nim`, `map_art.nim`, `rig_art.nim`, `server.nim`,
   `wire_constants.nim`, `tools/brmapkit.nim`, `tools/br_spec_to_ctf.nim`,
   `tools/team16_smoke_probe.nim`, `docs/RULES.md`, `docs/ENV_VARIATION.md`,
   `BR_FINAL_MATCH_REPORT.md`, and five `tests/test_br_*.nim`/`test_zone.nim`
   files. If `br-integrate` merges to `main` without `ladder-scout-tooling`'s
   doc also landing, every one of those citations becomes a dangling
   reference in the shipped tree.
   **Recommended merge order**: (a) land `maxwell/ladder-scout-tooling`'s
   `docs/designs/BR_MAPGEN.md` (and its accompanying doctrine commits) to
   `main` first or in the same PR, (b) merge/rebase `maxwell/br-integrate`
   on top, (c) re-verify the full suite post-merge. Also note: `main` has
   moved 7 commits ahead of `br-integrate`'s merge-base since this branch
   was cut (`bb1bf7b`..`6ecffcd`, mostly a "Paintball KOTH mode" merge and
   CI/image build changes) — `sim_types.nim` and `wire_constants.nim` are
   touched independently by both that work and this branch, so the merge
   will need real conflict resolution there, not a fast-forward, and
   should be re-suite-verified after.

3. **Zone paint pending** — see section 6 in full. Six machine checks, one
   open (door-first rank correlation, r=0.41 vs. an 0.8 bar), on a lane not
   yet merged into this branch.

4. **Pricing calibration pending evidence.** The `BrPlacementBonus`
   schedule (section 4) is explicitly a placeholder shape awaiting "the
   evidence phase (real BR replays)" per its own doc comment. No number in
   it should be read as tuned, and no claim in this package treats it as
   such.

---

## UNVERIFIED — claims this package could not trace to a source

- **"~110 commits."** The actual commit count on
  `git log origin/main..origin/maxwell/br-integrate` is 152, with
  substantial content duplication from the mapgen-lane merge (`1ea2ae4`)
  landing the same round-1–13 work under a second set of hashes. This
  document does not assert an exact deduplicated commit count.
- **The "launch-readiness audit"** referenced by name in several commit
  messages (e.g. `3f6f87b`, `2043dd9`) is quoted from those commit messages
  only — no standalone audit document was found in this tree or on the
  branches this package searched. Its existence and contents beyond what's
  quoted in commit messages are UNVERIFIED.
- **Wall-clock performance numbers** in BR_FINAL_MATCH_REPORT.md's tide-
  cache section (the "before/after median 1ms/p90 3ms" figures) are
  self-caveated in that report as "heavily caveated... weak evidence on
  its own" due to concurrent fleet load on the recording machine — this
  package repeats that report's own caveat rather than re-verifying the
  numbers.
- **`test_br_golden_e2e.nim` was not re-run by this reviewer** — its
  pass/fail state is taken from `3f6f87b`'s own commit message ("full
  suite (4 shards) confirmed green together") and the presence of the
  committed fixture files, not from an independent execution in this
  worktree.
- **The static 765-test-block count** (section 5) is a `grep -c 'test "'`
  count across `tests/*.nim`, not a live suite run. It is offered as an
  order-of-magnitude figure alongside the commit-message-reported live-run
  totals (707/707 OK, "4 shards green"), not as a replacement for them.
