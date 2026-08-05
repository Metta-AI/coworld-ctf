## LANES, CHOKEPOINTS, AND THE LENGTH-AWARE CORRIDOR RULE.
##
## The single most load-bearing competitive property of a CTF map is that
## every base pair is joined by at least three VERTEX-DISJOINT routes of
## DIFFERENT character. `k = 1` — one route between the bases — is a fatal
## map: the whole game becomes one queue. `src/ctf/map_metrics.nim` already
## MEASURES that number (unit-capacity max-flow over a cell-split graph); this
## module is the generator side, plus the one rule the validator is missing.
##
## ---------------------------------------------------------------------------
## THE DESIGN CONFLICT THIS MODULE EXISTS TO RESOLVE
## ---------------------------------------------------------------------------
##
## `map_rules.RecommendedCorridorWidthPx` is 68 px — two DRAWN cog bodies
## (`SoldierBodyPx` = 34) abreast. A deliberate CHOKEPOINT is 30-45 px — one
## cog at a time, a doorway you fight over. Under a single global minimum
## these contradict: a 68 px floor rejects exactly the feature a map needs
## most, and dropping the floor to 45 throws away the two-abreast property
## (no overtaking, no escorting, no trading) that motivated 68 in the first
## place.
##
## They are TWO DIFFERENT CONCEPTS and the validator today has only one:
##
##   CORRIDOR minimum — the SUSTAINED width of a traversal route.  68 px.
##   CHOKEPOINT       — a deliberate, LOCAL, SHORT pinch.          30-45 px.
##
## The distinguishing variable is not width, it is LENGTH. So the rule is
## made LENGTH-AWARE: a sub-corridor-width section is legal exactly as long as
## its ARC LENGTH — the distance a player actually travels while inside it —
## stays under `maxPinchRunPx`, which is DERIVED below. Everywhere else the
## 68 px floor applies untouched.
##
## ---------------------------------------------------------------------------
## DERIVING THE MAXIMUM PINCH LENGTH
## ---------------------------------------------------------------------------
##
## A chokepoint you cannot clear before dying is not a chokepoint, it is a
## KILL BOX. So the bound is: the run a player can traverse inside the time a
## pre-aimed defender needs to kill them.
##
## `map_rules` already derives that length for OPEN ground:
##
##     ShotsToKill     = HitPoints * 100 / FieldAccuracyPct = 3*100/55 = 5
##     TicksToKill     = (5 - 1) * FireCooldownTicks        = 48 ticks
##     MaxExposedRunPx = 48 * MaxSpeed / MotionScale        = 132 px
##
## That uses the FIELD accuracy of 55%, which is measured on players who are
## DODGING. Inside a pinch they cannot. A shot's acceptance corridor is
## +-(PlayerHalf + BulletHalfWidth), so `StrafeWindowPx` = 28 px of lateral
## displacement turns a locked-in hit into a miss — and a 30 px pinch leaves a
## 34 px body NO lateral room at all. With no dodge the shooter gets the
## nominal 80% (`AimJitterCentralZ` = Phi^-1(0.90): 80% of the aim jitter lies
## inside a fully visible body at max range), and the same three lines give
##
##     ShotsToKill  = 3 * 100 / 80              = 3 shots
##     TicksToKill  = (3 - 1) * 12              = 24 ticks
##     LethalRunPx  = 24 * 704 / 256            = 66 px
##
## **66 px is the maximum pinch length at the 30-45 px chokepoint width.**
##
## Two independent checks that this is the right number:
##   - It is the bottom of the brief's stated lethal-exposure window (TTK
##     1.0-1.9 s at 66 px/s gives 66-125 px). The undodgeable end of that
##     window is exactly where an undodgeable pinch should sit.
##   - 66 px is under two drawn body lengths. A 30-45 px wide, 66 px deep
##     opening reads on screen as a DOORWAY — about one body wide and two
##     bodies deep, cleared in 24 ticks. That is a threshold you fight over.
##     A 300 px version of the same width is a tunnel, and a tunnel held by
##     one defender is a queue.
##
## THE ALLOWANCE IS GRADED, NOT A STEP. Dodge room recovers linearly between
## a body width and a body width plus a full strafe window, so
## `dodgeAccuracyPct` interpolates 80% -> 55% over that span and
## `maxPinchRunPx` follows:
##
##     width 30 px (no dodge room)          ->  66 px
##     width 45 px (11 px of room)          ->  99 px
##     width 62-67 px (a full strafe window)-> 132 px
##
## and at 68 px the pinch rule stops applying and `maxExposedRunPx` — which is
## 132 px — takes over as the cover-spacing rule. The two rules MEET at the
## same value, so there is no cliff at the corridor floor: the schedule is
## continuous by construction, which is the test that it was derived rather
## than tuned.
##
## ---------------------------------------------------------------------------
## HOW A PINCH IS FOUND — AND THE TWO FAILURES THIS AVOIDS
## ---------------------------------------------------------------------------
##
## Chokepoint detection has failed twice in this codebase, in opposite
## directions, and both failures are designed against here:
##
##   CONFETTI. Unfiltered distance-transform local minima flag every notch
##     between two pebbles. Togelius's documented fix is to keep only genuine
##     CUT vertices — narrow floor you must actually walk through.
##   ZERO. The harness author's medial-axis local-minimum filter was so
##     aggressive it returned 0 chokepoints for EVERY map, control included:
##     the cell holding a doorway records its WIDEST interior pixel while the
##     cells at the doorway's shoulders record floor pinched against the wall,
##     so the doorway is never the local minimum.
##
## So the ridge heuristic is gone entirely and THE CUT TEST IS THE ONLY
## FILTER. Candidates are simply the connected components of sub-corridor-
## width walkable floor — which IS the distance transform's low band, with the
## component's own minimum standing in for the medial-axis minimum, no
## skeleton required. Everything before the cut test exists only to bound
## cost: an on-route filter (a mandatory pinch must lie on a near-shortest
## base-to-base path) and a narrowest-first cap.
##
## The engine's own protected spawn pocket is EXCLUDED, for the reason
## `map_metrics` documents: its mouth is a genuine cut on every board ever
## generated, it is carved identically on all of them, and no map author
## controls it. A detector that reports it is measuring the engine.
##
## PURITY. This module imports `sim_types`, `map_rules` and `burrow` and
## NOTHING ELSE — deliberately not `arena`, so that `arena.collectMapDiagnostics`
## can adopt `corridorPinchFailures` with a one-line call without creating an
## import cycle. See `docs` in `laneApi` below for that exact line.

