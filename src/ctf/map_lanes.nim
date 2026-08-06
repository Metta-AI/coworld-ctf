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

import std/[algorithm, math, random, strutils]
import sim_types
import map_rules
import burrow

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
  MaxRoutePasses* = 6
    ## How many independent routes the gate enumeration walks. One more than
    ## the largest lane count `map_rules` ever asks for (colossal drops back
    ## to 3; giant asks 6), so every designed lane gets a pass.
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
    exposedPx*: int
      ## The longest stretch of that travel a single defender can hold in one
      ## line of sight. THIS is what the rule gates on, not `arcLenPx`: a
      ## kill box needs the shooter to keep seeing you for the whole kill, so
      ## a passage that BENDS resets the clock at every corner however long it
      ## runs in total. See `auditCorridorPinches`.
    allowedPx*: int         ## `maxPinchRunPx(minWidthPx)`
    pixels*: int
    onRoute*: bool          ## lies on a near-shortest base-to-base path
    mandatory*: bool        ## sealing it costs a whole kill to route around
    tested*: bool           ## the cut test was actually run on it
    pass*: int              ## which independent route this gate belongs to;
                            ## 0 is the route a player actually takes

  PinchAudit* = object
    ## The length-aware corridor/chokepoint verdict for one map.
    ok*: bool
    reason*: string         ## first failure, "" when ok
    corridorMinPx*: int
    routeWidthPx*: int
      ## The widest sustained corridor the map delivers between the bases —
      ## the maximin bottleneck the rule was evaluated on. Read this FIRST
      ## when a map fails: a board whose route width is 26 px does not have a
      ## chokepoint problem, it has no corridors.
    routePasses*: int
      ## How many independent routes the search found before the board came
      ## apart. A cheap second opinion on `map_metrics.routeCountMin`.
    runs*: seq[PinchRun]        ## every pinched section, worst-excess first
    chokepoints*: seq[PinchRun] ## the subset that are genuine CUTS
    gates*: seq[PinchRun]
      ## Every gate, one or more per independent route. THIS is the list the
      ## isovist assertion runs on: on a map with three parallel doorways no
      ## single one is individually load-bearing, so `chokepoints` is empty
      ## while `gates` correctly holds all three.
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
  ## How far past its allowance this section's EXPOSED run goes. Negative is
  ## slack.
  run.exposedPx - run.allowedPx

func isChokepoint*(run: PinchRun): bool {.inline.} =
  ## A genuine chokepoint: a mandatory cut, narrow enough to read as a
  ## doorway, and short enough to clear alive.
  run.mandatory and run.exposedPx <= run.allowedPx

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

proc routeWidthPx*(
  wall: seq[bool], w, h: int, anchors: openArray[MapPoint]
): int =
  ## THE WIDEST SUSTAINED CORRIDOR the map actually delivers: the largest T
  ## such that some route joins every base while never narrowing below T px.
  ##
  ## This is the single number that says whether a 68 px corridor floor is a
  ## rule the map obeys or a rule it has never met, and it is the number to
  ## read FIRST when the pinch audit reports a violation — a map whose route
  ## width is 26 px does not have a chokepoint problem, it has no corridors.
  ##
  ## Computed as a widest-path / maximum-bottleneck join: add pixels in
  ## DESCENDING width order, union each into its already-added neighbours, and
  ## report the width at which the bases first land in one set. Exact, and one
  ## counting sort plus one union-find pass rather than a search over floods.
  ##
  ## The engine's spawn pocket is forced to the top bucket for the reason the
  ## audit excludes it: its mouth is the tightest cut on every board ever
  ## generated and no map author controls it.
  let n = w * h
  if n <= 0 or wall.len < n or anchors.len < 2: return 0
  let
    clear = clearancePx(wall, w, h)
    walk = walkableMask(clear, w, h)
  var anchorPx: seq[int]
  for a in anchors:
    let i = nearestWalkable(walk, w, h, a.x, a.y)
    if i >= 0: anchorPx.add i
  if anchorPx.len < 2: return 0

  var nearBase = newSeq[bool](n)
  for a in 0 ..< anchorPx.len:
    let field = geodesic(walk, w, h, [anchorPx[a]])
    var span = -1
    for b in 0 ..< anchorPx.len:
      if b == a: continue
      let d = int(field[anchorPx[b]])
      if d >= 0 and (span < 0 or d < span): span = d
    if span < 5 * EngineMinCorridorPx: continue
    let near = int32(span div 5)
    for i in 0 ..< n:
      if field[i] >= 0 and field[i] <= near: nearBase[i] = true

  var maxW = 0
  for i in 0 ..< n:
    if walk[i]: maxW = max(maxW, 2 * int(clear[i]))
  if maxW <= 0: return 0
  let top = maxW + 1

  var order = newSeq[seq[int32]](top + 1)
  for i in 0 ..< n:
    if not walk[i]: continue
    let wpx = if nearBase[i]: top else: min(top, 2 * int(clear[i]))
    order[wpx].add int32(i)

  var parent = newSeq[int32](n)
  var added = newSeq[bool](n)
  proc find(a: int): int =
    var r = a
    while int(parent[r]) != r: r = int(parent[r])
    var c = a
    while int(parent[c]) != c:
      let nxt = int(parent[c])
      parent[c] = int32(r)
      c = nxt
    r
  proc union(a, b: int) =
    let ra = find(a)
    let rb = find(b)
    if ra != rb: parent[ra] = int32(rb)

  for wpx in countdown(top, 0):
    for m in order[wpx]:
      let i = int(m)
      added[i] = true
      parent[i] = int32(i)
      let x = i mod w
      for step in [-1, 1, -w, w]:
        if step == -1 and x == 0: continue
        if step == 1 and x == w - 1: continue
        let j = i + step
        if j >= 0 and j < n and added[j]: union(i, j)
    var joined = true
    for b in 1 ..< anchorPx.len:
      if not added[anchorPx[0]] or not added[anchorPx[b]] or
          find(anchorPx[0]) != find(anchorPx[b]):
        joined = false
        break
    if joined: return min(wpx, maxW)
  0

proc longestExposedRunPx*(
  wall: seq[bool], w, h: int, path: openArray[int32]
): int =
  ## The longest sub-stretch of a route whose two ends see each other.
  ##
  ## The pinch rule bounds how long a player may be EXPOSED, and exposure is
  ## line of sight, not distance walked. A defender holding a doorway kills
  ## you only while they can still see you; step behind a corner and their
  ## clock resets. So a 188 px passage that bends twice is three ~60 px
  ## exposures, not one 188 px one, and gating on the walked length instead
  ## rejects every naturally winding route — it rejected the hand-authored
  ## arena, whose widest route runs 188 px of 36 px floor around a corner.
  ##
  ## Measured as the widest window [i, j] over the ordered path with clear
  ## line of sight between its ends. Windows are short (a pinch is by
  ## definition a local feature) and `losClear` is strided, so the quadratic
  ## is cheap and exact.
  if path.len == 0: return 0
  result = 1
  var i = 0
  while i < path.len:
    var j = i + result
    while j < path.len:
      let
        a = int(path[i])
        b = int(path[j])
      if not losClear(wall, w, h, a mod w, a div w, b mod w, b div w): break
      result = max(result, j - i + 1)
      inc j
    inc i

const LethalUnit* = 396
  ## One whole kill, in lethality units. `maxPinchRunPx` only ever returns
  ## 66, 99 or 132 (shots-to-kill is an integer), and 396 is their LCM — so
  ## a pixel of sub-corridor floor costs exactly `396 div maxPinchRunPx` and
  ## a run that accumulates 396 is a run you die in, with no rounding.

func pixelLethality*(widthPx, corridorMinPx: int): int {.inline.} =
  ## What one pixel of travel at this local width costs, as a fraction of a
  ## kill scaled by `LethalUnit`. Floor at or above the corridor minimum is
  ## FREE: two cogs abreast is the sustained-corridor property, and a player
  ## who has it can trade, escort and dodge, so it never accrues pinch debt.
  if widthPx >= corridorMinPx: 0
  else: LethalUnit div max(1, maxPinchRunPx(widthPx))

