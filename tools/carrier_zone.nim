## carrier_zone — where a heart carrier stands relative to the zone it has to
## reach, for the offline map tools. Not part of the server.
##
## WHY THIS IS A MODULE AND NOT FIVE LINES INLINE. The five lines it replaces
## lived in tools/map_playtest.nim and reported 0 on EVERY episode ever
## measured — including the two that CAPTURED (`tests/fixtures/capture-seed1`
## and `gen-small-pits`, both 1 capture, both 1 capture verified inside the
## engine's own zone predicate, both `carrierInZoneTicks = 0`). A detector
## that returns 0 on a positive case cannot be told apart from a correct
## detector on an empty population by looking at its output, so it is here
## where `tests/test_carrier_zone.nim` can drive it against a PLANTED carrier
## whose answer is known in advance. `tests/test_map_eval.nim`'s `doorwayMap`
## is the same move for the chokepoint detector.
##
## The answer, once controlled: the population really is empty, and it is
## empty by construction rather than by accident — see `carriersInOwnZone`.
## `approachPx` is the measurement that replaces it.

import
  std/math,
  ../src/ctf/sim

proc carriersInOwnZone*(sim: SimServer, zones: openArray[CaptureZone]): int =
  ## Live carriers standing inside their OWN capture zone at this instant.
  ##
  ## STRUCTURALLY ZERO WHEN SAMPLED BETWEEN STEPS, and that is a fact about
  ## the engine, not a bug in here. `checkWinCondition` runs at the end of
  ## every `step()` and captures the instant this same predicate turns true
  ## for a live carrier — unconditionally, with no own-flag-must-be-home
  ## precondition (sim.nim's own comment says "deliberately") — then sets
  ## `flags[team].carrier = -1` in that same tick. `CollisionW`/`CollisionH`
  ## are 1, so the engine's `x + CollisionW div 2` is literally the point this
  ## tests. A dead carrier cannot linger either: `killPlayer` sends the heart
  ## home. So between two steps — the only vantage an offline replay tool
  ## has — the state this counts has already been consumed.
  ##
  ## Kept, rather than deleted, as a TRIPWIRE: if the engine ever grows a
  ## precondition on capture (own heart home, a channel timer, a contested
  ## zone), a carrier CAN then stand and wait, this goes non-zero, and the
  ## approach numbers below stop being the whole story. The test asserts both
  ## halves — that it fires on a planted carrier, and that it stays 0 across
  ## real episodes that captured.
  for team in sim.teams():
    let carrier = sim.flags[team].carrier
    if carrier < 0 or carrier >= sim.players.len: continue
    let holder = sim.players[carrier]
    if not holder.alive: continue
    if zones[ord(holder.team)].inCaptureZone(holder.x, holder.y):
      inc result

proc homeRaySpan*(x, y, anchorX, anchorY: int): int =
  ## Length in px of the straight run from a carrier to its own base anchor.
  let
    dx = anchorX - x
    dy = anchorY - y
  max(1, int(round(sqrt(float(dx * dx + dy * dy)))))

proc homeRayPoint*(x, y, anchorX, anchorY, step: int): tuple[x, y: int] =
  ## The point `step` px along that run. Exported so the test can check the
  ## boundary `approachPx` reports with the SAME arithmetic that found it —
  ## a test that re-derived the ray could agree with the map and still
  ## disagree with the code.
  let
    span = homeRaySpan(x, y, anchorX, anchorY)
    dx = float(anchorX - x)
    dy = float(anchorY - y)
    t = float(step) / float(span)
  (x + int(round(dx * t)), y + int(round(dy * t)))

proc approachPx*(zone: CaptureZone, x, y, anchorX, anchorY: int): int =
  ## Pixels a carrier at (x, y) still has to cover walking STRAIGHT AT its own
  ## base anchor before the engine's own capture predicate turns true. 0 once
  ## inside. -1 if the anchor is not itself inside the zone — an impossible
  ## zone, reported rather than quietly answered with a distance.
  ##
  ## This asks `inCaptureZone` rather than re-deriving the boundary from the
  ## zone fields, so a new endzone shape can never make this disagree with the
  ## engine about where the line is. It walks the segment a pixel at a time
  ## instead of bisecting: every zone shape is an axis box intersected with an
  ## L1 ball, an L2 disc, or nothing — all convex, all containing their
  ## anchor, so the segment crosses the boundary exactly once and the first
  ## hit IS the crossing, without having to argue that the integer rounding a
  ## bisection samples stays monotone.
  ##
  ## It is a distance ALONG THE HOME RAY, not to the nearest zone point: the
  ## question a map verdict asks is how much further the carrier had to run,
  ## and a carrier walks at its base, not at the closest corner of the paint.
  if zone.inCaptureZone(x, y): return 0
  if not zone.inCaptureZone(anchorX, anchorY): return -1
  let span = homeRaySpan(x, y, anchorX, anchorY)
  for step in 1 .. span:
    let p = homeRayPoint(x, y, anchorX, anchorY, step)
    if zone.inCaptureZone(p.x, p.y): return step
  span

proc carrierApproach*(
  sim: SimServer, zones: openArray[CaptureZone]
): int =
  ## The closest any live carrier stands to its own capture zone right now, in
  ## `approachPx`. -1 when nobody is carrying — the caller must not fold that
  ## into a minimum, or an episode with no carry at all would read as a
  ## carrier on the doorstep.
  result = -1
  for index, player in sim.players:
    if not player.alive or not player.carryingFlag: continue
    let
      anchor = sim.gameMap.teamAnchor(player.team)
      d = zones[ord(player.team)].approachPx(
        player.x, player.y, anchor.x, anchor.y)
    if d < 0: continue
    if result < 0 or d < result: result = d