import std/[algorithm, math, strutils]
import sim_types
import map_rules

# ---------------------------------------------------------------------------
# Constants this module must agree with, and cannot import
# ---------------------------------------------------------------------------

const
  EngineMinCorridorPx* = 26
    ## Must equal `arena.MinCorridorWidth`, the narrowest corridor the 13 px
    ## solid player footprint can use and the width the validator's own
    ## erosion is calibrated to. `arena` would import THIS module, so the
    ## dependency cannot point the other way; `tests/test_map_lanes.nim` pins
    ## the two together, the same guard `map_rules.BorderPx` uses for
    ## `arena.ArenaBorder`.

  ChokeWidthMinPx* = 30
    ## Tight, but never impassable: clears the 26 px engine minimum by 4 px so
    ## a chokepoint is a doorway rather than a wall the validator happens to
    ## let through.
  ChokeWidthMaxPx* = 45
    ## Above this a pinch stops reading as a doorway. Chosen so one body
    ## (34 px) passes with room to spare but two never do.

  PinchAccuracyPct* = 80
    ## Shooter accuracy against a target with NO dodge room: the nominal
    ## `AimJitterCentralZ` figure for a fully visible body at max range. The
    ## counterpart to `map_rules.FieldAccuracyPct` = 55, which is measured on
    ## players who are dodging. These are the two ends of `dodgeAccuracyPct`.

  PinchCandidateCap* = 24
    ## Ceiling on how many pinched components get the (linear) cut test, taken
    ## narrowest-first among those already on a near-shortest route. Bounds a
    ## giant board's cost without changing the answer on any board small
    ## enough to test exhaustively.
  PinchMinPixels* = 16
    ## A pinched blob smaller than this is rasterization noise at a wall
    ## corner, not a section of route.
  IsovistStridePx* = EngineMinCorridorPx
    ## Vantage-point sampling stride for the "one camper watches every
    ## chokepoint" test. One corridor width apart: finer buys nothing, because
    ## two vantages inside one corridor see the same thing.
  LosStridePx* = 3
    ## Line-of-sight sampling stride, finer than the thinnest wall feature
    ## (12 px). Same rule `map_metrics.losClear` samples by; duplicated rather
    ## than imported because `map_metrics` imports `arena` and this module
    ## must not (see PURITY above).