proc auditCorridorPinches*(
  wall: seq[bool], w, h: int, anchors: openArray[MapPoint],
  corridorMinPx = RecommendedCorridorWidthPx,
): PinchAudit =
  ## THE length-aware corridor/chokepoint measurement.
  ##
  ## ------------------------------------------------------------------------
  ## WHY THIS IS A ROUTING PROBLEM AND NOT A SHAPE PROBLEM
  ## ------------------------------------------------------------------------
  ##
  ## The first version of this audit took connected components of sub-68px
  ## walkable floor and measured each one's arc length. It FLAGGED THE
  ## CONTROL: the hand-authored arena came back as a single 26px-wide "kill
  ## box" 1175 px long, spanning the whole board.
  ##
  ## That verdict was nonsense and the reason is worth keeping. In any
  ## open-plan map, thin floor is not a set of separate necks — it is a WEB.
  ## The arena's passages run between pickets, so the pinched skirt around
  ## every picket touches the pinched skirt around the next one, and all of
  ## them 4-connect into one component that spans the map. Its "arc length"
  ## is the map's diameter, and it means nothing, because at every point on
  ## that web a player can take one step sideways into a 200 px opening.
  ##
  ## Being IN narrow floor is not the hazard. Being UNABLE TO AVOID IT is.
  ## So the question is about ROUTES, not regions:
  ##
  ##   over all routes from base A to base B, what is the least pinch debt a
  ##   player can pay, and does any single unavoidable stretch of it exceed
  ##   what they can clear alive?
  ##
  ## That is a shortest-path problem with `pixelLethality` as the edge cost —
  ## zero on corridor-width floor, `LethalUnit / maxPinchRunPx(width)` on
  ## anything narrower. Costs are the small integers {0, 3, 4, 6}, so it runs
  ## on a bucket queue: Dial's algorithm, the same engine `burrow` uses to
  ## dig, now used to measure.
  ##
  ## Everything falls out of the one number `pain[B]`:
  ##
  ##   pain = 0     Some route from A to B never drops below the corridor
  ##                floor. The map obeys the 68 px minimum. There is no
  ##                chokepoint and nothing to report.
  ##   0 < pain     Every route pays. The cheapest one is reconstructed and
  ##                cut into maximal sub-68px stretches; each of those IS a
  ##                chokepoint, and each is checked against `maxPinchRunPx`
  ##                at its own tightest width.
  ##   pain >= 396  A whole kill's worth in one stretch: a kill box.
  ##
  ## ------------------------------------------------------------------------
  ## WHICH ROUTE THE RULE IS EVALUATED ON — the second control failure
  ## ------------------------------------------------------------------------
  ##
  ## Minimising TOTAL pinch debt is not what a player does, and taking it
  ## literally flagged the control a second time: on the arena the cheapest-
  ## by-total route threaded a 26 px gap between two pickets for 133 px,
  ## because a long tight squeeze summed cheaper than a short detour. The
  ## widest route available on that board is 36 px (`routeWidthPx`), and 36 px
  ## is the door a player actually walks through.
  ##
  ## So the search is LEXICOGRAPHIC: widest bottleneck first, least debt
  ## second. `routeWidthPx` gives the maximin width T, the graph is restricted
  ## to floor at least T wide, and Dial's runs inside that. The rule is then
  ## evaluated on the route a player would really pick, and `minWidthPx` of
  ## the worst run agrees with `routeWidthPx` by construction instead of
  ## contradicting it.
  ##
  ## THE CUT TEST IS STILL THE ONLY FILTER, and it is now on the right graph.
  ## A stretch is confirmed by blocking it and re-routing. "Strictly more
  ## painful" is too weak a bar — on a board where every route pays something,
  ## any detour is worse by a pixel and everything reads as mandatory — so the
  ## bar is a WHOLE KILL's worth of extra exposure (`LethalUnit`), or outright
  ## disconnection. A notch beside a wide opening re-routes for nearly free
  ## and is dropped, so no confetti; a real doorway costs a kill to avoid, so
  ## never a blanket zero. No ridge heuristic and no medial-axis skeleton is
  ## involved at any point.
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
  if anchorPx.len < 2: return

  # The engine's protected spawn pocket and its approach — the first fifth of
  # the walk to the nearest other base. Its mouth is a genuine cut on EVERY
  # board, carved identically on all of them, and no map author controls it.
  # `map_metrics` excludes it from both the route metric and the chokepoint
  # detector for exactly this reason; charging pinch debt for it would make
  # every map fail on the engine's own geometry.
  let plain = geodesic(walk, w, h, [anchorPx[0]])
  var nearBase = newSeq[bool](n)
  for a in 0 ..< anchorPx.len:
    let field = if a == 0: plain else: geodesic(walk, w, h, [anchorPx[a]])
    var span = -1
    for b in 0 ..< anchorPx.len:
      if b == a: continue
      let d = int(field[anchorPx[b]])
      if d >= 0 and (span < 0 or d < span): span = d
    if span < 5 * EngineMinCorridorPx: continue
    let near = int32(span div 5)
    for i in 0 ..< n:
      if field[i] >= 0 and field[i] <= near: nearBase[i] = true

  # --- restrict to the WIDEST route ---------------------------------------
  # Lexicographic: widest bottleneck first, least pinch debt second. Without
  # this the router threads a long tight squeeze whenever it sums cheaper than
  # a short detour, which is not a route any player takes. See the doc above.
  let routeW = routeWidthPx(wall, w, h, anchors)
  result.routeWidthPx = routeW
  var wide = newSeq[bool](n)
  for i in 0 ..< n:
    wide[i] = walk[i] and (nearBase[i] or 2 * int(clear[i]) >= routeW)

  # --- pixel cost ---------------------------------------------------------
  var cost = newSeq[uint8](n)
  for i in 0 ..< n:
    if not walk[i]: continue
    cost[i] =
      if nearBase[i]: 0'u8
      else: uint8(pixelLethality(2 * int(clear[i]), corridorMinPx))
  var maxCost = 0
  for i in 0 ..< n: maxCost = max(maxCost, int(cost[i]))

  # --- Dial's: least-pinch routing ---------------------------------------
  # Buckets are indexed by pain modulo (maxCost + 1); every relaxation moves
  # forward by at most `maxCost`, so the cyclic window is always valid. This
  # is the same bucket structure `burrow.weightedDistances` runs on.
  proc leastPain(trav: seq[bool],
                 blocked: seq[bool]): tuple[pain: seq[int32], prev: seq[int32]] =
    let buckets = max(1, maxCost) + 1
    var
      pain = newSeq[int32](n)
      prev = newSeq[int32](n)
      queue = newSeq[seq[int32]](buckets)
    for i in 0 ..< n:
      pain[i] = int32.high
      prev[i] = -1
    if blocked.len == n and blocked[anchorPx[0]]: return (pain, prev)
    pain[anchorPx[0]] = 0
    queue[0].add int32(anchorPx[0])
    var
      level = 0
      seen = 1
      drained = 0
    while drained < seen:
      let slot = level mod buckets
      while queue[slot].len > 0:
        let i = int(queue[slot].pop())
        if int(pain[i]) != level: continue
        inc drained
        let x = i mod w
        for step in [-1, 1, -w, w]:
          if step == -1 and x == 0: continue
          if step == 1 and x == w - 1: continue
          let j = i + step
          if j < 0 or j >= n or not trav[j]: continue
          if blocked.len == n and blocked[j]: continue
          let nd = int32(level + int(cost[j]))
          if nd < pain[j]:
            if pain[j] == int32.high: inc seen
            pain[j] = nd
            prev[j] = int32(i)
            queue[int(nd) mod buckets].add int32(j)
      inc level
      if level > n * (maxCost + 1) + buckets: break
    (pain, prev)

  # Blocking a pinch means sealing its CROSS-SECTION, not drawing a line
  # through it. The first cut test blocked only the 1 px path chain and every
  # synthetic doorway came back non-mandatory, because a player just steps one
  # pixel to the side. The clearance disc at a pinched pixel reaches both walls
  # by definition, so stamping it is exactly "close this passage" — the same
  # `clearPx + PlayerHalf` disc `map_metrics` seals a chokepoint candidate with.
  proc sealRun(dst: var seq[bool], pixels: seq[int32]) =
    for m in pixels:
      let
        i = int(m)
        cx = i mod w
        cy = i div w
        rad = int(clear[i]) + PlayerHalf
      for yy in max(0, cy - rad) .. min(h - 1, cy + rad):
        for xx in max(0, cx - rad) .. min(w - 1, cx + rad):
          let dx = xx - cx
          let dy = yy - cy
          if dx * dx + dy * dy <= rad * rad: dst[yy * w + xx] = true

  proc runsAlong(pain, prev: seq[int32], pass: int,
                 runs: var seq[PinchRun], runPixels: var seq[seq[int32]]) =
    ## Walk the predecessor chain back to base 0, cutting it into maximal
    ## stretches of sub-corridor floor. Each stretch is one gate, and its
    ## length in pixels IS its arc length: the chain is 4-connected, one px a
    ## step.
    for b in 1 ..< anchorPx.len:
      if pain[anchorPx[b]] == int32.high: continue
      var path: seq[int32]
      var cur = int32(anchorPx[b])
      var guard = 0
      while cur >= 0 and guard <= n:
        path.add cur
        if int(cur) == anchorPx[0]: break
        cur = prev[int(cur)]
        inc guard
      var k = 0
      while k < path.len:
        if cost[int(path[k])] == 0:
          inc k
          continue
        var
          run = PinchRun(minWidthPx: high(int), onRoute: true, pass: pass)
          sx, sy, count = 0
          pix: seq[int32]
        while k < path.len and cost[int(path[k])] > 0:
          let j = int(path[k])
          run.minWidthPx = min(run.minWidthPx, 2 * int(clear[j]))
          sx += j mod w
          sy += j div w
          inc count
          pix.add int32(j)
          inc k
        run.pixels = count
        run.arcLenPx = count
        run.exposedPx = longestExposedRunPx(wall, w, h, pix)
        run.x = sx div max(1, count)
        run.y = sy div max(1, count)
        run.allowedPx = maxPinchRunPx(run.minWidthPx)
        runs.add run
        runPixels.add pix

  var noBlock: seq[bool]
  let (pain, prev) = leastPain(wide, noBlock)
  # The cut test asks "can a player route around this AT ALL", which is a
  # question about the whole board — so its baseline is the UNRESTRICTED
  # walkable graph. Asking it on the width-restricted graph made it vacuous:
  # that graph is pinned at the maximin width, so sealing the bottleneck
  # disconnects it BY CONSTRUCTION and every pass-0 run came back mandatory,
  # including on the arena, which has eight disjoint routes.
  let painFull = leastPain(walk, noBlock).pain

  # --- the gates, route by route -----------------------------------------
  # Pass 0 is the route a player takes and the one `ok` is decided on. Then
  # the route is SEALED and the search repeats on the FULL walkable graph --
  # not the width-restricted one, or the alternatives are excluded by the very
  # width restriction that picked pass 0. On a carved board the ungated fast
  # lane is the widest route, so pass 0 measures IT and every designed gate
  # sits on a narrower lane the restriction had already thrown away. That
  # enumerates one gate per independent lane, which is what the isovist
  # assertion needs: on a map with three parallel doors NONE of them is
  # individually load-bearing, so a cut test alone would report zero gates on
  # exactly the map this generator is built to produce.
  var
    runs: seq[PinchRun]
    runPixels: seq[seq[int32]]
    sealed = newSeq[bool](n)
  var passReached = newSeq[bool](MaxRoutePasses)
  runsAlong(pain, prev, 0, runs, runPixels)
  for b in 1 ..< anchorPx.len:
    if pain[anchorPx[b]] != int32.high: passReached[0] = true
  result.routePasses = 1
  block passes:
    var cumulative: seq[seq[int32]]
    for m in runPixels: cumulative.add m
    # Seal only the GATES, not the whole path. Stamping a full route's
    # clearance discs severs a picket-field board outright — on the arena it
    # left every later pass unreachable, so the search never saw the seven
    # other routes the board actually has.
    for pix in cumulative: sealRun(sealed, pix)
    for pass in 1 ..< MaxRoutePasses:
      let probe = leastPain(walk, sealed)
      var reached = false
      for b in 1 ..< anchorPx.len:
        if probe.pain[anchorPx[b]] != int32.high: reached = true
      if not reached: break passes
      passReached[pass] = true
      inc result.routePasses
      var passRuns: seq[PinchRun]
      var passPixels: seq[seq[int32]]
      runsAlong(probe.pain, probe.prev, pass, passRuns, passPixels)
      for i in 0 ..< passRuns.len:
        runs.add passRuns[i]
        runPixels.add passPixels[i]
      if passPixels.len == 0: break passes
      for pix in passPixels: sealRun(sealed, pix)

  # --- the cut test: THE ONLY FILTER --------------------------------------
  # Seal the stretch's cross-section and re-route. If the cheapest route gets
  # a whole kill more painful, or vanishes, the stretch was load-bearing and
  # is a genuine cut. A notch beside a wide opening re-routes for nearly free
  # and is dropped here — that is the anti-confetti filter, and it is the only
  # one. Note a real map with three parallel doors has NO individually
  # mandatory gate, which is correct and is why `gates` exists alongside
  # `chokepoints`.
  if runs.len > 0:
    var order: seq[int]
    for i in 0 ..< runs.len: order.add i
    order.sort(proc (a, b: int): int = cmp(runs[a].minWidthPx, runs[b].minWidthPx))
    if order.len > PinchCandidateCap: order.setLen(PinchCandidateCap)
    for k in order:
      var blocked = newSeq[bool](n)
      sealRun(blocked, runPixels[k])
      let probe = leastPain(walk, blocked)
      var harder = false
      for b in 1 ..< anchorPx.len:
        if painFull[anchorPx[b]] == int32.high: continue
        if probe.pain[anchorPx[b]] == int32.high or
            int(probe.pain[anchorPx[b]]) - int(painFull[anchorPx[b]]) >= LethalUnit:
          harder = true
      runs[k].mandatory = harder
      runs[k].tested = true

  # --- verdict ------------------------------------------------------------
  runs.sort(proc (a, b: PinchRun): int = cmp(b.excessPx, a.excessPx))
  result.runs = runs
  result.worstExcessPx = if runs.len == 0: 0 else: low(int)
  # THE VERDICT, and the cut test is the only filter here too.
  #
  # A kill box you can walk AROUND is not a kill box, it is a flank. The
  # arena settles this: its widest route is 36 px and it carries a straight
  # 188 px channel along the bottom border, which by the raw physics is
  # lethal — and it ships, and it plays well, because it is ONE optional lane
  # among eight and a player who dislikes the odds takes another. Rejecting a
  # map for owning a risky flank would reject the best map in the repo and
  # would forbid the tight-flank lane this generator exists to build.
  #
  # What is genuinely fatal is a pinch that is MANDATORY — sealing it costs a
  # whole kill to route around, or disconnects the board outright — AND too
  # long to clear alive. Then there is no alternative and no way through.
  for r in runs:
    if r.mandatory: result.chokepoints.add r
    if r.pass < MaxRoutePasses: result.gates.add r
    result.worstExcessPx = max(result.worstExcessPx, r.excessPx)
  for r in result.chokepoints:
    if r.exposedPx > r.allowedPx and result.reason.len == 0:
      result.ok = false
      result.reason =
        "kill box at (" & $r.x & "," & $r.y & "): an UNAVOIDABLE pinch holds " &
          $r.exposedPx & "px of unbroken sightline in floor only " &
          $r.minWidthPx & "px wide, past the " & $r.allowedPx &
          "px a player can clear alive at that width (corridor floor is " &
          $corridorMinPx & "px, this map's widest route is " &
          $result.routeWidthPx & "px)"

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

