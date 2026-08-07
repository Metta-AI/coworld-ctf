# The seven silent hex failures — measured, then fixed or refuted

Sweep of `maxwell/hex-integration` @ `214a05d` (the ship-gate tip), run
2026-08-07. Branch: `maxwell/hex-silent-failures`.

The audit ranked seven sim/perception rules that were written against a
RECTANGULAR playfield and mean something else on a hexagon. What makes this
family dangerous is that none of them crash: the code compiles, the episode
runs to completion, the wire stays well-formed, and the behaviour is simply
wrong. There is no exception to catch and no log line to grep. "No error" is
therefore not evidence of correctness, so **every claim below was reproduced by
running the code, and every fix was A/B'd on the same measurement**.

Three of the seven reproduced. Three did not. One is a documentation contract.
The refuted ones are the more interesting result: each was holding by an
accident of some *other* component, with nothing asserting it — so they get
tests rather than patches, and the tests name the premise they depend on.

## Scoreboard

| # | Claim | Verdict | Measurement |
|---|---|---|---|
| 1 | Grenade pickups permanently unreachable | **already fixed**, now guarded | 4/4 spawns walkable and touchable on 12 boards |
| 2 | Rect clamps project throws into the void | **CONFIRMED → fixed** | 19.8–20.4% of full-charge throws off-field → **0%** |
| 3 | Sliding fails on a 60° wall below a speed threshold | **CONFIRMED → fixed** | pulsed policy: 1px per 60 ticks → **30px**, = flat floor |
| 4 | Respawn drift out of the capture zone | **refuted**, now guarded | 0 escapes / 1600 draws over 8 boards |
| 5 | `GrenadeMaxRange` / `ShoutRange` inflate ~15% | **CONFIRMED → fixed** | arena 223 → **193**; giant 581 → 503 |
| 6 | FOV leaks through the diagonal edges | **refuted**, now asserted | 0 transparent void cells over 7 boards |
| 7 | The `game teams … map <W>x<H>` marker lies | **contract stated** | box 1119×969, playfield 1095×949 / 71.8% |

Plus: `tools/ladder/scout.py` resolved GameVersion from `src/ctf/sim.nim`,
which the sim split emptied — `our_game_version()` returned `None`, and the
skip is written `if gv and OUR_GV and gv != OUR_GV`, so the ladder's
engine-horizon check was **entirely dead** and every replay was re-simulated
regardless of the engine that recorded it. It now searches `sim_types.nim`
first, falls back to `sim.nim` for older checkouts, and **raises** instead of
returning `None` — a dead check reads as "nothing to skip", which is exactly
how this survived.

## The three that reproduced

**2 — throws landed in the void, and damaged through the map edge.**
`throwTarget` clamped each axis independently into `ArenaBorder .. MapWidth -
ArenaBorder`. That box is 28% larger than the hull, so an aim toward any of the
six corners resolved to a point outside the hexagon: unreachable ground, drawn
to the policy as a legal charge ring, and — because `explodeGrenade` has no
line-of-sight test on blast damage — still dealing damage back through the map
edge to anyone standing inside. Swept over every one of the 32 aim slots from a
60px grid of thrower positions, at full charge: **1316/6656 on `arena`
(19.8%), 2299/11520 on `arena-large`, 999/4896 on `gen small`, 9425/47520 on
`gen giant`** — up to 223px past the border ring. After the fix, **0 on all
four**.

The landing is now solved once, by `throwLanding`, against the real hull, and
`throwGrenade` calls the same proc the render's charge ring does — they used to
be two copies of the same arithmetic. A throw that would leave the field is
SHORTENED along the player's own aim rather than projected sideways: the legal
set is an intersection of half-planes and therefore convex, and the thrower
stands inside it, so marching `t` down from full strength crosses the boundary
exactly once. That makes the result exact rather than a bisection artifact, and
it mirrors cleanly.

**3 — a 60° wall stops a pulsing policy dead, and continuous input hides it.**
`slideScanRadius` floored at 1, which is a 45° diagonal — exactly what the
rectangular board's walls were. A hex hull edge meets the x axis at 60°, so
advancing 1px along it costs tan(60) = 1.73px perpendicular, and a radius of 1
cannot take the step: `applyMomentumAxis` sets `carry = 0` and the mover stops.

The first measurement **missed this**, and the miss is worth recording. Driven
with `right` held continuously, travel along a 60° face is *identical* to flat
floor (dx=71 in 30 ticks, both), because the scan widens with speed and the
acceleration curve leaves the radius-1 regime in two ticks. The bug lives at
LOW speed — and a policy that PULSES its d-pad, a common shape, never leaves
it:

| input duty | flat floor | 45° face | 60° face |
|---|---|---|---|
| 1-in-2 | 30px | 30px | **1px** |
| 1-in-3 | 15px | 15px | **1px** |
| 1-in-4 | 10px | 10px | **1px** |
| 1-in-6 | 5px | 5px | **1px** |

A 30x collapse, on exactly the geometry the hexagon introduced. With the scan
floored at 2 (`MovementSlideMinScan`) all three columns agree at every duty
cycle. Both regimes are pinned in `tests/test_hex_safety.nim`, including the
continuous-input case — because a test that only exercised continuous input
would have gone green on the broken build.

**5 — every player had a 15.5% longer throw and a louder shout.** The one the
ship gate found and deliberately held back (`maxwell/hex-grenade-axis-fix`)
because it desyncs fixtures. `selectCtfMap` assigned `MapWidth div 5`,
inherited verbatim from the rectangular board where width WAS the short axis;
after the landscape flip that is the point-to-point diagonal. `sim_types.nim`
declares both as `MapHeight div 5` and spends seven lines explaining that
reading `MapWidth` "would have handed every player a 15.5% longer throw and a
15.5% louder shout as an accidental side effect of a rendering decision" — and
the runtime then did precisely that. Landed here with the GV41 event and the
fixture re-record that the other two changes force anyway.