# ---------------------------------------------------------------------------
# The derivation, as code
# ---------------------------------------------------------------------------

func shotsToKillAt*(accuracyPct: int): int {.inline.} =
  ## Shots a shooter must FIRE to land `HitPoints` of them at this hit rate.
  ## Identical form to `map_rules.ShotsToKill`, which is this at
  ## `FieldAccuracyPct`.
  HitPoints * 100 div max(1, accuracyPct)

func lethalRunPx*(accuracyPct: int): int {.inline.} =
  ## How far a player travels while a pre-aimed shooter kills them at this hit
  ## rate. `map_rules.MaxExposedRunPx` is this at `FieldAccuracyPct` (132 px).
  max(0, shotsToKillAt(accuracyPct) - 1) * FireCooldownTicks *
    SpeedPxPerTickNum div SpeedPxPerTickDen

func dodgeAccuracyPct*(widthPx: int): int =
  ## The hit rate a shooter gets against a player confined to floor `widthPx`
  ## wide. A body is `SoldierBodyPx` across, so lateral room is
  ## `widthPx - SoldierBodyPx`; `StrafeWindowPx` of it turns a locked-in hit
  ## into a miss, which is what the measured field rate already reflects. With
  ## none of it, the shooter gets the nominal figure.
  let
    room = max(0, widthPx - SoldierBodyPx)
    frac = min(1.0, float(room) / float(max(1, StrafeWindowPx)))
  int(round(float(PinchAccuracyPct) +
    (float(FieldAccuracyPct) - float(PinchAccuracyPct)) * frac))

func maxPinchRunPx*(widthPx: int): int {.inline.} =
  ## THE RULE. The longest arc length a section of floor `widthPx` wide may
  ## run before it stops being a chokepoint and becomes a kill box.
  ##
  ##   30 px -> 66 px    45 px -> 99 px    62+ px -> 132 px
  ##
  ## At and above `RecommendedCorridorWidthPx` this equals
  ## `map_rules.MaxExposedRunPx`, where the cover-spacing rule takes over — so
  ## the schedule is continuous across the corridor floor.
  lethalRunPx(dodgeAccuracyPct(widthPx))

# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------

type
  PinchRun* = object
    ## One connected section of sub-corridor-width walkable floor.
    x*, y*: int             ## centroid, in map px
    minWidthPx*: int        ## the tightest point in it (the medial minimum)
    arcLenPx*: int          ## how far a player TRAVELS while inside it
    allowedPx*: int         ## `maxPinchRunPx(minWidthPx)`
    pixels*: int
    onRoute*: bool          ## lies on a near-shortest base-to-base path
    mandatory*: bool        ## removing it disconnects a base pair: a CUT
    tested*: bool           ## the cut test was actually run on it

  PinchAudit* = object
    ## The length-aware corridor/chokepoint verdict for one map.
    ok*: bool
    reason*: string         ## first failure, "" when ok
    corridorMinPx*: int
    runs*: seq[PinchRun]        ## every pinched section, worst-excess first
    chokepoints*: seq[PinchRun] ## the subset that are genuine CUTS
    worstExcessPx*: int         ## how far the worst offender overruns

  IsovistVerdict* = object
    ## Whether one vantage point can watch every chokepoint at once.
    covered*: bool
    x*, y*: int             ## where that vantage is, when `covered`
    rangePx*: int

  CollisionFrontier* = object
    ## Where the fight will actually happen: the equidistant frontier of a
    ## multi-source BFS from all N bases.
    x*, y*: int             ## the frontier point the race reaches FIRST
    pixels*: int
    components*: int        ## distinct frontier lobes = distinct contact routes
    coverFrac*: float       ## wall fraction in a gun-range-quarter disc there
    mapCoverFrac*: float    ## the same measure over the whole board
    coverRatio*: float      ## coverFrac / mapCoverFrac
    routeCells*: int        ## walkable cells on the frontier, a route proxy
    ok*: bool
    reason*: string