# ---------------------------------------------------------------------------
# LANE CARVING
# ---------------------------------------------------------------------------
#
# A route network is not three corridors of the same shape in three places.
# The MW2 grammar is ONE TIGHT FLANK, ONE CONTESTED MID, ONE EXPOSED FAST
# LANE, and the lengths differ: Terminal shipped 1575 / 1064 / 1352, mid
# fastest but flankable. Three identical corridors give a player a choice with
# no decision in it.
#
# Lanes here are y-PROFILES over the attack axis: each lane is a function
# `laneY(x)` built from waypoints. That one representation makes every
# operation below a one-liner — the separator between two lanes is their
# midline, a gate is two shoulders straddling the profile, and a piece of
# cover intrudes exactly when its centre is within a lane half-width of the
# profile at its own x.
#
# WHY PROFILES JOG. A straight horizontal lane is an open horizontal
# sightline, which `arena`'s validator rejects outright ("open horizontal
# sightline at y="), and `map_rules.maxOpenRunPx` forbids for the same reason
# a designer would. Every profile therefore carries vertical jogs, which cost
# nothing in readability and buy both the validator and the sightline budget.

type
  LaneRole* = enum
    laneFlank   ## tight, longest, hugs the edge. The sneak route.
    laneMid     ## contested, shortest, through the middle. Everyone meets here.
    laneFast    ## exposed, wide, straight. Quick but you are seen.

  LaneGate* = object
    ## One deliberate pinch across a lane.
    x*, y*: int
    widthPx*: int    ## 30-45: one cog at a time
    runPx*: int      ## how deep the pinch is, always <= maxPinchRunPx(width)

  Lane* = object
    role*: LaneRole
    path*: seq[MapPoint]   ## waypoints, ascending in x
    widthPx*: int
    lengthPx*: int
    gates*: seq[LaneGate]

  LanePlan* = object
    region*: MapRect
    seamX*: int
    corridorMinPx*: int
    sepThickPx*: int
    laneStartX*: int
      ## Where the profiles leave the base and the lanes become distinct.
      ## Nothing structural can exist left of it.
    lanes*: seq[Lane]

func laneY*(lane: Lane, x: int): int =
  ## The lane's centreline at this x, linearly interpolated between waypoints.
  if lane.path.len == 0: return 0
  if x <= lane.path[0].x: return lane.path[0].y
  for i in 1 ..< lane.path.len:
    if x <= lane.path[i].x:
      let
        a = lane.path[i - 1]
        b = lane.path[i]
        span = max(1, b.x - a.x)
      return a.y + (b.y - a.y) * (x - a.x) div span
  lane.path[^1].y

func laneLengthPx*(lane: Lane): int =
  ## Arc length of the profile — the distance a player actually runs. This is
  ## what must DIFFER between lanes; three routes of equal length are one
  ## route drawn three times.
  for i in 1 ..< lane.path.len:
    let
      dx = float(lane.path[i].x - lane.path[i - 1].x)
      dy = float(lane.path[i].y - lane.path[i - 1].y)
    result += int(round(sqrt(dx * dx + dy * dy)))

func gateWidthFor*(rng: var Rand, rules: MapRules): int =
  ## A gate width inside the design band. Never the corridor floor: a gate
  ## that admits two cogs abreast is not a gate.
  ChokeWidthMinPx + rand(rng, ChokeWidthMaxPx - ChokeWidthMinPx)