## The three that did not

These were all **holding by a property of some other component**, with nothing
asserting the dependency. That is the same shape as a bug: the next change to
the other component breaks them silently.

**1 — grenade pickups are reachable.** Already fixed on this branch:
`grenadeSpawnPoints` derives four of the hull's six vertices with no
trigonometry, and `walkableGrenadePoints` shrinks the whole ring — rather than
nudging each point — until all four land on floor. Measured over 12 boards
(both hand-authored arenas, five generated seeds, four size classes, the
4-team hex): every spawn walkable, every spawn reachable, **0 untouchable**.

One residual worth naming: the ring-shrink loop tests `isWalkable`, a single
PIXEL, while a pickup fires only when a player's CENTRE gets within
`GrenadePickupRange`, which needs a whole footprint. On 6 of 12 boards a spawn
sits where the footprint does not fit, and is taken by standing beside it. That
works — 12px of touch range against a 6px half-extent leaves room — but it is
slack, not a guarantee. The test asserts the property that matters
(*touchable from some occupiable cell*), so if the margin ever closes it goes
red instead of the pickup silently becoming unobtainable.

**4 — respawns do not drift.** `randomEndzonePosition` rejects on
`inCaptureZone` only, then runs the accepted point through `nearestWalkable`,
whose Chebyshev ring search can in principle walk it back out of the zone.
Measured 1600 draws over 8 boards: **0 escapes, 0 non-occupiable**. The reason
is that every endzone disc is *protected floor* — `isProtectedFloor` refuses to
carve wall there — so `nearestWalkable` is a no-op and there is nothing to
drift. That is a property of the map generator, not of this proc. Left
unchanged (adding a walkability term to the rejection loop would consume RNG
draws and change the sim for no measured benefit) and pinned with two tests:
the draws stay in the zone, AND the zones are wholly walkable — the second
names the premise, so a generator change that carves into an endzone goes red
with the reason rather than through this proc.

**6 — the fog does not leak through the hull.** `buildFovBlocked` downsamples
8×8 px to one occlusion cell on `walls * 2 >= pixels`, so a cell that is 30–49%
wall is transparent, and a staircased 60° edge is exactly the thing that
produces such cells. Measured over 7 boards up to the giant class: **0
transparent cells among 74,000+ fully-void cells**, and a viewer walked along
the inside of a slanted edge saw **0 cells with no playfield pixel**.

It holds because the void is WALL, so a cell wholly outside the hull is 100%
wall and opaque by construction — a proof, not a sample. That premise was
load-bearing in three places and asserted in none, so it is asserted now:

* the map bake raises `CtfError` naming the pixel and its edge distance if any
  floor pixel survives inside the border ring or outside the hull;
* `arena.nim`'s connectivity BFS steps `-1/+1` across a flat index and carried
  a *comment* saying row wrap "can't happen: the border ring is wall, so
  `open[]` is false along every edge" — it checks its four board edges now, at
  the cost of one pass over the border rather than the board.

Left alone deliberately: `fovVisibleAt` returns `true` on an invalid cache.
That is a fail-OPEN default for viewers with no eyes yet, changing it moves
broadcast output, and it is not reachable from the leak this item describes.

## 7 — the marker states the BOX, and now says so

`game teams <n> map <W>x<H>` was documented as "the exact map size in map
pixels". On a rectangle that was both the coordinate space and the playable
extent; the hexagon split them and the marker kept the box. **That is the right
choice** — it is the space every wire coordinate lives in, so `0 <= x < W`
still bounds every object — but it has to be said, because the walkability
sprite is the only channel carrying the true shape, and it does so correctly.

Standard class: box 1119×969 (1,084,311 px), playfield 779,019 px (**71.8%**),
playable extent **1095×949**. Stated in `labels.nim`, `docs/PROTOCOL.md` and
`docs/RULES.md`, all three of which read false before. `docs/RULES.md` also
still quoted the deleted 1235×659 rectangle as the map size and as the
walkability sprite's dimensions.

## Version and fixtures

Items 2, 3 and 5 are RULES CHANGES: they alter what a bot hears, where a
grenade lands, and how a body moves, so recorded fixtures desync. That forces
the version event the ship gate already flagged as blocker B — `GameVersion`
read `"38"` for the hex arena while main had since shipped GV38, GV39 and GV40,
two incompatible contracts under one string that the version check cannot catch
because the string never moved. Bumped to **`"41"`**, the first value free on
both lines, and the five recordable fixtures are re-recorded against it.

## What this sweep did NOT settle

* The 4-team boot crash (ship gate blocker A) and the rebase onto main
  (blocker B's other half) are untouched — both need an integration decision,
  not a sim fix.
* `explodeGrenade` still has no line-of-sight test on blast damage. Item 2
  removes the void-lob that made it exploitable through the map EDGE, but a
  grenade landing on the far side of an interior wall still damages through it.
  That is pre-existing, deliberate (grenades fly over obstacles), and out of
  scope here — flagged because item 2's write-up is the only place it is
  recorded.
* Items 4 and 7 have assertions but no negative control: 4's would require
  carving wall into an endzone, and 7's is a contract rather than a behaviour.
  The other five were each verified by reverting the fix and confirming the
  suite goes red — 12 tests across items 2, 3 and 5, 6 tests for item 1, and a
  boot-time raise for item 6.