func excessPx*(run: PinchRun): int {.inline.} =
  ## How far past its allowance this section runs. Negative is slack.
  run.arcLenPx - run.allowedPx

func isChokepoint*(run: PinchRun): bool {.inline.} =
  ## A genuine chokepoint: a mandatory cut, narrow enough to read as a
  ## doorway, and short enough to clear alive.
  run.mandatory and run.arcLenPx <= run.allowedPx

func inDesignBand*(run: PinchRun): bool {.inline.} =
  ## Whether the pinch sits in the 30-45 px band this generator aims for.
  run.minWidthPx >= ChokeWidthMinPx and run.minWidthPx <= ChokeWidthMaxPx

# ---------------------------------------------------------------------------
# Masks: clearance, walkable floor, geodesic distance
# ---------------------------------------------------------------------------

proc clearancePx*(wall: seq[bool], w, h: int): seq[int32] =
  ## Chamfer 3-4 distance to the nearest wall pixel, divided back to px. The
  ## SAME kernel `arena.collectMapDiagnostics` and `map_metrics` run, so a
  ## width measured here is the width they measure.
  ##
  ## Floor of width W has clearance ~W/2 at its medial axis, so the local
  ## width this module reports is `2 * clearancePx`.
  let n = w * h
  var dist = newSeq[int32](n)
  for i in 0 ..< n:
    dist[i] = if wall[i]: 0'i32 else: int32.high div 2
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      if dist[i] == 0: continue
      var d = dist[i]
      if x > 0: d = min(d, dist[i - 1] + 3)
      if y > 0: d = min(d, dist[i - w] + 3)
      if x > 0 and y > 0: d = min(d, dist[i - w - 1] + 4)
      if x < w - 1 and y > 0: d = min(d, dist[i - w + 1] + 4)
      dist[i] = d
  for y in countdown(h - 1, 0):
    for x in countdown(w - 1, 0):
      let i = y * w + x
      if dist[i] == 0: continue
      var d = dist[i]
      if x < w - 1: d = min(d, dist[i + 1] + 3)
      if y < h - 1: d = min(d, dist[i + w] + 3)
      if x < w - 1 and y < h - 1: d = min(d, dist[i + w + 1] + 4)
      if x > 0 and y < h - 1: d = min(d, dist[i + w - 1] + 4)
      dist[i] = d
  result = newSeq[int32](n)
  for i in 0 ..< n:
    result[i] = dist[i] div 3

func widthAt*(clear: seq[int32], i: int): int {.inline.} =
  ## Local floor width at a pixel: twice its clearance.
  2 * int(clear[i])

proc walkableMask*(clear: seq[int32], w, h: int): seq[bool] =
  ## Floor the player footprint can actually use — `arena`'s own erosion,
  ## expressed as a width: at least `EngineMinCorridorPx` across.
  result = newSeq[bool](w * h)
  for i in 0 ..< w * h:
    result[i] = 2 * int(clear[i]) >= EngineMinCorridorPx

proc nearestWalkable*(walk: seq[bool], w, h, px, py: int): int =
  ## The walkable pixel nearest a map point, or -1. A base sits on protected
  ## floor and is normally walkable outright, but a spiral keeps the caller
  ## from having to care.
  if px < 0 or py < 0 or px >= w or py >= h: return -1
  if walk[py * w + px]: return py * w + px
  for radius in 1 .. 64:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        if max(abs(dx), abs(dy)) != radius: continue
        let
          x = px + dx
          y = py + dy
        if x < 0 or y < 0 or x >= w or y >= h: continue
        if walk[y * w + x]: return y * w + x
  -1