func maxGateRunPx*(widthPx: int): int =
  ## How deep a gate of this width may be built.
  ##
  ## NOT `maxPinchRunPx(widthPx)` directly: the measured exposed run of a
  ## doorway includes the FUNNEL on both sides, where the floor has already
  ## dropped below the corridor width but the walls have not closed to the
  ## gate width yet. A 40 px door through a 40 px wall measures 94 px of
  ## exposure, not 40. Budgeting half the allowance for the pinch itself
  ## leaves the other half for its approaches, which is what keeps a built
  ## gate inside the rule that will later audit it.
  max(EngineMinCorridorPx, maxPinchRunPx(widthPx) div 2)

proc planLanes*(
  rng: var Rand, region: MapRect, base: MapPoint, seamX: int, rules: MapRules
): LanePlan =
  ## The route plan for one half-field: `rules.laneCount` lanes from the base
  ## out to the symmetry seam, with different widths, different lengths and
  ## different gate counts.
  ##
  ## Emitted in the SEED half only. The symmetry lift in `arena` mirrors it,
  ## so a lane meets its own image at the seam and the pair is one full route
  ## between the two bases — which is what makes the count of lanes here the
  ## count of vertex-disjoint routes there.
  result.region = region
  result.seamX = seamX
  result.corridorMinPx = rules.minCorridorWidthPx
  let
    lanes = max(3, rules.laneCount)
    top = region.y
    bottom = region.y + region.h
    usable = max(1, bottom - top)
    x0 = max(region.x, base.x)
    xs = max(x0 + 4 * EngineMinCorridorPx, seamX)
    # NOT `EngineMinCorridorPx`. That is a free-SPACE minimum and using it as a
    # wall thickness held the separator network at a fixed absolute size while
    # the board shrank, which is what put the small class over the cover
    # ceiling on structure alone. `map_rules` scales it by
    # `crossSection / (laneCount + 1)`; standard is unchanged at 26.
    thick = rules.laneSeparatorThickPx
    jogAmp = rules.coverSizePx div 2
  result.sepThickPx = thick
  result.laneStartX = x0
  # Lane WIDTHS first, then the bands are packed around them with a separator
  # between each pair and at both margins. Pitching the bands evenly and
  # setting widths independently (the obvious way) overruns the cross-section:
  # the outer lanes ended up squeezed against the border, the flank's bow ran
  # off the board, and the separators had no room to be structure rather than
  # trim.
  var widths: seq[int]
  for i in 0 ..< lanes:
    let isMid = i == lanes div 2
    widths.add(
      if isMid: rules.laneWidthPx
      elif i == 0: rules.minCorridorWidthPx
      else: rules.laneWidthPx + rules.coverSizePx div 2)
  # The jog amplitude has to be RESERVED, not taken out of the separators.
  # Packing bands from widths alone left 3px of slack on a standard half, so
  # the profiles' jogs pushed adjacent lanes into overlap, the separator
  # between them was suppressed by its own `yb - ya >= thick` guard, and the
  # middle of the board came out as one open expanse with no structure in it.
  # Jog room is reserved between EVERY pair, not just at the margins.
  # Reserving it only at the outside still let a jogging lane close to within
  # 6px of its neighbour mid-field, where the separator's own `yb - ya >=
  # thick` guard then suppressed it and the board lost its middle structure.
  let pitch = thick + 2 * jogAmp
  var need = (lanes + 1) * pitch
  for wpx in widths: need += wpx
  if need > usable:
    # Shrink lanes proportionally, never below the corridor floor: a lane one
    # body wide is a corridor, and a network of corridors has no overtaking.
    let slack = need - usable
    var shrinkable = 0
    for wpx in widths: shrinkable += max(0, wpx - rules.minCorridorWidthPx)
    if shrinkable > 0:
      for i in 0 ..< widths.len:
        let give = max(0, widths[i] - rules.minCorridorWidthPx)
        widths[i] -= min(give, give * slack div shrinkable)
  var cursor = top + pitch
  for i in 0 ..< lanes:
    var lane = Lane()
    let
      bandY = cursor + widths[i] div 2
      isMid = i == lanes div 2
    # The FIRST band is the tight flank and the LAST is the exposed fast lane.
    # Making both edges flanks (the obvious reading of "outermost") produced
    # flank / mid / flank on a three-lane board -- two identical routes and no
    # fast lane at all, which is the failure this grammar exists to prevent.
    lane.role =
      if isMid: laneMid
      elif i == 0: laneFlank
      elif i == lanes - 1: laneFast
      else: (if i < lanes div 2: laneFlank else: laneFast)
    lane.widthPx = widths[i]
    cursor += widths[i] + pitch
    # Profiles. Mid runs straight from the base to the seam and is therefore
    # the SHORTEST — the fastest route, and the one everyone contests. The
    # others must climb to their band first, which costs length for free, and
    # the flank additionally bows toward the edge, which is what makes it the
    # longest and the sneakiest.
    let
      headroom = min(bandY - top - widths[i] div 2 - thick,
                     bottom - bandY - widths[i] div 2 - thick) - thick
      jog = clamp(jogAmp, 0, max(0, headroom))
      # Lanes fan out from the base and must be ON their bands for the rest of
      # the run; a fan that lasts the whole field is three lanes that overlap
      # everywhere except the seam.
      fan = x0 + (xs - x0) div 5
      mid1 = x0 + (xs - x0) div 3
      mid2 = x0 + 2 * (xs - x0) div 3
    case lane.role
    of laneMid:
      # Straight once it is on its band: the SHORTEST route, which is what
      # makes it the fast one everybody contests.
      lane.path = @[
        MapPoint(x: x0, y: base.y),
        MapPoint(x: fan, y: bandY),
        MapPoint(x: xs, y: bandY)]
    of laneFast:
      # One shallow jog: long enough to break the horizontal sightline, not so
      # long that it stops being the quick way across.
      lane.path = @[
        MapPoint(x: x0, y: base.y),
        MapPoint(x: fan, y: bandY),
        MapPoint(x: mid2, y: bandY - jog),
        MapPoint(x: xs, y: bandY)]
    of laneFlank:
      # Serpentine: the LONGEST route, and the tightest. You take it to
      # arrive somewhere nobody is looking, and you pay for it in seconds.
      lane.path = @[
        MapPoint(x: x0, y: base.y),
        MapPoint(x: fan, y: bandY + jog),
        MapPoint(x: mid1, y: bandY - jog),
        MapPoint(x: mid2, y: bandY + jog),
        MapPoint(x: xs, y: bandY)]
    lane.lengthPx = lane.laneLengthPx()
    # Gates. `map_rules` sizes the count by traverse over one gun range: two
    # gates are tactically distinct exactly when a defender holding one cannot
    # shoot into the other.
    #
    # At least TWO per lane, always. One gate cannot break its own lane:
    # whatever rows its opening spans run clear from base to seam. Two gates
    # with DISJOINT openings (see the stagger below) leave no row that threads
    # both, which is what turns "no unbroken sightline" from a validator
    # complaint into a property of the construction.
    #
    # That is why the fast lane is no longer gate-free, which it was. It stays
    # fast — two SHORT pinches add no arc length and it keeps the widest
    # profile — but "exposed, wide, straight" cannot mean a clear 800px row
    # with a map-wide gun on the board. Measured before this: 18-23 open rows
    # on 3 of 3 carved seeds, in bands sitting exactly on the un-gated and
    # single-gated lanes.
    #
    # NOTE (measured, left alone deliberately): `chokepointsPerRoute` is a
    # count PER ROUTE and a route is this lane PLUS its mirror across the
    # seam, so spending the whole figure in one half puts twice the intended
    # chokepoints on every full route. Halving it here does cut structure —
    # gate shoulders are 52 of the small class's 132 permille — but it is a
    # net LOSS: measured over 20 seeds it took median interiorFrac 0.293 ->
    # 0.267, because a gate shoulder is exactly the kind of architecture the
    # enclosure metric is looking for. It also moves every class, and the
    # classes above small are not in trouble. Filed as its own task instead.
    let want =
      case lane.role
      of laneFlank: max(2, rules.chokepointsPerRoute)
      of laneMid: 2
      of laneFast: 2
    # Gate x positions are STAGGERED per lane and aligned to the middle of a
    # separator run. Both matter and both were found by measurement:
    #   - Spacing them evenly per lane put all three gates of a three-lane
    #     board on ONE vertical line, and the isovist assertion immediately
    #     reported that a single vantage watches every chokepoint. One camper
    #     would own the map.
    #   - A gate in a separator GAP pinches nothing: players leave the lane
    #     through the gap and walk around it. A gate has to sit where the lane
    #     is enclosed, which is the middle of a wall segment.
    let period = WallSpanPx + max(EngineMinCorridorPx, lane.widthPx)
    for g in 0 ..< want:
      # Spread the gates of one lane along its run, then OFFSET each lane by
      # half a slot so no two lanes gate at the same x, then SNAP to the
      # nearest separator-segment centre.
      let
        frac = (2 * g + 1) * 2 * lanes + (2 * i + 1)
        want2 = 2 * want * 2 * lanes
        wish = x0 + (xs - x0) * frac div max(1, want2)
        k = (wish - region.x - WallSpanPx div 2 + period div 2) div period
        snapped = region.x + k * period + WallSpanPx div 2
        gx =
          if snapped > x0 + EngineMinCorridorPx and
             snapped < xs - EngineMinCorridorPx: snapped
          else: wish
        drawn = gateWidthFor(rng, rules)
        ## A gate opening must be narrow enough that TWO of them, pushed to
        ## opposite lane edges, do not overlap — otherwise a row threads every
        ## gate in the lane and survives as an unbroken sightline. Two
        ## openings at offsets +-(W - gw)/2 are disjoint exactly when
        ## gw < W/2, so that is the clamp. It only ever binds on the tight
        ## flank (W = the corridor floor), where it lands at the 30 px bottom
        ## of the design band rather than outside it.
        gw = max(EngineMinCorridorPx, min(drawn, (lane.widthPx - 2) div 2))
        ## Alternate the opening between the lane's two edges. Every gate used
        ## to be centred on the centreline (`y: lane.laneY(gx)`), so a lane's
        ## openings all overlapped there and the centre rows passed through
        ## the lot of them untouched — measured as bands of 8-23 open rows on
        ## 3 of 3 carved seeds. Staggering is also what makes the pinch a real
        ## decision: you enter through one opening, move ACROSS the lane, and
        ## leave through the other.
        offset = (lane.widthPx - gw) div 2
        gy = lane.laneY(gx) + (if g mod 2 == 0: -offset else: offset)
      if gx <= x0 + EngineMinCorridorPx or gx >= xs - EngineMinCorridorPx:
        continue
      lane.gates.add LaneGate(
        x: gx, y: gy, widthPx: gw, runPx: maxGateRunPx(gw))
    result.lanes.add lane

proc laneSeparatorShapes*(plan: LanePlan, thickPx = 0): seq[ArenaShape] =
  ## The structural walls BETWEEN adjacent lanes. Without these there are no
  ## lanes, only three imaginary lines drawn on one open field.
  ##
  ## Each separator follows the midline of the two profiles it divides and is
  ## emitted in SEGMENTS at least `map_rules.wallSpanPx` long with a lane's
  ## width of gap between them. That span is derived: rounding one end of a
  ## wall of span S costs S/2 of extra travel, and for the separation to mean
  ## anything that detour has to cost more than a kill takes, so
  ## S >= 2 * maxExposedRunPx = 264 px. Shorter walls are cover, not structure.
  ## The MARGIN strips between the outermost lanes and the board edge get a
  ## separator too. Skipping them left a ~44 px lane of untouched floor along
  ## the top border running the whole width, and `arena`'s validator rejected
  ## every carved map outright with "open horizontal sightline at y=12".
  let thick = if thickPx > 0: thickPx else: max(12, plan.sepThickPx)
  const Step = 14
  if plan.lanes.len == 0: return
  for i in 0 .. plan.lanes.len:
    let
      above =
        if i == 0:
          Lane(widthPx: 0, path: @[
            MapPoint(x: plan.region.x, y: plan.region.y),
            MapPoint(x: plan.seamX, y: plan.region.y)])
        else: plan.lanes[i - 1]
      below =
        if i == plan.lanes.len:
          Lane(widthPx: 0, path: @[
            MapPoint(x: plan.region.x, y: plan.region.y + plan.region.h),
            MapPoint(x: plan.seamX, y: plan.region.y + plan.region.h)])
        else: plan.lanes[i]
      gap = max(EngineMinCorridorPx, max(above.widthPx, below.widthPx))
      # Phase from where the lanes actually DIVERGE, not from the board edge.
      # Everything left of that is the home pocket, where all profiles sit on
      # the base and no separator can exist; phasing from region.x spent most
      # of every separator's duty cycle in that dead zone and left the middle
      # of the field as one open expanse.
      runStart = plan.laneStartX
      runSpan = max(1, plan.seamX - runStart)
      # One wallSpan segment plus one gap is the most a standard half-field
      # fits, so clamp the period to the span rather than letting a segment
      # fall off the end, and STAGGER each separator by a fraction of it so
      # the gaps do not line up into an open cross-field row.
      period = min(WallSpanPx + gap, runSpan)
      span = max(WallSpanPx * 2 div 3, period - gap) * 5 div 8
      offset = i * period div max(1, plan.lanes.len + 1)
    var x = runStart
    while x < plan.seamX:
      let phase = (x - runStart + offset) mod period
      if phase < span:
        let
          ya = above.laneY(x) + above.widthPx div 2
          yb = below.laneY(x) - below.widthPx div 2
          y = (ya + yb) div 2
        if yb - ya >= thick:
          # A flat separator blocks only the rows it sits on, and `arena`'s
          # validator wants EVERY row between the capture columns broken. The
          # margin strips are where that bites -- a single thin wall at y=46
          # left the whole top border open and every carved map was rejected
          # with "open horizontal sightline at y=64". So a separator SWEEPS
          # its band as a triangle wave, which costs nothing and closes every
          # row it spans.
          let
            room = max(0, (yb - ya - thick) div 2)
            cycle = max(1, span)
            t = (x - plan.region.x) mod cycle
            tri = if t < cycle div 2: t * 2 else: (cycle - t) * 2
            sweep = if room == 0: 0 else: (tri * room * 2) div cycle - room
          result.add ArenaShape(kind: shapeRect, rect: MapRect(
            x: x, y: y + sweep - thick div 2, w: Step + 2, h: thick))
      x += Step

proc laneGateShapes*(plan: LanePlan): seq[ArenaShape] =
  ## The gate SHOULDERS: two stubs straddling a lane's centreline that pinch
  ## it to `gate.widthPx` for `gate.runPx`, and no further.
  ##
  ## This is the feature the length-aware rule exists to make legal. A global
  ## 68 px corridor floor would reject every one of these; the pinch rule
  ## accepts them precisely because they are SHORT.
  ## The shoulders are measured from the LANE BAND, not from the gate's own
  ## y. Once an opening is staggered off the centreline (which is what stops
  ## a row threading every gate), a shoulder sized from the gate centre no
  ## longer reaches the far edge of the lane, and the rows it fails to reach
  ## are exactly the ones that stayed open. Each shoulder therefore runs from
  ## the lane edge to the opening, and overruns the band by one engine
  ## corridor so it keys into the separator instead of leaving a seam.
  ## The overrun past the band is deliberately SMALL. A full engine corridor
  ## on each side reads as "obviously safe" and costs
  ## `2 * overrun * runPx` of wall per gate, which measured 186 permille cover
  ## against a 180 ceiling — trading the sightline failure for a clogged one.
  ## The shoulder only has to deny a player the seam between lane edge and
  ## separator, so it is sized to the engine's own collision footprint.
  const GateKeyPx = 8
  for lane in plan.lanes:
    let half = lane.widthPx div 2
    for gate in lane.gates:
      let
        cy = lane.laneY(gate.x)
        opening = gate.widthPx div 2
        bandLo = min(cy - half, gate.y - opening) - GateKeyPx
        bandHi = max(cy + half, gate.y + opening) + GateKeyPx
        upper = gate.y - opening - bandLo
        lower = bandHi - (gate.y + opening)
      if upper >= 6:
        result.add ArenaShape(kind: shapeRect, rect: MapRect(
          x: gate.x, y: bandLo, w: gate.runPx, h: upper))
      if lower >= 6:
        result.add ArenaShape(kind: shapeRect, rect: MapRect(
          x: gate.x, y: gate.y + opening, w: gate.runPx, h: lower))

func laneBandOver*(lane: Lane, x0, x1: int): tuple[lo, hi: int] =
  ## The vertical band this lane occupies over an x RANGE — the centreline's
  ## own excursion across that range, widened by the half width.
  ##
  ## Exact, not sampled. `laneY` is piecewise linear, so its extrema over
  ## `[x0, x1]` are attained at an endpoint or at a waypoint strictly inside,
  ## and there are a handful of waypoints. The strided version this replaces
  ## (`x += 14`) could step straight over a lane crossing, which is the same
  ## class of bug as the one below but pointing the other way.
  let half = lane.widthPx div 2
  var
    lo = min(lane.laneY(x0), lane.laneY(x1))
    hi = max(lane.laneY(x0), lane.laneY(x1))
  for p in lane.path:
    if p.x > x0 and p.x < x1:
      lo = min(lo, p.y)
      hi = max(hi, p.y)
  (lo - half, hi + half)