proc geodesic*(walk: seq[bool], w, h: int, starts: openArray[int]): seq[int32] =
  ## 4-connected BFS distance in px over walkable floor; -1 where unreachable.
  ## Multi-source when several starts are given, which is what makes the
  ## collision frontier a single pass.
  let n = w * h
  result = newSeq[int32](n)
  for i in 0 ..< n: result[i] = -1
  var queue = newSeqOfCap[int32](n div 4)
  for s in starts:
    if s < 0 or s >= n or not walk[s] or result[s] >= 0: continue
    result[s] = 0
    queue.add int32(s)
  var head = 0
  while head < queue.len:
    let i = int(queue[head])
    inc head
    let
      x = i mod w
      d = result[i] + 1
    if x > 0 and walk[i - 1] and result[i - 1] < 0:
      result[i - 1] = d; queue.add int32(i - 1)
    if x < w - 1 and walk[i + 1] and result[i + 1] < 0:
      result[i + 1] = d; queue.add int32(i + 1)
    if i >= w and walk[i - w] and result[i - w] < 0:
      result[i - w] = d; queue.add int32(i - w)
    if i + w < n and walk[i + w] and result[i + w] < 0:
      result[i + w] = d; queue.add int32(i + w)

proc losClear*(wall: seq[bool], w, h, x0, y0, x1, y1: int): bool =
  ## True when the open segment between two pixels crosses no wall. Both
  ## endpoints excluded so a vantage standing against cover still sees out.
  let
    dx = x1 - x0
    dy = y1 - y0
    span = max(abs(dx), abs(dy))
  if span == 0: return true
  let steps = max(1, span div LosStridePx)
  for i in 1 ..< steps:
    let
      x = x0 + dx * i div steps
      y = y0 + dy * i div steps
    if x < 0 or y < 0 or x >= w or y >= h: return false
    if wall[y * w + x]: return false
  true

# ---------------------------------------------------------------------------
# THE AUDIT
# ---------------------------------------------------------------------------