proc intrudesOnLane*(plan: LanePlan, shape: ArenaShape): bool =
  ## Whether a piece of cover would narrow a lane below its DESIGNED width.
  ## Discs and diamonds test centre-to-profile; rects test their span against
  ## `laneBandOver` over the x range they actually cover.
  ##
  ## The rect branch used to walk x in strides of 14, which could step clean
  ## over a lane crossing. `laneBandOver` answers the same question exactly and
  ## costs less.
  ##
  ## Note this is the DESIGN-width question, not the legality question.
  ## `clearLanes` asks the second one — how much of a lane may be spent before
  ## the corridor floor is breached — and uses `laneCoreOver` for it.
  for lane in plan.lanes:
    case shape.kind
    of shapeDisc, shapeDiamond:
      let half = lane.widthPx div 2
      if shape.cx < plan.region.x - shape.radius or shape.cx > plan.seamX: continue
      if abs(shape.cy - lane.laneY(shape.cx)) < half + shape.radius: return true
    of shapeRect:
      let band = lane.laneBandOver(shape.rect.x, shape.rect.x + shape.rect.w)
      if shape.rect.y <= band.hi and shape.rect.y + shape.rect.h >= band.lo:
        return true
    of shapePolygon:
      # KNOWN UNSOUND, deliberately left alone: see `clearLanes`. A vertex test
      # both misses a triangle that straddles a lane with no vertex in it and
      # condemns one that only clips a corner. Fixing it is coupled to the fill
      # DENSITY and is tracked separately.
      let half = lane.widthPx div 2
      for p in shape.points:
        if abs(p.y - lane.laneY(p.x)) < half: return true
    of shapeDiagonal:
      let half = lane.widthPx div 2
      if abs(shape.y0 - lane.laneY(shape.x0)) < half: return true
      if abs(shape.y1 - lane.laneY(shape.x1)) < half: return true
  false

const
  LaneClipSlabPx* = 24
    ## How finely a rect is cut when it is clipped against a SLOPED lane. One
    ## band for the whole rect is correct but wasteful: `laneFlank` descends
    ## 231 px across the half-field, so its band over a 120 px block is ~64 px
    ## taller than the lane itself and eats the block whole. Cutting the block
    ## into slabs lets each one see only its own local band, and the surviving
    ## pieces step down alongside the lane — which is what a row of buildings
    ## along a diagonal avenue looks like. Adjacent slabs that clip identically
    ## are merged back, so a lane running flat under a block still yields ONE
    ## rect, not five.
  LaneTrimMinPx* = EngineMinCorridorPx
    ## The thinnest surviving sliver worth keeping — the engine's own collision
    ## footprint. Below this a trimmed block is a hairline against the street:
    ## it reads as grime rather than structure, and no cog can stand behind a
    ## piece of cover narrower than a cog. Dropping it is the one case where
    ## deletion is right.
    ##
    ## It is also the knob that pays for the trim. `arena`'s fill budget is
    ## spent in EMISSION ORDER and skips any shape too big for what is left, so
    ## cutting one rejected block into several small ones lets the budget be
    ## spent more completely and the shipping generator already runs at a
    ## median 163 permille against a 170 ceiling. At 16 px the slivers cost
    ## 2 valid seeds in 60; at the engine footprint they do not.

func laneCoreOver*(lane: Lane, corridorMinPx, x0, x1: int): tuple[lo, hi: int] =
  ## The part of a lane that cover may NEVER touch, over an x range.
  ##
  ## A lane is not a keep-out zone; it is a route with a WIDTH BUDGET. The
  ## floor is `corridorMinPx`, and anything a lane carries above that floor is
  ## slack it can spend on cover — which this module already asserts it should
  ## ("a lane with NO cover in it is wrong by this repo's own rules", see the
  ## disc branch of `clearLanes` and `map_rules.MaxExposedRunPx`). So the
  ## protected core is the band shrunk by half the slack on each side, and the
  ## complement of the core is where cover may live.
  ##
  ## THE CHANNEL THIS LEAVES IS A GUARANTEE, NOT A MEASUREMENT. Write the
  ## lane's half width `h`, its centreline excursion across the range `E`, and
  ## `keep = (2h - corridorMinPx) / 2`. The band is `[minCy - h, maxCy + h]`,
  ## the core is that shrunk by `keep`, and cover lives outside the core. At
  ## any single x the free part of the lane is `lane ∩ core`, whose height is
  ##   E >= keep:  2h - keep      = corridorMin + (2h - corridorMin)/2
  ##   E <  keep:  2h + E - 2keep = corridorMin + E
  ## and both are >= `corridorMinPx` for every E. No reroll, no audit — the
  ## arithmetic cannot produce a pinched lane.
  ##
  ## A GATE HAS ALREADY SPENT THE SLACK. Over a gate's run the lane is not
  ## `widthPx` wide, it is `gate.widthPx` wide — 30 to 45 px, one cog — and the
  ## strip left open is STAGGERED off the centreline, so it need not even lie
  ## inside the band. Charging the slack twice is exactly what happened when
  ## this was written without the gate term: the trimmed blocks landed in the
  ## mid lane's gate openings and the map came back "no 26px route to the
  ## center" on 4 city seeds of 6. Over a gate, nothing is spendable.
  let band = lane.laneBandOver(x0, x1)
  var
    keep = max(0, (lane.widthPx - corridorMinPx) div 2)
    lo = band.lo
    hi = band.hi
  for gate in lane.gates:
    # The gate's reach is its run PLUS a funnel on each side, for the same
    # reason `maxGateRunPx` budgets one: a cog leaving a staggered opening is
    # off the centreline and needs a corridor width of run to rejoin the lane.
    # Protecting only the run itself left cover sitting immediately downstream
    # of the opening, where it met the shoulder at an angle and closed the
    # route just as dead -- 4 city seeds of 6, and only the rendered mask
    # showed which pixels did it.
    if gate.x - corridorMinPx > x1: continue
    if gate.x + gate.runPx + corridorMinPx < x0: continue
    keep = 0
    lo = min(lo, gate.y - gate.widthPx div 2)
    hi = max(hi, gate.y + gate.widthPx div 2)
  (lo + keep, hi - keep)

func trimRectToLanes(rect: MapRect, window: bool, plan: LanePlan): seq[ArenaShape] =
  ## Cut a rect down to the parts of it lying outside every lane's core.
  ##
  ## An axis-aligned rect minus a horizontal band is one or two axis-aligned
  ## rects, so this loses no fidelity at all — unlike rejection, which loses
  ## the whole piece. Slabs left to right, subtract each lane's local core from
  ## each slab's surviving y spans, then coalesce.
  var pieces: seq[MapRect]
  let xEnd = rect.x + rect.w
  var x = rect.x
  while x < xEnd:
    let xe = min(x + LaneClipSlabPx, xEnd)
    var spans = @[(rect.y, rect.y + rect.h)]
    for lane in plan.lanes:
      let core = lane.laneCoreOver(plan.corridorMinPx, x, xe)
      var kept: seq[(int, int)]
      for s in spans:
        if s[1] <= core.lo or s[0] >= core.hi:
          kept.add s
          continue
        if core.lo - s[0] >= LaneTrimMinPx: kept.add (s[0], core.lo)
        if s[1] - core.hi >= LaneTrimMinPx: kept.add (core.hi, s[1])
      spans = kept
    for s in spans:
      pieces.add MapRect(x: x, y: s[0], w: xe - x, h: s[1] - s[0])
    x = xe

  for p in pieces:
    var merged = false
    for i in 0 ..< result.len:
      let r = result[i].rect
      if r.y != p.y or r.h != p.h or r.x + r.w != p.x: continue
      # Only merge when the WIDER rect still clears every core. Two slabs can
      # clip to the same y span on opposite sides of a steep lane, and welding
      # those into one rect would lay it straight across the lane.
      var safe = true
      for lane in plan.lanes:
        let core = lane.laneCoreOver(plan.corridorMinPx, r.x, p.x + p.w)
        if r.y < core.hi and r.y + r.h > core.lo:
          safe = false
          break
      if not safe: continue
      result[i].rect.w = r.w + p.w
      merged = true
      break
    if not merged:
      result.add ArenaShape(kind: shapeRect, window: window, rect: p)

proc clearLanes*(shapes: seq[ArenaShape], plan: LanePlan): seq[ArenaShape] =
  ## Push cover OUT of the lanes rather than deleting it.
  ##
  ## Deleting is the obvious move and it is the wrong one twice over: it
  ## spends the map's cover budget (`arena` rejects a map under
  ## `CoverPermilleMin`) and it leaves the lane reading as a random absence.
  ## Sliding a disc perpendicular until it clears keeps the mass AND lines it
  ## up along the lane edge, so the lane reads as something carved through the
  ## terrain — which is exactly what it is.
  ##
  ## SLIDING IS ONLY RIGHT FOR A PEBBLE. A disc has no interior structure, so
  ## moving it whole loses nothing. An extended shape does: a city block is
  ## 120 px on a side and the thing that makes it a BLOCK is where its edges
  ## are, so the operation that preserves it is a CUT, not a shove. Dropping
  ## the whole rect on any overlap made `city` — the only biome in the set
  ## that can render the brief's "blocks" archetype — contribute exactly zero
  ## cover on six seeds of six, because a lane network with three profiles
  ## crosses every block somewhere. Trimming turns the same block into the
  ## buildings that LINE the street, which is both the right geometry and the
  ## right picture.
  ##
  ## Only shapes with nothing left after the cut are dropped.
  for shape in shapes:
    if not plan.intrudesOnLane(shape):
      result.add shape
      continue
    case shape.kind
    of shapeDisc, shapeDiamond:
      var moved = shape
      var placed = false
      for lane in plan.lanes:
        let
          cy = lane.laneY(shape.cx)
          half = lane.widthPx div 2
        if abs(shape.cy - cy) >= half + shape.radius: continue
        # KEEP the piece inside the lane when the lane is wide enough to give
        # it up: hug one edge, and the clear channel left on the far side is
        # `widthPx - 2*radius`. A lane with NO cover in it is wrong by this
        # repo's own rules -- `map_rules.MaxExposedRunPx` says a route may not
        # run more than 132px without cover -- and it is also what left every
        # carved map with an open horizontal sightline, because a swept
        # separator can only break the rows it sits on and nothing broke the
        # rows inside the lanes. The tight flank is exactly the lane this
        # cannot help, which is correct: tight is its character.
        if lane.widthPx - 2 * shape.radius >= plan.corridorMinPx:
          moved.cy =
            if shape.cy < cy: cy - (half - shape.radius)
            else: cy + (half - shape.radius)
          result.add moved
          placed = false
          break
        let push = half + shape.radius + 2
        moved.cy = if shape.cy < cy: cy - push else: cy + push
        placed = true
        break
      if placed and not plan.intrudesOnLane(moved) and
          moved.cy - moved.radius > plan.region.y and
          moved.cy + moved.radius < plan.region.y + plan.region.h:
        result.add moved
    of shapeRect:
      result.add trimRectToLanes(shape.rect, shape.window, plan)
    else:
      # Polygons and diagonals still reject whole. The same argument says they
      # should be clipped -- a convex ring minus a horizontal band is at most
      # two convex rings, and a 45° run minus a band is at most two runs -- but
      # measuring it first showed WHY that is not a free change: rejection has
      # been acting as the fill layer's density regulator. Clipping them lifted
      # `caves` from 144/148/144/136/153/142 to 186/182/187/144/187/146 against
      # a 170 ceiling (4 of 6 seeds newly invalid), and `forest` and `plains`
      # the same way. The geometry fix is right; it has to land WITH a fill
      # density that was tuned against it, which lives in `mapgen_biomes`.
      discard


# ---------------------------------------------------------------------------
# k-FOLD DISJOINT BURROW — route count stops being MEASURED and is GUARANTEED
# ---------------------------------------------------------------------------
#
# `map_metrics.vertexDisjointRoutes` MEASURES how many independent flank routes
# a map has, and the shipped hard band is `routeCountMin >= 2` (control: the
# arena, 8.0). Everything above in this module is likewise measurement: carve,
# then check, then reroll if the check fails.
#
# It does not have to be that way. By MENGER'S THEOREM the maximum number of
# internally vertex-disjoint s-t paths equals the minimum s-t vertex cut. So
# if we can EXHIBIT k pairwise cell-disjoint corridors between two bases, the
# min-cut is >= k as a theorem — not as a measurement that might come back
# unlucky. Exhibiting them is the whole job:
#
#     dig a corridor, mark its cells used, dig again, k times.
#
# `burrow` already owns every piece: a `domain` mask to exclude cells from, a
# width-guaranteeing brush (`brushRadiusForCorridor` — stamping an L2 disc of
# radius r unions to a band exactly 2r+1 cells across), the wall/object cost
# ratios that make a dig prefer reusing corridor over cutting rock over
# bulldozing content, and `labelComponents` to certify the result.
#
# ---------------------------------------------------------------------------
# THE TRAP: THE PROOF MUST BE ON THE METRIC'S OWN GRID
# ---------------------------------------------------------------------------
#
# `burrow` is normally run at a fine cell size (8 px). The route metric counts
# disjointness at `RouteCellPx` = 26 px, one vertex per coarse cell. Two
# corridors that are disjoint on an 8 px grid can sit in the SAME 26 px cell —
# and then they are one vertex to the metric, the min-cut is 1 where we
# "proved" 2, and the guarantee is about a graph nobody measures.
#
# So `RouteGridCellPx` is pinned to `RouteCellPx` and the dig runs there. Cell
# indexing agrees too: `burrowGridFromPixels` and `map_metrics.buildCoarse`
# both index as `px div cell` from the origin, so cell (i,j) here IS cell
# (i,j) there. And the rasterisation difference points the safe way — burrow
# calls a cell passable only when EVERY pixel in it is clear, while the metric
# calls it open when ANY pixel is, so every cell this proof uses is a cell the
# metric also considers open.

const RouteGridCellPx* = 26
  ## MUST equal `map_metrics.RouteCellPx`. The disjointness certificate below
  ## is a statement about the graph whose vertices are cells of this size; at
  ## any other size it is a true statement about a graph the validator does
  ## not measure. Pinned by test.

type
  KRouteReport* = object
    ## The certificate. `ok` means k pairwise cell-disjoint corridors were
    ## exhibited, so by Menger the min cut is at least k.
    requested*, achieved*: int
    ok*: bool
    reason*: string
    cellSize*: int
    corridorWidthPx*: int
    routes*: seq[seq[BurrowPoint]]  ## centreline of each corridor, in cells
    wallCellsDug*: int
    disjoint*: bool                 ## verified, not assumed

proc digDisjointRoutes*(
  grid: var BurrowGrid, a, b: BurrowPoint, k: int,
  corridorWidthPx = RecommendedCorridorWidthPx,
  params = defaultBurrowParams(),
): KRouteReport =
  ## Dig `k` pairwise cell-disjoint corridors between two anchors, each at
  ## least `corridorWidthPx` wide, and return the certificate.
  ##
  ## Each pass is a Dial's bucket-queue shortest path under burrow's own cost
  ## model — reuse open floor (1) << cut rock (`WallCostRatio`) << bulldoze
  ## placed content (`ObjectCostRatio`) — so the first corridor follows what is
  ## already there and only later ones pay to cut new ground. A cell is
  ## eligible only when its WHOLE brush footprint is unused, which is what
  ## makes the stamped bands disjoint rather than merely their centrelines.
  result.requested = k
  result.cellSize = grid.cellSize
  result.corridorWidthPx = corridorWidthPx
  result.disjoint = true
  if k <= 0: 
    result.ok = true
    return
  if grid.cellSize != RouteGridCellPx:
    result.reason = "grid cell size " & $grid.cellSize & " != RouteCellPx " &
      $RouteGridCellPx & ": a disjointness proof here is about a graph the " &
      "route metric does not measure"
    return
  let
    w = grid.w
    h = grid.h
    n = w * h
  if not grid.onGrid(a.x, a.y) or not grid.onGrid(b.x, b.y):
    result.reason = "anchor off grid"
    return
  let brush = brushRadiusForCorridor(corridorWidthPx, grid.cellSize)

  # Routes may SHARE the immediate neighbourhood of each anchor, and must be
  # allowed to: every corridor starts at the same base cell, so retiring the
  # first corridor's brush footprint there walls the base in and pass 2 cannot
  # leave it. `map_metrics` makes the same allowance for the same reason --
  # it sources from each base's whole near neighbourhood so that the engine's
  # spawn-pocket mouth is never the answer. The certificate below excludes the
  # zone too, so nothing is proved about cells that were exempted.
  let anchorFree = brush + 1
  var anchorZone = newSeq[bool](n)
  for centre in [a, b]:
    for dy in -anchorFree .. anchorFree:
      for dx in -anchorFree .. anchorFree:
        let
          x = centre.x + dx
          y = centre.y + dy
        if grid.onGrid(x, y): anchorZone[y * w + x] = true

  var used = newSeq[bool](n)
  template footprintFree(cx, cy: int): bool =
    ## Whether the whole brush disc at this cell is unused and on-grid.
    var free = true
    for dy in -brush .. brush:
      for dx in -brush .. brush:
        if dx * dx + dy * dy > brush * brush: continue
        let
          x = cx + dx
          y = cy + dy
        if not grid.onGrid(x, y) or not grid.inDomain(x, y) or
            used[y * w + x]:
          free = false
    free

  func stepCost(cell: BurrowCell): int =
    case cell
    of bcFloor, bcContent: 1
    of bcWall: params.wallCost
    of bcObject: params.objectCost

  for pass in 0 ..< k:
    # --- Dial's over cells whose brush footprint is still free -------------
    let maxStep = max(params.wallCost, params.objectCost)
    var
      dist = newSeq[int32](n)
      prev = newSeq[int32](n)
      buckets = newSeq[seq[int32]](maxStep + 1)
    for i in 0 ..< n:
      dist[i] = int32.high
      prev[i] = -1
    let
      src = a.y * w + a.x
      dst = b.y * w + b.x
    dist[src] = 0
    buckets[0].add int32(src)
    var
      level = 0
      settled = 0
      pending = 1
    while settled < pending:
      let slot = level mod (maxStep + 1)
      while buckets[slot].len > 0:
        let i = int(buckets[slot].pop())
        if int(dist[i]) != level: continue
        inc settled
        if i == dst: break
        let x = i mod w
        for step in [-1, 1, -w, w]:
          if step == -1 and x == 0: continue
          if step == 1 and x == w - 1: continue
          let j = i + step
          if j < 0 or j >= n: continue
          let (jx, jy) = (j mod w, j div w)
          if not anchorZone[j] and not footprintFree(jx, jy): continue
          let nd = int32(level + stepCost(grid.cells[j]))
          if nd < dist[j]:
            if dist[j] == int32.high: inc pending
            dist[j] = nd
            prev[j] = int32(i)
            buckets[int(nd) mod (maxStep + 1)].add int32(j)
      inc level
      if level > n * maxStep + maxStep + 2: break
    if dist[dst] == int32.high:
      result.achieved = pass
      result.reason = "no " & $corridorWidthPx & "px route left after " &
        $pass & " disjoint corridor(s); the board cannot carry " & $k
      return

    # --- stamp the corridor and retire its cells --------------------------
    var route: seq[BurrowPoint]
    var cur = dst
    var guard = 0
    while cur >= 0 and guard <= n:
      route.add BurrowPoint(x: cur mod w, y: cur div w)
      if cur == src: break
      cur = int(prev[cur])
      inc guard
    for p in route:
      for dy in -brush .. brush:
        for dx in -brush .. brush:
          if dx * dx + dy * dy > brush * brush: continue
          let
            x = p.x + dx
            y = p.y + dy
          if not grid.onGrid(x, y) or not grid.inDomain(x, y): continue
          let i = y * w + x
          if grid.cells[i] == bcWall: inc result.wallCellsDug
          if not grid.cells[i].isPassable: grid.cells[i] = bcFloor
          if not anchorZone[i]: used[i] = true
    result.routes.add route
    result.achieved = pass + 1

  # --- verify the certificate rather than asserting it --------------------
  var seen = newSeq[int](n)
  for i in 0 ..< result.routes.len:
    for p in result.routes[i]:
      let idx = p.y * w + p.x
      if anchorZone[idx]: continue
      if seen[idx] != 0 and seen[idx] != i + 1: result.disjoint = false
      seen[idx] = i + 1
  result.ok = result.achieved == k and result.disjoint
  if not result.disjoint:
    result.reason = "corridors share a routing cell: not a Menger certificate"