proc auditCorridorPinches*(
  wall: seq[bool], w, h: int, anchors: openArray[MapPoint],
  corridorMinPx = RecommendedCorridorWidthPx,
): PinchAudit =
  ## THE length-aware corridor/chokepoint measurement, and the only filter
  ## worth trusting for either question.
  ##
  ## Finds every connected section of walkable floor narrower than
  ## `corridorMinPx`, measures how far a player TRAVELS while inside it (its
  ## arc length along the geodesic from the first base), and compares that
  ## against `maxPinchRunPx` at the section's own tightest width. Sections
  ## that overrun are corridor-floor violations; sections that fit AND are
  ## genuine cuts are chokepoints.
  ##
  ## `anchors` are the team flag homes. Two or more are needed for the cut
  ## test and for the spawn-pocket exclusion; with fewer, only the geometric
  ## measurements are populated and nothing is ever reported as mandatory.
  result.corridorMinPx = corridorMinPx
  result.ok = true
  let n = w * h
  if n <= 0 or wall.len < n: return

  let
    clear = clearancePx(wall, w, h)
    walk = walkableMask(clear, w, h)

  var anchorPx: seq[int]
  for a in anchors:
    let i = nearestWalkable(walk, w, h, a.x, a.y)
    if i >= 0: anchorPx.add i
  if anchorPx.len == 0: return

  # Geodesic fields, one per base. `dist[0]` doubles as the ARC-LENGTH ruler:
  # `max - min` of it over a section is exactly how far you travel inside it.
  var dist: seq[seq[int32]]
  for a in anchorPx: dist.add geodesic(walk, w, h, [a])

  # The engine's protected spawn pocket and its approach — the first fifth of
  # the walk to the nearest other base. Its mouth is a genuine cut on EVERY
  # board, carved identically on all of them, and no map author controls it.
  # `map_metrics` excludes it from both the route metric and the chokepoint
  # detector for this reason and so does this audit.
  var nearBase = newSeq[bool](n)
  for a in 0 ..< anchorPx.len:
    var span = -1
    for b in 0 ..< anchorPx.len:
      if b == a: continue
      let d = int(dist[a][anchorPx[b]])
      if d >= 0 and (span < 0 or d < span): span = d
    if span < 5 * EngineMinCorridorPx: continue
    let near = int32(span div 5)
    for i in 0 ..< n:
      if dist[a][i] >= 0 and dist[a][i] <= near: nearBase[i] = true

  # --- pinched components -------------------------------------------------
  var pinched = newSeq[bool](n)
  for i in 0 ..< n:
    pinched[i] = walk[i] and not nearBase[i] and 2 * int(clear[i]) < corridorMinPx

  var
    seen = newSeq[bool](n)
    stack: seq[int32]
    comps: seq[seq[int32]]
  for start in 0 ..< n:
    if seen[start] or not pinched[start]: continue
    stack.setLen(0)
    stack.add int32(start)
    seen[start] = true
    var members: seq[int32]
    while stack.len > 0:
      let i = int(stack.pop())
      members.add int32(i)
      let x = i mod w
      if x > 0 and pinched[i - 1] and not seen[i - 1]:
        seen[i - 1] = true; stack.add int32(i - 1)
      if x < w - 1 and pinched[i + 1] and not seen[i + 1]:
        seen[i + 1] = true; stack.add int32(i + 1)
      if i >= w and pinched[i - w] and not seen[i - w]:
        seen[i - w] = true; stack.add int32(i - w)
      if i + w < n and pinched[i + w] and not seen[i + w]:
        seen[i + w] = true; stack.add int32(i + w)
    if members.len >= PinchMinPixels:
      comps.add members

  # --- measure each ------------------------------------------------------
  # A mandatory pinch must lie on a near-shortest base-to-base path (if you
  # can route around it at similar cost, it is not a cut). That is a cheap
  # NECESSARY condition, and it is what keeps the cut test off the confetti.
  let slack = int32(2 * corridorMinPx)
  var runs: seq[PinchRun]
  var members: seq[seq[int32]]
  for c in comps:
    var
      run = PinchRun(minWidthPx: high(int), arcLenPx: 0, pixels: c.len)
      sx, sy = 0
      dLo = int32.high
      dHi = int32.low
    for m in c:
      let i = int(m)
      run.minWidthPx = min(run.minWidthPx, 2 * int(clear[i]))
      sx += i mod w
      sy += i div w
      let d = dist[0][i]
      if d >= 0:
        dLo = min(dLo, d)
        dHi = max(dHi, d)
    run.x = sx div c.len
    run.y = sy div c.len
    if dHi >= dLo: run.arcLenPx = int(dHi - dLo)
    run.allowedPx = maxPinchRunPx(run.minWidthPx)
    for a in 0 ..< anchorPx.len:
      for b in a + 1 ..< anchorPx.len:
        let span = dist[a][anchorPx[b]]
        if span < 0: continue
        for m in c:
          let i = int(m)
          if dist[a][i] < 0 or dist[b][i] < 0: continue
          if dist[a][i] + dist[b][i] <= span + slack:
            run.onRoute = true
            break
        if run.onRoute: break
      if run.onRoute: break
    runs.add run
    members.add c

  # --- the cut test: THE ONLY FILTER -------------------------------------
  # Narrowest first, capped. Everything above is cost control; this is what
  # decides whether a pinch is a chokepoint.
  var order: seq[int]
  for i in 0 ..< runs.len:
    if runs[i].onRoute: order.add i
  order.sort(proc (a, b: int): int = cmp(runs[a].minWidthPx, runs[b].minWidthPx))
  if order.len > PinchCandidateCap: order.setLen(PinchCandidateCap)

  if anchorPx.len >= 2:
    var blockedPx = newSeq[bool](n)
    for k in order:
      for m in members[k]: blockedPx[int(m)] = true
      var probe = newSeq[bool](n)
      for i in 0 ..< n: probe[i] = walk[i] and not blockedPx[i]
      var isCut = false
      if probe[anchorPx[0]]:
        let d = geodesic(probe, w, h, [anchorPx[0]])
        for b in 1 ..< anchorPx.len:
          if dist[0][anchorPx[b]] >= 0 and d[anchorPx[b]] < 0:
            isCut = true
            break
      else:
        isCut = true
      runs[k].mandatory = isCut
      runs[k].tested = true
      for m in members[k]: blockedPx[int(m)] = false

  # --- verdict ------------------------------------------------------------
  runs.sort(proc (a, b: PinchRun): int = cmp(b.excessPx, a.excessPx))
  result.runs = runs
  result.worstExcessPx = low(int)
  for r in runs:
    if r.mandatory: result.chokepoints.add r
    result.worstExcessPx = max(result.worstExcessPx, r.excessPx)
    if r.mandatory and r.arcLenPx > r.allowedPx and result.reason.len == 0:
      result.ok = false
      result.reason =
        "kill box at (" & $r.x & "," & $r.y & "): " & $r.minWidthPx &
          "px floor runs " & $r.arcLenPx & "px, over the " & $r.allowedPx &
          "px a player can clear alive at that width (corridor floor is " &
          $corridorMinPx & "px)"
  if runs.len == 0: result.worstExcessPx = 0

proc corridorPinchFailures*(
  wall: seq[bool], w, h: int, anchors: openArray[MapPoint],
  corridorMinPx = RecommendedCorridorWidthPx,
): seq[string] =
  ## THE ONE-LINE CALL the validator adopts. Empty when the map obeys the
  ## length-aware corridor rule; otherwise the reasons, worst first.
  ##
  ## Drop this into `arena.collectMapDiagnostics`, immediately after the
  ## `sightlines` block (while `maxWall` is still alive, before the
  ## `maxWall.setLen(0)` release):
  ##
  ##   for r in corridorPinchFailures(maxWall, w, h, gameMap.flagHomes()):
  ##     recordFailure(r)
  ##
  ## where `flagHomes` is `for t in gameMap.teams(): gameMap.flagHome(t)`.
  ## Nothing else changes: the 68 px floor now applies to SUSTAINED corridor,
  ## and a deliberate 30-45 px chokepoint under `maxPinchRunPx` long passes.
  let audit = auditCorridorPinches(wall, w, h, anchors, corridorMinPx)
  if not audit.ok: result.add audit.reason

# ---------------------------------------------------------------------------
# The isovist assertion
# ---------------------------------------------------------------------------

proc chokepointsCovered*(
  wall: seq[bool], w, h: int, chokes: openArray[PinchRun],
  rangePx = GunRange,
): IsovistVerdict =
  ## One vantage that watches every chokepoint is one camper who owns the map.
  ## Range-capped at gun range: beyond it, watching is not covering.
  ##
  ## The ASSERTION a generator wants is `not covered`.
  result.rangePx = rangePx
  if chokes.len <= 1:
    # A single forced doorway is trivially covered — by standing on it. That
    # is a k=1 map and a different failure; say so honestly rather than
    # passing it.
    result.covered = chokes.len == 1
    if chokes.len == 1:
      result.x = chokes[0].x
      result.y = chokes[0].y
    return
  let r2 = rangePx * rangePx
  var y = 0
  while y < h:
    var x = 0
    while x < w:
      if not wall[y * w + x]:
        var all = true
        for c in chokes:
          let
            dx = c.x - x
            dy = c.y - y
          if dx * dx + dy * dy > r2 or not losClear(wall, w, h, x, y, c.x, c.y):
            all = false
            break
        if all:
          result.covered = true
          result.x = x
          result.y = y
          return
      x += IsovistStridePx
    y += IsovistStridePx

# ---------------------------------------------------------------------------
# The collision point
# ---------------------------------------------------------------------------