proc guaranteeRouteCount*(
  wall: seq[bool], w, h: int, a, b: MapPoint, k: int,
  corridorWidthPx = RecommendedCorridorWidthPx,
): KRouteReport =
  ## THE pixel-space entry point: build the routing grid at the metric's own
  ## cell size and exhibit `k` disjoint corridors between two bases.
  ##
  ## The returned `routes` are cell centrelines; `cellRectPx` turns each into
  ## the pixel box a caller must keep clear, which is what a scene graph
  ## reserves BEFORE it places any cover.
  var grid = burrowGridFromPixels(w, h, RouteGridCellPx, wall)
  let
    ac = BurrowPoint(x: clamp(a.x div RouteGridCellPx, 0, grid.w - 1),
                     y: clamp(a.y div RouteGridCellPx, 0, grid.h - 1))
    bc = BurrowPoint(x: clamp(b.x div RouteGridCellPx, 0, grid.w - 1),
                     y: clamp(b.y div RouteGridCellPx, 0, grid.h - 1))
  digDisjointRoutes(grid, ac, bc, k, corridorWidthPx)

proc shapeRowSpan(shape: ArenaShape): tuple[y0, y1, x0, x1: int] =
  ## Conservative row/column extent of one shape. Radial kinds are shrunk by a
  ## quarter radius so a row is only claimed where the shape is actually solid
  ## across, not merely inside its bounding box.
  case shape.kind
  of shapeRect:
    (shape.rect.y, shape.rect.y + shape.rect.h - 1,
     shape.rect.x, shape.rect.x + shape.rect.w - 1)
  of shapeDisc:
    # Half the radius: a disc is only reliably solid ACROSS a row near its
    # equator, and claiming rows out to its poles reports a row blocked that
    # the real rasteriser leaves open.
    let r = shape.radius div 2
    (shape.cy - r, shape.cy + r, shape.cx - r, shape.cx + r)
  of shapeDiamond:
    # A diamond is an L1 ball: at cy +- r it is a single pixel. Claiming its
    # bounding box was what kept reporting row 288 as covered when it was not.
    let r = shape.radius div 3
    (shape.cy - r, shape.cy + r, shape.cx - r, shape.cx + r)
  of shapeDiagonal:
    (min(shape.y0, shape.y1), max(shape.y0, shape.y1),
     min(shape.x0, shape.x1), max(shape.x0, shape.x1))
  of shapePolygon:
    var (y0, y1, x0, x1) = (high(int), low(int), high(int), low(int))
    for p in shape.points:
      y0 = min(y0, p.y); y1 = max(y1, p.y)
      x0 = min(x0, p.x); x1 = max(x1, p.x)
    (y0, y1, x0, x1)

proc plugOpenRows*(
  shapes: seq[ArenaShape], plan: LanePlan, height, loX, hiX: int
): seq[ArenaShape] =
  ## Close every horizontal row that no obstacle blocks, CONSTRUCTIVELY.
  ##
  ## `arena`'s validator rejects a map outright if any row between the capture
  ## columns is unbroken ("open horizontal sightline at y="), and it is right
  ## to: with map-wide 1050 px guns, one open row is a gallery shot across the
  ## whole board. Chasing those rows by nudging separators is whack-a-mole --
  ## every fix here moved the failure to a new y and never removed it.
  ##
  ## So this is an INTERVAL COVER instead of a repair: take the union of the
  ## rows the obstacle set already blocks, and insert one picket into each row
  ## still uncovered. No budget to exhaust and no reroll, which is the whole
  ## difference between a construction and a repair.
  ##
  ## A picket has to go INSIDE a lane -- everywhere else is already blocked by
  ## the separator that made it a lane -- so it is placed hugging the lane
  ## edge and only where the lane can afford it, leaving `corridorMinPx` of
  ## clear channel. That is the same rule `clearLanes` keeps cover in a lane
  ## by, and it is why the tight flank never receives one.
  result = shapes
  if plan.lanes.len == 0 or height <= 0: return
  var blocked = newSeq[bool](height)
  for shape in shapes:
    let sp = shape.shapeRowSpan()
    if sp.x1 < loX or sp.x0 > hiX: continue
    for y in max(0, sp.y0) .. min(height - 1, sp.y1):
      blocked[y] = true
  const PicketW = 22
  let picketH = EngineMinCorridorPx
  var y = 0
  var stagger = 0
  while y < height:
    if blocked[y]:
      inc y
      continue
    # Find a lane that owns this row and can spare the width.
    var placed = false
    let span = max(1, plan.seamX - plan.laneStartX)
    # Try several x offsets, not one. A lane's centreline MOVES -- that is the
    # point of a profile -- so a single staggered x can easily land where this
    # row is outside the lane, and giving up there left rows open in the
    # middle of a lane wide enough to have taken a picket.
    block place:
     for attempt in 0 ..< 8:
      for lane in plan.lanes:
        if lane.widthPx - PicketW < plan.corridorMinPx: continue
        let
          px = plan.laneStartX +
            ((stagger + attempt) * 137) mod max(1, span - PicketW)
          cy = lane.laneY(px)
          half = lane.widthPx div 2
        if y < cy - half or y > cy + half: continue
        let py = if y < cy: cy - half else: cy + half - picketH
        # Cover the row that PROMPTED the picket, not merely the rows the
        # picket happens to span -- a picket pushed to the far lane edge can
        # miss its own trigger row, and then `y` never advances.
        let lo = min(py, y)
        let hi = max(py + picketH - 1, y)
        result.add ArenaShape(kind: shapeRect, rect: MapRect(
          x: px, y: py, w: PicketW, h: picketH))
        for yy in max(0, lo) .. min(height - 1, hi):
          blocked[yy] = true
        inc stagger
        placed = true
        break place
    if not placed:
      # No lane owns this row: it lies in a separator band or a margin, where
      # a picket costs nothing because that ground is already structure. This
      # is the case the lane-only version missed -- the failing row was always
      # y=104, in the margin between the top separator's sweep and the flank
      # lane, which no lane could ever claim.
      let
        span = max(1, plan.seamX - plan.laneStartX)
        px = plan.laneStartX + (stagger * 137) mod max(1, span - PicketW)
        candidate = ArenaShape(kind: shapeRect, rect: MapRect(
          x: px, y: y, w: PicketW, h: picketH))
      if not plan.intrudesOnLane(candidate):
        result.add candidate
        for yy in y .. min(height - 1, y + picketH - 1):
          blocked[yy] = true
        inc stagger
    inc y

proc carveLanes*(
  rng: var Rand, region: MapRect, base: MapPoint, seamX: int,
  rules: MapRules, cover: seq[ArenaShape] = @[]
): tuple[shapes: seq[ArenaShape], plan: LanePlan] =
  ## THE CALL a scene graph makes. Plans the route network, emits the
  ## structure that makes it real, and reconciles whatever cover a style
  ## generator produced with the lanes it has to leave open.
  let plan = planLanes(rng, region, base, seamX, rules)
  var shapes = laneSeparatorShapes(plan)
  shapes.add laneGateShapes(plan)
  shapes.add clearLanes(cover, plan)
  shapes = plugOpenRows(shapes, plan, region.y + region.h,
    region.x, plan.seamX)
  (shapes, plan)