proc collisionFrontier*(
  wall: seq[bool], w, h: int, anchors: openArray[MapPoint],
): CollisionFrontier =
  ## Where the fight will actually happen: the equidistant frontier of a
  ## multi-source BFS from all N bases — the cells the two nearest bases
  ## reach at the same time.
  ##
  ## The documented failure this catches is a map whose collision point lands
  ## in a cover-free area: that map plays as a sprint into a shooting gallery
  ## no matter what else it has. So the frontier must carry MORE cover and
  ## MORE route than the board average, and `ok` asserts exactly that.
  let n = w * h
  result.reason = ""
  if n <= 0 or wall.len < n or anchors.len < 2:
    result.reason = "need two or more bases"
    return
  let
    clear = clearancePx(wall, w, h)
    walk = walkableMask(clear, w, h)
  var anchorPx: seq[int]
  for a in anchors:
    let i = nearestWalkable(walk, w, h, a.x, a.y)
    if i >= 0: anchorPx.add i
  if anchorPx.len < 2:
    result.reason = "bases are not on walkable floor"
    return
  var dist: seq[seq[int32]]
  for a in anchorPx: dist.add geodesic(walk, w, h, [a])

  var
    frontier = newSeq[bool](n)
    bestD1 = high(int)
    picks: seq[int]
  for i in 0 ..< n:
    if not walk[i]: continue
    var d1, d2 = high(int)
    for t in 0 ..< dist.len:
      let d = int(dist[t][i])
      if d < 0: continue
      if d < d1: (d2, d1) = (d1, d)
      elif d < d2: d2 = d
    if d1 == high(int) or d2 == high(int): continue
    # Equidistant to within one corridor width: the frontier is a band, not a
    # razor, because two players arriving a body apart still collide.
    if d2 - d1 <= EngineMinCorridorPx:
      frontier[i] = true
      picks.add i
      if d1 < bestD1:
        bestD1 = d1
        result.x = i mod w
        result.y = i div w
  result.pixels = picks.len
  result.routeCells = picks.len div max(1, EngineMinCorridorPx * EngineMinCorridorPx)
  if picks.len == 0:
    result.reason = "no collision frontier: the bases do not race each other"
    return

  # Distinct frontier lobes = distinct ways the two sides can meet. One lobe
  # is one contact point and one queue.
  var fseen = newSeq[bool](n)
  var stack: seq[int32]
  for start in picks:
    if fseen[start]: continue
    inc result.components
    stack.setLen(0)
    stack.add int32(start)
    fseen[start] = true
    while stack.len > 0:
      let i = int(stack.pop())
      let x = i mod w
      if x > 0 and frontier[i - 1] and not fseen[i - 1]:
        fseen[i - 1] = true; stack.add int32(i - 1)
      if x < w - 1 and frontier[i + 1] and not fseen[i + 1]:
        fseen[i + 1] = true; stack.add int32(i + 1)
      if i >= w and frontier[i - w] and not fseen[i - w]:
        fseen[i - w] = true; stack.add int32(i - w)
      if i + w < n and frontier[i + w] and not fseen[i + w]:
        fseen[i + w] = true; stack.add int32(i + w)

  # Cover density AT the collision point vs the board's own average. The
  # radius is a quarter gun range: the ground a fight at the frontier is
  # actually contested over.
  let rad = GunRange div 4
  var near, nearWall, total, totalWall = 0
  for y in max(0, result.y - rad) .. min(h - 1, result.y + rad):
    for x in max(0, result.x - rad) .. min(w - 1, result.x + rad):
      let
        dx = x - result.x
        dy = y - result.y
      if dx * dx + dy * dy > rad * rad: continue
      inc near
      if wall[y * w + x]: inc nearWall
  for i in 0 ..< n:
    inc total
    if wall[i]: inc totalWall
  result.coverFrac = float(nearWall) / float(max(1, near))
  result.mapCoverFrac = float(totalWall) / float(max(1, total))
  result.coverRatio = result.coverFrac / max(1e-6, result.mapCoverFrac)
  result.ok = result.coverRatio >= 1.0 and result.components >= 2
  if not result.ok:
    result.reason =
      "collision point (" & $result.x & "," & $result.y & ") has cover ratio " &
        formatFloat(result.coverRatio, ffDecimal, 2) & " and " &
        $result.components & " frontier lobe(s); the fight lands in " &
        (if result.coverRatio < 1.0: "open ground" else: "a single queue")
