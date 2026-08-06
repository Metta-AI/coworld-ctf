## map_metrics — the fitness measuring stick for CTF maps.
##
## This module is the MEASURING STICK, built before anything changes what it
## measures. It answers one question about a `CtfMap`: is this an interesting,
## fair, *architectural* board, or is it scatter on a field?
##
## Three rules this file is built around, each learned by producing a
## confidently wrong number:
##
## 1. **The control is always scored.** Every metric here runs on the
##    hand-authored `arena` exactly as it runs on a generated map. A metric
##    that flags the control is wrong; a metric that SKIPS the control is
##    worse, because then nothing ever catches it. `tools/map_eval.nim`
##    enforces this structurally by prepending `arena` to every batch — this
##    module makes it possible by never special-casing a layout.
## 2. **No count without its fraction.** A count cannot distinguish "one
##    narrow doorway" from "one enormous gap": both score 1. Every count-shaped
##    field here (`midCrossCount`, `standRingArcs`, `chokeCount`) ships next to
##    the fraction that disambiguates it (`midOpenFrac`, `standRingOpen`,
##    `chokeMinClearPx`).
## 3. **Reuse the sim's geometry, never reimplement it.** Walls come from
##    `rasterizeWallMasks` via `mapDiagnostics`; the corridor erosion and the
##    reachability flood are the validator's own. This module adds analysis on
##    top of those masks and owns no geometry of its own.
##
## PURITY: like `tools/map_render.nim`, every proc here is a pure function of
## its `CtfMap` argument. Nothing installs a map, nothing reads the process
## globals (`MapWidth`, `ArenaObstacles`, `obstacleWallAtF`, …). A ranker may
## therefore call `evaluateMap` from a thread pool or inside a best-of-K loop.
##
## WHICH MASK: the two wall masks point in opposite directions (a spinning
## diamond is not one shape), and this module follows the validator's own
## convention exactly —
##   * `maxWall` (swept union, MORE wall) for structure: cover, enclosure,
##     stand cover, collision-point density. A shape that is there at any
##     frame counts as architecture.
##   * `minWall` (always-stone, LESS wall) for vision: open runs, isovists,
##     the visibility graph. A firing lane that opens at any frame IS an open
##     lane.
##   * `corridorOpen` (the validator's player-width erosion) for movement:
##     routes, chokepoints, detour, the collision frontier.
##
## DO THESE MASKS DESCRIBE WHAT THE ENGINE ACTUALLY COLLIDES WITH? Measured,
## yes — which is the fact that makes every number below mean anything. The
## engine's `walkMask`/`wallMask` come from the art BAKE (sim.nim, via
## `loadMapLayers`), not from these procs, so the question is real. But the
## bake calls `rasterizeRestWallMask` itself and its masking composition
## reduces to `includeSpinning = false`; `tools/mask_parity_probe.nim` (added
## by the map-art work) measures zero mismatched pixels against the baked
## collision mask across arena, arena-large and five generated seeds spanning
## three size classes. Window glass needs no special case — it sits on the WALL
## side of both. So for every non-spinning pixel the geometry scored here IS
## the shipped collision geometry.
##
## Spinning diamonds are the one exception, and are why this module brackets
## rather than picks: the bake EXCLUDES them (their rotation is stamped per
## frame and resolved by `animatedDiamondCovers` at query time), so no single
## static mask is the truth for those pixels. `minWall` and `maxWall` are the
## floor and ceiling over a full turn, and each metric above takes whichever
## one is pessimistic for what it measures.
##
## The single weighted scalar is `staticScore`. It is deliberately a thin
## weighted sum of banded sub-scores so a downstream ranker can re-weight
## without re-deriving anything, and so `bandReport` can print how much slack
## is left at every bound (rule 5: thresholds are calibrated against the
## control, and "tight" is printed rather than silently spent).

import std/[algorithm, math, strformat, strutils]
import sim_types, arena
# `map_lanes` for the length-aware pinch predicate ONLY. It deliberately does
# not import `arena` (that would be a cycle), so the dependency can point this
# way and the chokepoint length is the same number the corridor rule uses
# rather than a second implementation of it.
import map_lanes

# ---------------------------------------------------------------------------
# Tunables. Every bound is calibrated against the hand-authored arena; see
# `docs`-free notes on each const and the `Band` table at the bottom.
# ---------------------------------------------------------------------------

const
  EnclosureReachPx* = 120
    ## How far a direction is probed for wall when scoring how enclosed a
    ## piece of floor is. Ported verbatim from mw2_structure.py's `enclosure`,
    ## where 120px separated "a room" from "a crate" across seven maps.
  InteriorBlockedMin* = 6
    ## Of 8 directions, how many must be blocked within reach for the floor to
    ## count as INTERIOR. 0-2 is open field, 3-5 is cover or a corridor, 6+ is
    ## an alcove/room/interior.
  CoveredBlockedMin* = 3
  ExposedBlockedMax* = 1
  LongRunPx* = 600
    ## An open run longer than this is a gallery shot. Hand-picked, and it
    ## survives the lethality audit by luck rather than derivation: the derived
    ## figure is `2 * LethalEnvelopePx` = 518 px (a lane in which two players
    ## can engage from opposite ends and neither can leave), which 600 clears
    ## by 16%. Left where it is because every band below is calibrated on it;
    ## noted here so the next person does not have to re-derive it.
  SightlineCapPx* = GunRange
    ## THE HARD CAP on an unbroken open line, on any of the four scan axes.
    ##
    ## This is the arena validator's own horizontal rule, said as a LENGTH
    ## instead of as a crossing. That rule rejects a ray only when it clears
    ## the entire `sightlineLoX .. sightlineHiX` band — which is 805 px wide on
    ## a column-endzone map but 1205 px on a compact-endzone one, so the
    ## effective cap moved with the endzone shape and on half the pool ended up
    ## WIDER THAN THE GUN. Four curated pool seeds ship an open row longer than
    ## `GunRange` and every one of them passes today.
    ##
    ## A lane longer than the gun's own reach cannot be contested from either
    ## end, which is the thing "with map-wide guns no straight ray may survive"
    ## was reaching for.
  StandCoverRadiusPx* = 200
    ## The cover budget that decides whether a stolen flag can be defended.
  StandCoverFloorPermille* = 15
    ## THE ABSOLUTE stand-side cover floor, as permille of the 200px disc.
    ##
    ## Until this existed the objective carried only a fairness SPREAD, and a
    ## spread cannot express a floor: two equally NAKED stands both score a
    ## spread of 0 and pass. This is the one causally-established property in
    ## the suite, and it was the one going unenforced.
    ##
    ## Calibrated as a NAKEDNESS detector, not a quality bar — see the band's
    ## note for why the fraction cannot carry a quality bar at all.
  RouteCellPx* = 26
    ## Coarse routing cell. Mirrors arena.nim's (unexported) MinCorridorWidth
    ## = 26, the narrowest corridor the 13px player footprint can use, so one
    ## min-cut cell IS one minimum-width corridor and `cut * RouteCellPx` is a
    ## bottleneck in px.
  ChokeMaxClearPx* = 90
    ## Floor wider than this is not a doorway, whatever the topology says.
  ChokeCandidateCap* = 1500
    ## Ceiling on how many narrow cells get the (linear) cut test, taken
    ## narrowest-first. Bounds a giant board's cost without changing the answer
    ## on any board small enough to test exhaustively.
  IsovistRangePx* = LethalEnvelopePx
    ## 259px. The range cap on the "can one vantage point watch every
    ## chokepoint" test.
    ##
    ## THIS WAS `GunRange` = 1050 AND WAS THEREFORE ABOUT 4x TOO WIDE. Gun range
    ## is a REACH, not an engagement range: aim is 32 discrete slots 11.25 deg
    ## apart with no aim assist, a shot is accepted against the 13px SOLID body,
    ## and the jitter sigma is 9.4x smaller than the half-slot — so the LATTICE
    ## decides, and `P(hit)` is 0.47 at 300px and 0.14 at gun range, where TTK
    ## is over ten seconds and nobody is fighting. Covering a chokepoint means
    ## being able to KILL into it; a camper who can see a doorway 900px away and
    ## cannot hit anyone standing in it is not covering it.
    ##
    ## `map_rules.LethalEnvelopePx` carries the derivation and the three
    ## independent constants that converge on it (FieldAccuracyPct is achieved
    ## at 259px; `GrenadeMaxRange` = `GunRange div 4` = 262px; the observed
    ## 1.0-1.9s TTK band implies 142-225px). `ChokepointSpacingPx` and
    ## `MinPickupSpacingPx` were already moved onto it — this metric was the
    ## straggler.
    ##
    ## DIRECTION OF THE CHANGE, stated because it is the counter-intuitive one:
    ## a SMALLER isovist makes the "one camper owns every route" penalty fire
    ## LESS often, not more. That is correct. The old radius was flagging maps
    ## whose chokepoints merely fell in one field of view.
  VisionPairRangePx* = GunRange
    ## The pair cutoff for the visibility graph, deliberately still on the
    ## AWARENESS axis: that graph asks who can SEE whom, and the answer changes
    ## how a player reads a board even where they cannot shoot. The lethal-range
    ## twin is measured alongside it (`visLethalDegree*`) and is the one to read
    ## for any density or encounter claim — see the audit note on `MapMetrics`.
  LosStridePx* = 3
    ## Line-of-sight sampling stride. Finer than the thinnest wall feature
    ## (12px), the same rule `rectOnOpenFloor` samples by.
  VisibilitySampleCap* = 400
    ## Cap on visibility-graph sample points, so a giant board costs the same
    ## as a standard one. Degree is reported as a FRACTION of samples for
    ## exactly this reason.

# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------

type
  MapMetrics* = object
    ## Static fitness of one map. Pure function of a `CtfMap`.
    ##
    ## Downstream (best-of-K ranker, structure pass, biome layer) should call
    ## `evaluateMap` and read these fields; `staticScore` collapses them to a
    ## single [0,1] scalar and `bandReport` explains the collapse.
    name*: string                 ## caller-supplied label ("arena", "gen:1003")
    width*, height*: int
    teams*: int
    layout*: string               ## $gameMap.layout
    symmetry*: string             ## $gameMap.symmetry
    endzone*: string              ## $gameMap.endzone
    valid*: bool                  ## validateGeneratedMap passed
    reason*: string               ## first validator failure, "" when valid

    # --- cover (the validator's own budget, echoed so one report has both) ---
    coverPermille*, minCoverPermille*: int
    openFloorPx*: int             ## non-maxWall pixels inside the border

    # --- architecture: the scatter-vs-buildings discriminator ---------------
    interiorFrac*: float          ## open floor with >= 6 of 8 dirs blocked @120px
    coveredFrac*: float           ## >= 3 of 8
    exposedFrac*: float           ## <= 1 of 8

    # --- vision -------------------------------------------------------------
    # EVERY open run below is measured BETWEEN OCCUPIABLE ENDS: the ray must
    # cross no `minWall`, and its two endpoints must both be `corridorOpen`,
    # i.e. floor a player can actually stand on. A line nobody can stand at
    # either end of is not a firing lane.
    #
    # Every board carries a ~10px strip between the border ring's inner edge
    # and the first floor a body can occupy, and it runs unbroken around the
    # whole map — so before this condition the longest run on EVERY map,
    # including both controls, was seeded in it: `arena`'s longest row at
    # y = 10, its longest column at x = 10, its longest diagonal from (12,10).
    #
    # HOW MUCH IT MOVED, because the honest answer is "less than the seeding
    # suggested": those runs are ANCHORED in the gutter but they travel through
    # real playfield, so trimming the unoccupiable tails costs 3-4%, not the
    # whole number. arena 663 -> 638 px row and 790 -> 758 px diagonal;
    # arena-large 868 -> 843 and 1185 -> 1149. The condition matters because it
    # makes the number mean what it says — NOT because it was hiding a lane,
    # and anyone re-deriving a bound here should expect a trim, not a cliff.
    openRunP50Px*, openRunP95Px*, openRunMaxPx*: int
    longRunFrac*: float           ## share of axis runs over LongRunPx
    longRunPxFrac*: float
      ## Share of scanned open PIXELS lying on a run over LongRunPx.
      ##
      ## The count-share above cannot be compared between the axis and diagonal
      ## scans, and that is not a nuance — it is the reason the diagonal
      ## measurement could not gate. The diagonal scan emits a run for every one
      ## of the ~2(w+h) diagonals, most of them short corner clips, so the same
      ## board reads 11.0% long by axis count and 0.2% by diagonal count while
      ## its longest diagonal is LONGER than its longest row. Weighting by pixel
      ## makes the two scans the same measurement and makes both scale-free.
    clearP50Px*, clearP95Px*: int ## distance transform over open floor
    sightlineMaxPx*: int
      ## The longest open run found on ANY of the four scan axes — rows,
      ## columns and both diagonals — the single number `SightlineCapPx` gates.
    sightlineAxis*: string        ## which axis carried it, for a caller to look
    sightlineX*, sightlineY*: int ## and where it starts
    diagRunP95Px*, diagRunMaxPx*: int
      ## The SAME open-run scan along both 45-degree diagonals, length scaled
      ## to px by sqrt(2) per step. Reported SEPARATELY from the axis runs on
      ## purpose: every band above is calibrated against the hand-authored
      ## arena's AXIS numbers, so folding diagonals into that histogram would
      ## move every bound and the control with it, which is not a measurement.
      ##
      ## Why it exists: the axis scan is blind to a diagonal sightline of ANY
      ## length. That was harmless while every obstacle was an axis-aligned
      ## rect on a column lattice, but GV37 added polygon obstacles and every
      ## generator now under construction (Voronoi cells, thresholded noise,
      ## organic massifs) produces non-axis-aligned geometry. A diagonal
      ## sniping lane would score PERFECTLY under the axis scan alone — so a
      ## generator optimised against it would be rewarded for building one.
      ## Measure the hole first; fold it into the gate only once we know what
      ## the control actually scores.
      ##
      ## THE HOLE IS NOW MEASURED AND THE ANSWER WAS NOT THE OBVIOUS ONE. The
      ## diagonal really is the longest line on both controls (arena 790px vs
      ## 663px axis; arena-large 1185px vs 868px) — but every one of those runs
      ## was seeded in the border gutter, and once runs are measured between
      ## occupiable ends the picture changes. Read `diagLongRunPxFrac`, which is
      ## the gated form; the count-share below is kept only because it is what
      ## the axis band was historically calibrated on.
    diagLongRunFrac*: float       ## share of DIAGONAL runs over LongRunPx
    diagLongRunPxFrac*: float     ## the pixel-weighted twin: the gated form

    # --- routes (vertex-disjoint max-flow per base pair) --------------------
    routeCountMin*, routeCountMax*: int
    routeCountMean*: float
    routeCapacityFrac*: float
      ## routeCountMin as a fraction of the board's short side in cells: the
      ## scale-free form. A giant board carries more absolute capacity than a
      ## small one for reasons that have nothing to do with its architecture,
      ## so the raw count cannot be banded across size classes and this can.
    bottleneckPx*: int            ## routeCountMin * RouteCellPx
    bottleneckX*, bottleneckY*: int  ## centroid of the tightest min-cut

    # --- chokepoints --------------------------------------------------------
    chokeCount*: int
    chokeMinClearPx*: int
    chokeX*, chokeY*: seq[int]    ## where each one is, so a caller can look
    chokeCovered*: bool           ## ONE 259px isovist sees every chokepoint
    chokeCoverX*, chokeCoverY*: int
    chokeCoveredAtGunRange*: bool
      ## The same test at the OLD 1050px radius, kept so the ~4x re-cut is a
      ## printed before/after rather than a claim. Reported, never gated.

    # --- chokepoint PINCH LENGTH (map_lanes.auditCorridorPinches) -----------
    # A 40px doorway and a 40 x 400px shooting gallery are the same chokepoint
    # to a detector that only measures WIDTH, and until these fields existed
    # they scored identically. The length-aware predicate lives in `map_lanes`
    # and is reused here rather than reimplemented (rule 3).
    routeWidthPx*: int
      ## The widest sustained corridor the map delivers between bases. READ
      ## THIS FIRST when a pinch overruns: a board whose route width is 26px
      ## does not have a chokepoint problem, it has no corridors.
    pinchGateCount*: int          ## gates found across all independent routes
    pinchMandatoryCount*: int     ## the subset that are genuine, unavoidable cuts
    chokeExposedPx*: int
      ## The worst UNBROKEN SIGHTLINE a mandatory pinch holds a player in.
      ## Exposure, not arc length: a passage that bends resets the defender's
      ## clock at every corner, and gating on walked length rejects the
      ## hand-authored arena.
    chokeAllowedPx*: int          ## `maxPinchRunPx` at that pinch's own width
    chokeExcessPx*: int
      ## `chokeExposedPx - chokeAllowedPx`. Positive is a kill box: an
      ## unavoidable pinch longer than a player can clear alive at its width.
      ## THE gated quantity — 0 when the map has no mandatory pinch at all.

    # --- the collision point: where a multi-source race from all N bases meets
    collisionX*, collisionY*: int
    collisionCoverFrac*: float
    collisionCoverRatio*: float   ## vs the map's own average cover
    collisionRoutes*: int         ## distinct frontier components
    collisionSpreadPx*: int

    # --- the objective, per team -------------------------------------------
    standCover*: seq[float]       ## wall fraction within 200px of each stand
    standCoverMin*, standCoverMax*: float
    standCoverGapPx*: seq[int]
      ## Distance from each stand to the NEAREST cover a carrier could break
      ## line of sight behind, ignoring the board's own border ring. Capped at
      ## `StandCoverRadiusPx + 1` when the disc holds no cover at all.
      ##
      ## This is the scale-free form of the same property, and it is the one
      ## with causal force: `MaxExposedRunPx` = 132px is how far a player
      ## travels while a shooter kills them, so a stand whose nearest cover is
      ## further than that is a stand a carrier cannot leave alive. The area
      ## FRACTION cannot say this — halve every obstacle's spacing and the
      ## fraction is unchanged.
    standCoverGapMaxPx*: int      ## the worst-served stand
    standRingOpen*: seq[float]    ## open fraction of the ring around each stand
    standRingArcs*: seq[int]      ## distinct walkable approaches
    standRingOpenMin*, standRingOpenMax*: float

    # --- midfield -----------------------------------------------------------
    midCrossCount*: int           ## distinct ways across the TIGHTEST cut line
    midOpenFrac*: float           ## how much of that cut line is open at all
    midAxisVertical*: bool
    midSeamAt*: int               ## where that tightest cut line sits, px

    # --- shape of the route set --------------------------------------------
    detourMin*, detourMax*, detourMean*: float

    # --- visibility graph ---------------------------------------------------
    # AUDIT NOTE, since this is the other place a range constant sets a
    # density: the graph below is cut at `VisionPairRangePx` = GunRange, which
    # is the AWARENESS axis and is the right axis for "how evenly is this board
    # seen". Any claim about ENCOUNTERS or LETHAL contact must be read off the
    # `visLethalDegree*` twin instead — `2 * lambda` is 4x `EngagementWidthPx`,
    # so an encounter law computed on sightlines overstates lethal contact
    # ~16x. The twin is reported and not banded, for one honest reason: the
    # sample stride grows with the board to hold the sample cap, so on a giant
    # board a 259px cut leaves each sample only a handful of in-range partners
    # and its CV is sampling noise. Fixing that needs a range-tied stride,
    # which is a separate change.
    visSamples*: int
    visDegreeMean*: float
    visDegreeFrac*: float         ## mean degree / (samples - 1): scale-free
    visDegreeP10*, visDegreeP90*: float
    visDegreeCv*: float           ## std/mean — how uneven exposure is
    visSampleStridePx*: int       ## what the cap forced; read it before the CV
    visLethalDegreeMean*: float   ## the same graph cut at LethalEnvelopePx
    visLethalDegreeFrac*: float
    visLethalDegreeCv*: float

  MapPlay* = object
    ## DYNAMIC fitness, merged over >= 3 episodes. Populated by the playtest
    ## side (`tools/map_playtest.nim`), not by `evaluateMap`.
    episodes*: int
    ticks*: seq[int]              ## per-episode length; rule 4 needs each one
    captures*: seq[int]           ## per-episode captures; a capture ENDS it
    balanceEntropy*: float        ## [0,1], log base = team count
    pace*: float                  ## scoring events per 1000 ticks
    fightTimeFrac*: float         ## share of alive-seat-ticks within gun range
    deadFloorFrac*: float
    biggestDeadPx*: int

  BandKind* = enum
    bandHard                      ## outside => the map is REJECTED
    bandSoft                      ## outside => the map scores badly

  Band* = object
    ## One named threshold plus its calibration provenance, so a bound can
    ## never drift away from the control that justified it.
    name*: string
    lo*, hi*: float               ## the acceptable interval
    margin*: float                ## how far outside before the sub-score is 0
    weight*: float
    kind*: BandKind
    control*: float               ## the arena's measured value
    note*: string

  BandResult* = object
    band*: Band
    value*: float
    sub*: float                   ## [0,1]
    tight*: bool                  ## within 15% of a bound's span from an edge
    breached*: bool

# ---------------------------------------------------------------------------
# Small numeric helpers
# ---------------------------------------------------------------------------

proc percentileOf(hist: seq[int], total: int, q: float): int =
  ## The q-quantile of a value histogram indexed by the value itself.
  if total <= 0: return 0
  let want = max(1, int(ceil(q * total.float)))
  var seen = 0
  for value in 0 ..< hist.len:
    seen += hist[value]
    if seen >= want:
      return value
  hist.len - 1

proc percentileOf(values: seq[float], q: float): float =
  if values.len == 0: return 0.0
  var sorted = values
  sorted.sort()
  let i = clamp(int(floor(q * float(sorted.len - 1) + 0.5)), 0, sorted.len - 1)
  sorted[i]

proc balanceEntropy*(counts: openArray[int], teams: int): float =
  ## B = -sum (k_i / K) log_N (k_i / K), with log base N = TEAM COUNT so the
  ## result is [0,1] for 2 / 3 / 4 / 6 teams alike. 1.0 is a perfectly even
  ## split; 0.0 is one team taking everything. Zero when nothing happened.
  if teams < 2: return 0.0
  var total = 0
  for k in counts:
    total += max(0, k)
  if total <= 0: return 0.0
  let lnN = ln(teams.float)
  for k in counts:
    if k > 0:
      let p = k.float / total.float
      result -= p * ln(p) / lnN
  result = clamp(result, 0.0, 1.0)

# ---------------------------------------------------------------------------
# Line of sight over a wall mask (pure; the caller picks the mask)
# ---------------------------------------------------------------------------

proc losClear*(
  mask: seq[bool], w, h, x0, y0, x1, y1: int, stride = LosStridePx
): bool =
  ## True when the open segment between two pixels crosses no wall. Sampled at
  ## `stride` px — finer than the thinnest wall feature — with both endpoints
  ## excluded so a vantage standing ON cover still sees out.
  let
    dx = x1 - x0
    dy = y1 - y0
    span = max(abs(dx), abs(dy))
  if span == 0: return true
  let steps = max(1, span div stride)
  for i in 1 ..< steps:
    let
      x = x0 + dx * i div steps
      y = y0 + dy * i div steps
    if x < 0 or y < 0 or x >= w or y >= h: return false
    if mask[y * w + x]: return false
  true

# ---------------------------------------------------------------------------
# Enclosure — ported from mw2_structure.py's `enclosure()`
# ---------------------------------------------------------------------------

proc axisWalk(a, b, step: int): seq[int] =
  ## The scan order for one enclosure direction. Built 16 times per map, not
  ## per pixel, so the allocation is not in any hot path.
  var v = a
  if step > 0:
    while v <= b:
      result.add v
      v += step
  else:
    while v >= b:
      result.add v
      v += step

proc enclosureCounts(
  wall: seq[bool], w, h, reach: int
): tuple[blocked: seq[uint8], openPx: int] =
  ## Of 8 directions, how many are blocked by wall within `reach` px, per open
  ## pixel.
  ##
  ## Connectivity is the wrong tool for this and produced a number that flagged
  ## the control: floor inside a building is still perfectly REACHABLE through
  ## its door, and the map's own border frame makes every open pixel unable to
  ## reach the image edge — so a flood-based measure reports one room covering
  ## the whole playfield on every map, arena included. What distinguishes a
  ## room is being surrounded AT SHORT RANGE, which is local, not topological.
  ##
  ## numpy rolls the mask `reach` times per direction; that is 8*reach passes
  ## over the board and is unaffordable on a giant map. The same answer comes
  ## from one scan per direction carrying "steps to the next wall along this
  ## ray", which is O(8 * w * h) total.
  var
    blocked = newSeq[uint8](w * h)
    steps = newSeq[int32](w * h)
    openPx = 0
  const dirs = [(1, 0), (-1, 0), (0, 1), (0, -1),
                (1, 1), (1, -1), (-1, 1), (-1, -1)]
  let far = int32(reach + 1)
  for d in dirs:
    let (dx, dy) = d
    # Walk so that (x+dx, y+dy) is always already resolved.
    let
      ys = if dy > 0: axisWalk(h - 1, 0, -1) else: axisWalk(0, h - 1, 1)
      xs = if dx > 0: axisWalk(w - 1, 0, -1) else: axisWalk(0, w - 1, 1)
    for y in ys:
      for x in xs:
        let
          nx = x + dx
          ny = y + dy
          i = y * w + x
        if nx < 0 or ny < 0 or nx >= w or ny >= h:
          steps[i] = far
        elif wall[ny * w + nx]:
          steps[i] = 1
        else:
          steps[i] = min(far, steps[ny * w + nx] + 1)
        if steps[i] <= int32(reach) and not wall[i]:
          inc blocked[i]
  for i in 0 ..< w * h:
    if not wall[i]:
      inc openPx
  (blocked, openPx)

# ---------------------------------------------------------------------------
# Coarse routing grid
# ---------------------------------------------------------------------------

type
  Coarse = object
    gw, gh, cell: int
    open: seq[bool]
    clearPx: seq[int]        ## widest clearance inside the cell, px
    repX, repY: seq[int]     ## that widest pixel: the cell's medial-axis point

proc cellX(g: Coarse, i: int): int = g.repX[i]
proc cellY(g: Coarse, i: int): int = g.repY[i]

iterator neighbours4(g: Coarse, i: int): int =
  let
    cx = i mod g.gw
    cy = i div g.gw
  if cx > 0: yield i - 1
  if cx < g.gw - 1: yield i + 1
  if cy > 0: yield i - g.gw
  if cy < g.gh - 1: yield i + g.gw

proc buildCoarse(
  corridor: seq[bool], dist: seq[int32], w, h, cell: int
): tuple[g: Coarse, adj: seq[seq[int]]] =
  ## An EXACT coarsening of the player-width floor: a cell is open when it
  ## holds any corridor-open pixel, and two cells are adjacent when two
  ## corridor-open pixels straddle their shared edge. So the coarse graph is
  ## connected exactly where the pixel graph is.
  ##
  ## The obvious alternative — sample each cell's geometric CENTER and join
  ## neighbours whose connecting segment is clear — is wrong, and it is wrong
  ## in the way that flags the control. On the arena it shattered the board
  ## into 24 components with the two bases in different ones, because the
  ## arena's passages run between pickets ~48px apart and a fixed 26px lattice
  ## simply misses them. That reports "0 routes" for a map the sim's own flood
  ## fill has already certified as connected, which is the same class of
  ## failure as the earlier lane metric that reported ONE route for every
  ## layout including the arena.
  ##
  ## Each cell also keeps a REPRESENTATIVE pixel: its widest corridor-open
  ## pixel, i.e. its point on the medial axis. Chokepoint clearance, isovist
  ## rays and the collision point all read that instead of the geometric
  ## center, so a cell that is mostly wall reports the place a player can
  ## actually stand.
  var g = Coarse(cell: cell, gw: max(1, (w + cell - 1) div cell),
                 gh: max(1, (h + cell - 1) div cell))
  let n = g.gw * g.gh
  g.open = newSeq[bool](n)
  g.clearPx = newSeq[int](n)
  g.repX = newSeq[int](n)
  g.repY = newSeq[int](n)
  for y in 0 ..< h:
    for x in 0 ..< w:
      if not corridor[y * w + x]: continue
      let
        i = (y div cell) * g.gw + (x div cell)
        clear = int(dist[y * w + x]) div 3
      if not g.open[i] or clear > g.clearPx[i]:
        g.clearPx[i] = clear
        g.repX[i] = x
        g.repY[i] = y
      g.open[i] = true
  var adj = newSeq[seq[int]](n)
  var linked = newSeq[bool](n * 2)   ## [cell*2 + axis] : edge already added
  for y in 0 ..< h:
    for x in 0 ..< w:
      if not corridor[y * w + x]: continue
      let i = (y div cell) * g.gw + (x div cell)
      if x + 1 < w and corridor[y * w + x + 1]:
        let j = (y div cell) * g.gw + ((x + 1) div cell)
        if j != i and not linked[i * 2]:
          linked[i * 2] = true
          adj[i].add j
          adj[j].add i
      if y + 1 < h and corridor[(y + 1) * w + x]:
        let j = ((y + 1) div cell) * g.gw + (x div cell)
        if j != i and not linked[i * 2 + 1]:
          linked[i * 2 + 1] = true
          adj[i].add j
          adj[j].add i
  (g, adj)

proc nearestOpenCell(g: Coarse, px, py: int): int =
  ## The open coarse cell nearest a map point, or -1. Bases sit inside
  ## protected floor, which is always corridor-open, but a base whose exact
  ## center falls in an unsampled cell corner must still find its cell.
  let
    cx = clamp(px div g.cell, 0, g.gw - 1)
    cy = clamp(py div g.cell, 0, g.gh - 1)
  if g.open[cy * g.gw + cx]: return cy * g.gw + cx
  for radius in 1 .. 8:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        if max(abs(dx), abs(dy)) != radius: continue
        let
          x = cx + dx
          y = cy + dy
        if x < 0 or y < 0 or x >= g.gw or y >= g.gh: continue
        if g.open[y * g.gw + x]: return y * g.gw + x
  -1

proc bfsCells(adj: seq[seq[int]], start: int): seq[int] =
  ## Hop distance over the coarse graph; -1 where unreachable.
  result = newSeq[int](adj.len)
  for i in 0 ..< result.len: result[i] = -1
  if start < 0: return
  result[start] = 0
  var queue = @[start]
  var head = 0
  while head < queue.len:
    let i = queue[head]
    inc head
    for j in adj[i]:
      if result[j] < 0:
        result[j] = result[i] + 1
        queue.add j

# ---------------------------------------------------------------------------
# Unit-capacity vertex-disjoint max flow (Dinic)
# ---------------------------------------------------------------------------

type
  FlowEdge = object
    to, cap, rev: int
  FlowNet = object
    adj: seq[seq[FlowEdge]]

proc addEdge(net: var FlowNet, u, v, cap: int) =
  net.adj[u].add FlowEdge(to: v, cap: cap, rev: net.adj[v].len)
  net.adj[v].add FlowEdge(to: u, cap: 0, rev: net.adj[u].len - 1)

proc bfsLevel(net: FlowNet, s, t: int, level: var seq[int]): bool =
  for i in 0 ..< level.len: level[i] = -1
  level[s] = 0
  var queue = @[s]
  var head = 0
  while head < queue.len:
    let u = queue[head]
    inc head
    for e in net.adj[u]:
      if e.cap > 0 and level[e.to] < 0:
        level[e.to] = level[u] + 1
        queue.add e.to
  level[t] >= 0

proc dfsFlow(
  net: var FlowNet, u, t, pushed: int, level: seq[int], iter: var seq[int]
): int =
  if u == t: return pushed
  while iter[u] < net.adj[u].len:
    let e = net.adj[u][iter[u]]
    if e.cap > 0 and level[e.to] == level[u] + 1:
      let got = net.dfsFlow(e.to, t, min(pushed, e.cap), level, iter)
      if got > 0:
        net.adj[u][iter[u]].cap -= got
        net.adj[e.to][e.rev].cap += got
        return got
    inc iter[u]
  0

proc maxFlow(net: var FlowNet, s, t: int): int =
  var level = newSeq[int](net.adj.len)
  while net.bfsLevel(s, t, level):
    var iter = newSeq[int](net.adj.len)
    while true:
      let got = net.dfsFlow(s, t, high(int), level, iter)
      if got == 0: break
      result += got

const FlowInf = 1_000_000

proc vertexDisjointRoutes(
  g: Coarse, adj: seq[seq[int]], srcSet, dstSet: seq[int]
): tuple[flow: int, cutX, cutY: int] =
  ## Independent flank routes between two base APPROACHES, and the centroid of
  ## the min cut that limits them.
  ##
  ## Each cell splits into in/out nodes joined by a capacity-1 edge, so a cut
  ## is a set of CELLS rather than a set of edges. That is the whole point: an
  ## edge cut on a grid is meaningless (you can always slip diagonally past
  ## it), and the earlier "find a path, wall it off, find another" formulation
  ## reported ONE route for every layout including the arena — the classic sign
  ## that a metric has stopped measuring the thing.
  ##
  ## The endpoints are SETS, not the two pedestals, and that is not a detail.
  ## Run pedestal-to-pedestal and the answer is 4 for the arena and 4 for 19 of
  ## the 20 curated pool seeds, because the tightest vertex cut is always the
  ## mouth of the engine's own protected spawn pocket — a fixed piece of
  ## geometry that no map author controls. A metric that returns the same
  ## number for every layout is measuring the engine, not the map. Sourcing
  ## from each base's whole near neighbourhood cuts the pocket out of the
  ## question and leaves the midfield, which is the part a map decides.
  ##
  ## Flow is in CELLS, not lanes: a 78px-wide corridor carries 3 units through
  ## one opening. Read it as capacity, with `cut * RouteCellPx` as the width in
  ## px of the narrowest place, and read `midCrossCount` for how many DISTINCT
  ## openings that capacity is divided into.
  let n = g.open.len
  if srcSet.len == 0 or dstSet.len == 0:
    return (0, 0, 0)
  var inSrc = newSeq[bool](n)
  var inDst = newSeq[bool](n)
  for i in srcSet: inSrc[i] = true
  for i in dstSet:
    if inSrc[i]: return (0, 0, 0)   ## overlapping endpoints: nothing to measure
    inDst[i] = true
  let
    source = 2 * n
    sink = 2 * n + 1
  var net = FlowNet(adj: newSeq[seq[FlowEdge]](2 * n + 2))
  for i in 0 ..< n:
    if not g.open[i]: continue
    let cap = if inSrc[i] or inDst[i]: FlowInf else: 1
    net.addEdge(2 * i, 2 * i + 1, cap)
    for j in adj[i]:
      net.addEdge(2 * i + 1, 2 * j, FlowInf)
  for i in srcSet: net.addEdge(source, 2 * i, FlowInf)
  for i in dstSet: net.addEdge(2 * i + 1, sink, FlowInf)
  let flow = net.maxFlow(source, sink)
  # Residual reachability from the source names the min cut: cells whose IN
  # node is reachable but whose OUT node is not.
  var seen = newSeq[bool](2 * n + 2)
  var queue = @[source]
  seen[source] = true
  var head = 0
  while head < queue.len:
    let u = queue[head]
    inc head
    for e in net.adj[u]:
      if e.cap > 0 and not seen[e.to]:
        seen[e.to] = true
        queue.add e.to
  var sx, sy, count = 0
  for i in 0 ..< n:
    if g.open[i] and seen[2 * i] and not seen[2 * i + 1]:
      sx += g.cellX(i)
      sy += g.cellY(i)
      inc count
  if count == 0:
    (flow, 0, 0)
  else:
    (flow, sx div count, sy div count)

# ---------------------------------------------------------------------------
# Stand ring — ported from mw2_playtest.py's `stand_exposure()`
# ---------------------------------------------------------------------------

proc standRing(
  wall: seq[bool], w, h, hx, hy, radius: int
): tuple[openFrac: float, arcs: int] =
  ## How open the ground immediately around a flag stand is, and into how many
  ## distinct walkable approaches that openness is divided.
  ##
  ## Counting arcs ALONE is degenerate and once had this reporting the exact
  ## opposite of the truth: a stand in open ground has one enormous unbroken
  ## arc and scored the same "1" as a stand behind a single doorway — an
  ## 81%-open ring was called "1 approach, a turkey shoot". The FRACTION is the
  ## honest primary number; the arc count only means something beside it.
  ##
  ## Measured for every map including the ones on the legacy column endzone,
  ## so the arena serves as a control here too. The earlier version skipped
  ## legacy maps and therefore never scored the control, which is exactly how
  ## the inverted reading survived.
  const steps = 360
  var ring = newSeq[bool](steps)
  var openCount = 0
  for i in 0 ..< steps:
    let
      th = 2.0 * PI * i.float / steps.float
      x = hx + int(round(radius.float * cos(th)))
      y = hy + int(round(radius.float * sin(th)))
      inside = x >= 0 and y >= 0 and x < w and y < h
    ring[i] = inside and not wall[y * w + x]
    if ring[i]: inc openCount
  let frac = openCount.float / steps.float
  if openCount == steps: return (frac, 1)
  if openCount == 0: return (frac, 0)
  var start = 0
  while ring[start]: inc start
  # ~25px of arc is a real doorway; a 13px player cannot use less.
  let arcPx = 2.0 * PI * radius.float / steps.float
  let minSteps = max(2, int(ceil(25.0 / max(arcPx, 0.001))))
  var arcs, run = 0
  for k in 0 ..< steps:
    if ring[(start + k) mod steps]:
      inc run
    else:
      if run >= minSteps: inc arcs
      run = 0
  if run >= minSteps: inc arcs
  (frac, arcs)

# ---------------------------------------------------------------------------
# Midfield seam
# ---------------------------------------------------------------------------

proc seamAt(
  wall: seq[bool], w, h: int, vertical: bool, at: int
): tuple[count: int, openFrac: float] =
  ## Crossings of one cut line, and the fraction of that line which is open.
  let
    band = PlayerHalf + 7             ## a player footprint either side
    axisLen = if vertical: h else: w
  var
    blockedRow = newSeq[bool](axisLen)
    openRows = 0
  for k in 0 ..< axisLen:
    var blocked = false
    for d in -band .. band:
      let
        x = if vertical: at + d else: k
        y = if vertical: k else: at + d
      if x < 0 or y < 0 or x >= w or y >= h or wall[y * w + x]:
        blocked = true
        break
    blockedRow[k] = blocked
    if not blocked: inc openRows
  var count, run = 0
  for k in 0 ..< axisLen:
    if not blockedRow[k]:
      inc run
    else:
      if run >= RouteCellPx: inc count
      run = 0
  if run >= RouteCellPx: inc count
  # Only the interior counts toward the fraction; the border ring is wall on
  # every map and would otherwise make every map look equally sealed.
  let interior = max(1, axisLen - 2 * ArenaBorder)
  (count, openRows.float / interior.float)

proc midfieldSeam(
  wall: seq[bool], w, h: int, vertical: bool, lo, hi: int
): tuple[count: int, openFrac: float, at: int] =
  ## How many DISTINCT ways cross the midfield between two bases, and how much
  ## of that crossing is open at all.
  ##
  ## Scanned across the whole midfield band and reported at the TIGHTEST cut
  ## line, because that is the cross-section every route has to pass through.
  ## Measuring at the exact center instead is wrong on a mirrored map and
  ## wrong in the way that flags the control: the center column IS the mirror
  ## seam, where a shape meets its own image, so the arena reads as a single
  ## 100%-open span — "one lane, a corridor" — for a board whose midfield is
  ## in fact divided by pickets a few dozen px to either side.
  ##
  ## The count ALONE stays degenerate in the way the stand-ring metric was: a
  ## map with 486px of continuous open midfield also reads as "1". And
  ## replacing the count with an absolute openness threshold fires on the
  ## arena itself. Both numbers ship together: low count plus low fraction is
  ## a corridor, low count plus high fraction is a field.
  ## The line is chosen by the LEAST TOTAL OPEN WIDTH, not by the fewest
  ## crossings. Choosing by count picks the emptiest line in the band — on the
  ## arena that is a column with nothing in it but the border, which scores
  ## "1 crossing, 100% open" and flags the control as a corridor. The narrowest
  ## cross-section is the one every route has to squeeze through, and its
  ## crossing count is the number of ways it offers.
  result = (0, 2.0, (lo + hi) div 2)
  var at = lo
  var found = false
  while at <= hi:
    let cut = seamAt(wall, w, h, vertical, at)
    if not found or cut.openFrac < result.openFrac:
      result = (cut.count, cut.openFrac, at)
      found = true
    at += PlayerHalf * 2
  if not found:
    result = (0, 0.0, (lo + hi) div 2)

# ---------------------------------------------------------------------------
# The evaluator
# ---------------------------------------------------------------------------

proc evaluateMap*(gameMap: CtfMap, name = ""): MapMetrics =
  ## Every static metric for one map, in one pass over the shared masks.
  ##
  ## Pure: reads only `gameMap`. Cost is dominated by the O(8 * w * h)
  ## enclosure scan and the O(n^2) visibility sample, both of which are capped;
  ## a standard board lands in the tens of milliseconds, which is free next to
  ## the ~97s a single headless episode costs.
  let
    w = gameMap.width
    h = gameMap.height
    teams = gameMap.teamCount()
  result.name = if name.len > 0: name else: "map"
  result.width = w
  result.height = h
  result.teams = teams
  result.layout = $gameMap.layout
  result.symmetry = $gameMap.symmetry
  result.endzone = $gameMap.endzone

  let diag = mapDiagnostics(
    gameMap, {diagnosticWallMasks, diagnosticCorridorOpen})
  result.reason = diag.reason
  result.valid = diag.reason.len == 0
  result.coverPermille = diag.coverPermille
  result.minCoverPermille = diag.minCoverPermille

  let
    maxWall = diag.maxWall
    minWall = diag.minWall
    corridor = diag.corridorOpen

  # --- architecture ------------------------------------------------------
  let (blocked, openPx) = enclosureCounts(maxWall, w, h, EnclosureReachPx)
  result.openFloorPx = openPx
  var interior, covered, exposed = 0
  for i in 0 ..< w * h:
    if maxWall[i]: continue
    let b = int(blocked[i])
    if b >= InteriorBlockedMin: inc interior
    if b >= CoveredBlockedMin: inc covered
    if b <= ExposedBlockedMax: inc exposed
  let openF = max(1, openPx).float
  result.interiorFrac = interior.float / openF
  result.coveredFrac = covered.float / openF
  result.exposedFrac = exposed.float / openF

  # --- open runs -----------------------------------------------------------
  # WHICH PIXELS COUNT. The ray is traced on `minWall` (a lane that opens at
  # any frame IS an open lane) but a run is only as long as the OCCUPIABLE
  # floor at its two ends: a firing lane needs somewhere for the shooter to
  # stand and somewhere for the target to be, and `corridorOpen` is the
  # validator's own answer to where that is.
  #
  # Without that condition the scan measures the BORDER GUTTER. Every board
  # here carries a 10px strip between the border ring's inner edge and the
  # first floor a 13px body can occupy, and it runs unbroken around the whole
  # map — so on `arena` the longest row (663px at y=10), the longest column
  # (639px at x=10) and the longest diagonal (790px from (12,10)) were all in
  # it. Those were the control's headline vision numbers, all three measured on
  # ground no player has ever stood on, and every band cut from them inherited
  # the error.
  var
    runHist = newSeq[int](max(w, h) + 2)
    runTotal, longRuns = 0
    runPxTotal, longRunPx = 0
  template noteRun(length: int) =
    ## `length` is already the occupiable-end-to-occupiable-end span, in px.
    if length > 0:
      inc runHist[min(length, runHist.len - 1)]
      inc runTotal
      runPxTotal += length
      if length > LongRunPx:
        inc longRuns
        longRunPx += length
  result.sightlineAxis = "none"

  # One scan body for all four axes. `stepPx` is how far one step travels: 1 px
  # along a row or column, sqrt(2) along a diagonal, so a diagonal lane is not
  # reported 29% shorter than the axis lane it is exactly as dangerous as.
  template scanLine(sx, sy, dx, dy: int, stepPx: float, axis: string,
                    hist: var seq[int], total, long, pxTotal, longPx: var int) =
    var
      x = sx
      y = sy
      firstOcc = -1                ## step index of the first occupiable pixel
      lastOcc = -1
      ox, oy = 0                   ## and where that first one was
      steps = 0
    template flush() =
      if firstOcc >= 0 and lastOcc > firstOcc:
        let length = int(float(lastOcc - firstOcc) * stepPx)
        if length > 0:
          inc hist[min(length, hist.len - 1)]
          inc total
          pxTotal += length
          if length > LongRunPx:
            inc long
            longPx += length
          if length > result.sightlineMaxPx:
            result.sightlineMaxPx = length
            result.sightlineAxis = axis
            result.sightlineX = ox
            result.sightlineY = oy
      firstOcc = -1
      lastOcc = -1
    while x >= 0 and x < w and y >= 0 and y < h:
      let i = y * w + x
      if minWall[i]:
        flush()
      elif corridor[i]:
        if firstOcc < 0:
          firstOcc = steps
          ox = x
          oy = y
        lastOcc = steps
      inc steps
      x += dx
      y += dy
    flush()

  for y in 0 ..< h:
    scanLine(0, y, 1, 0, 1.0, "row", runHist, runTotal, longRuns,
             runPxTotal, longRunPx)
  for x in 0 ..< w:
    scanLine(x, 0, 0, 1, 1.0, "column", runHist, runTotal, longRuns,
             runPxTotal, longRunPx)

  # --- diagonal open runs (the axis scan above cannot see these at all) ----
  # Reported SEPARATELY because every axis band is calibrated on the axis
  # histogram, and folding the diagonals into it would move every bound and the
  # control with them, which is not a measurement.
  var
    diagHist = newSeq[int](int(float(max(w, h)) * 1.4143) + 2)
    diagTotal, diagLong = 0
    diagPxTotal, diagLongPx = 0
  const Sqrt2 = 1.41421356
  for y in 0 ..< h:          # "\" diagonals, seeded down the left edge
    scanLine(0, y, 1, 1, Sqrt2, "diagonal", diagHist, diagTotal, diagLong,
             diagPxTotal, diagLongPx)
  for x in 1 ..< w:          # ...and along the top edge
    scanLine(x, 0, 1, 1, Sqrt2, "diagonal", diagHist, diagTotal, diagLong,
             diagPxTotal, diagLongPx)
  for y in 0 ..< h:          # "/" diagonals, seeded down the left edge
    scanLine(0, y, 1, -1, Sqrt2, "diagonal", diagHist, diagTotal, diagLong,
             diagPxTotal, diagLongPx)
  for x in 1 ..< w:          # ...and along the bottom edge
    scanLine(x, h - 1, 1, -1, Sqrt2, "diagonal", diagHist, diagTotal, diagLong,
             diagPxTotal, diagLongPx)
  result.diagRunP95Px = percentileOf(diagHist, diagTotal, 0.95)
  result.diagRunMaxPx = percentileOf(diagHist, diagTotal, 1.0)
  result.diagLongRunFrac =
    if diagTotal > 0: diagLong.float / diagTotal.float else: 0.0
  result.diagLongRunPxFrac =
    if diagPxTotal > 0: diagLongPx.float / diagPxTotal.float else: 0.0

  result.openRunP50Px = percentileOf(runHist, runTotal, 0.50)
  result.openRunP95Px = percentileOf(runHist, runTotal, 0.95)
  result.openRunMaxPx = percentileOf(runHist, runTotal, 1.0)
  result.longRunFrac = longRuns.float / max(1, runTotal).float
  result.longRunPxFrac =
    if runPxTotal > 0: longRunPx.float / runPxTotal.float else: 0.0

  # --- distance transform (chamfer 3-4 on maxWall, the validator's own) ---
  var dist = newSeq[int32](w * h)
  for i in 0 ..< w * h:
    dist[i] = if maxWall[i]: 0'i32 else: int32.high div 2
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
  var clearHist = newSeq[int](max(w, h) + 2)
  var clearTotal = 0
  for i in 0 ..< w * h:
    if maxWall[i]: continue
    let px = min(int(dist[i]) div 3, clearHist.len - 1)
    inc clearHist[px]
    inc clearTotal
  result.clearP50Px = percentileOf(clearHist, clearTotal, 0.50)
  result.clearP95Px = percentileOf(clearHist, clearTotal, 0.95)

  # --- coarse routing grid ------------------------------------------------
  let (g, adj) = buildCoarse(corridor, dist, w, h, RouteCellPx)
  var baseCell: seq[int]
  var anchors: seq[MapPoint]
  for team in gameMap.teams():
    let home = gameMap.flagHome(team)
    anchors.add home
    baseCell.add g.nearestOpenCell(home.x, home.y)

  # --- per-base BFS, detour, collision point ------------------------------
  var dists: seq[seq[int]]
  for cell in baseCell:
    dists.add bfsCells(adj, cell)

  # Each base's own near neighbourhood: the first fifth of the walk to the
  # nearest other base. That region is the engine's protected spawn pocket and
  # its approach — geometry no map author controls, carved identically on every
  # board — so both the route metric and the chokepoint detector cut it out of
  # the question and measure the part a map actually decides.
  var nearBase = newSeq[bool](g.open.len)
  for a in 0 ..< baseCell.len:
    if baseCell[a] < 0: continue
    var span = -1
    for b in 0 ..< baseCell.len:
      if b == a or baseCell[b] < 0: continue
      let d = dists[a][baseCell[b]]
      if d >= 0 and (span < 0 or d < span): span = d
    if span < 5: continue
    let near = span div 5
    for i in 0 ..< g.open.len:
      if dists[a][i] in 0 .. near: nearBase[i] = true

  # --- routes + bottleneck ------------------------------------------------
  var flows: seq[int]
  var bestCut = -1
  for a in 0 ..< baseCell.len:
    for b in a + 1 ..< baseCell.len:
      if baseCell[a] < 0 or baseCell[b] < 0: continue
      let span = dists[a][baseCell[b]]
      if span < 5: continue
      let near = span div 5
      var srcSet, dstSet: seq[int]
      for i in 0 ..< g.open.len:
        if not g.open[i]: continue
        if dists[a][i] in 0 .. near: srcSet.add i
        elif dists[b][i] in 0 .. near: dstSet.add i
      let r = vertexDisjointRoutes(g, adj, srcSet, dstSet)
      flows.add r.flow
      if bestCut < 0 or r.flow < bestCut:
        bestCut = r.flow
        result.bottleneckX = r.cutX
        result.bottleneckY = r.cutY
  if flows.len > 0:
    result.routeCountMin = min(flows)
    result.routeCountMax = max(flows)
    var totalFlow = 0
    for f in flows: totalFlow += f
    result.routeCountMean = totalFlow.float / flows.len.float
    result.bottleneckPx = result.routeCountMin * RouteCellPx
    result.routeCapacityFrac =
      result.routeCountMin.float / max(1.0, float(min(w, h) div RouteCellPx))
  var detours: seq[float]
  for a in 0 ..< baseCell.len:
    for b in a + 1 ..< baseCell.len:
      if baseCell[a] < 0 or baseCell[b] < 0: continue
      let hops = dists[a][baseCell[b]]
      if hops < 0: continue
      let
        straight = hypot(
          float(anchors[a].x - anchors[b].x), float(anchors[a].y - anchors[b].y))
        walked = float(hops * g.cell)
      if straight > 1.0:
        detours.add walked / straight
  if detours.len > 0:
    result.detourMin = min(detours)
    result.detourMax = max(detours)
    var total = 0.0
    for d in detours: total += d
    result.detourMean = total / detours.len.float

  # The collision point: run every base's race at once and keep the cells
  # where the two nearest arrive together. That frontier is where the map
  # decides its fights; a map whose frontier sits in open ground with no cover
  # plays as a sprint into a shooting gallery no matter what else it has.
  var frontier: seq[int]
  var bestD1 = high(int)
  for i in 0 ..< g.open.len:
    if not g.open[i]: continue
    var d1 = high(int)
    var d2 = high(int)
    for t in 0 ..< dists.len:
      let d = dists[t][i]
      if d < 0: continue
      if d < d1:
        d2 = d1; d1 = d
      elif d < d2:
        d2 = d
    if d1 == high(int) or d2 == high(int): continue
    if d2 - d1 <= 1:
      frontier.add i
      if d1 < bestD1:
        bestD1 = d1
        result.collisionX = g.cellX(i)
        result.collisionY = g.cellY(i)
  if frontier.len > 0:
    var inFrontier = newSeq[bool](g.open.len)
    for i in frontier: inFrontier[i] = true
    var seen = newSeq[bool](g.open.len)
    for i in frontier:
      if seen[i]: continue
      inc result.collisionRoutes
      var queue = @[i]
      seen[i] = true
      var head = 0
      while head < queue.len:
        let u = queue[head]
        inc head
        for v in g.neighbours4(u):
          if inFrontier[v] and not seen[v]:
            seen[v] = true
            queue.add v
    var sx, sy = 0.0
    for i in frontier:
      sx += float(g.cellX(i))
      sy += float(g.cellY(i))
    let
      mx = sx / frontier.len.float
      my = sy / frontier.len.float
    var varSum = 0.0
    for i in frontier:
      let
        dx = float(g.cellX(i)) - mx
        dy = float(g.cellY(i)) - my
      varSum += dx * dx + dy * dy
    result.collisionSpreadPx = int(sqrt(varSum / frontier.len.float))

  # Cover density at the collision point, against the map's own average, so
  # the number means "denser or thinner than this map" rather than importing a
  # cover budget from a different board size.
  var wallPx = 0
  for i in 0 ..< w * h:
    if maxWall[i]: inc wallPx
  let mapCoverFrac = wallPx.float / float(w * h)
  block collisionCover:
    var near, nearWall = 0
    let r = StandCoverRadiusPx
    for y in max(0, result.collisionY - r) .. min(h - 1, result.collisionY + r):
      for x in max(0, result.collisionX - r) .. min(w - 1, result.collisionX + r):
        let
          dx = x - result.collisionX
          dy = y - result.collisionY
        if dx * dx + dy * dy > r * r: continue
        inc near
        if maxWall[y * w + x]: inc nearWall
    result.collisionCoverFrac = nearWall.float / max(1, near).float
    result.collisionCoverRatio =
      if mapCoverFrac > 0.0: result.collisionCoverFrac / mapCoverFrac else: 0.0

  # --- stands -------------------------------------------------------------
  let ringRadius =
    (if gameMap.endzoneRadius > 0: gameMap.endzoneRadius else: gameMap.flagRing) +
      PlayerHalf + 14
  for home in anchors:
    var near, nearWall = 0
    let r = StandCoverRadiusPx
    # ...and the distance to the nearest cover a carrier could actually use.
    # The board's own BORDER RING is excluded: it is wall on every map, it is
    # always within a stand's disc on a column endzone, and counting it would
    # hand every naked stand a perfect score off the engine's own geometry —
    # the same reason the route metric and the chokepoint detector cut out the
    # protected spawn pocket.
    var gap2 = (r + 1) * (r + 1)
    for y in max(0, home.y - r) .. min(h - 1, home.y + r):
      for x in max(0, home.x - r) .. min(w - 1, home.x + r):
        let
          dx = x - home.x
          dy = y - home.y
          d2 = dx * dx + dy * dy
        if d2 > r * r: continue
        inc near
        if maxWall[y * w + x]:
          inc nearWall
          if x >= ArenaBorder and y >= ArenaBorder and
              x < w - ArenaBorder and y < h - ArenaBorder and d2 < gap2:
            gap2 = d2
    result.standCover.add nearWall.float / max(1, near).float
    result.standCoverGapPx.add min(int(sqrt(gap2.float)), r + 1)
    let ring = standRing(maxWall, w, h, home.x, home.y, ringRadius)
    result.standRingOpen.add ring.openFrac
    result.standRingArcs.add ring.arcs
  if result.standCover.len > 0:
    result.standCoverMin = min(result.standCover)
    result.standCoverMax = max(result.standCover)
    result.standCoverGapMaxPx = max(result.standCoverGapPx)
    result.standRingOpenMin = min(result.standRingOpen)
    result.standRingOpenMax = max(result.standRingOpen)

  # --- midfield seam ------------------------------------------------------
  block midfield:
    var
      bestPair = (0, 1)
      bestDist = Inf
    for a in 0 ..< anchors.len:
      for b in a + 1 ..< anchors.len:
        let d = hypot(float(anchors[a].x - anchors[b].x),
                      float(anchors[a].y - anchors[b].y))
        if d < bestDist:
          bestDist = d
          bestPair = (a, b)
    if anchors.len < 2:
      result.midAxisVertical = true
      let seam = midfieldSeam(maxWall, w, h, true, w div 3, 2 * w div 3)
      result.midCrossCount = seam.count
      result.midOpenFrac = seam.openFrac
      result.midSeamAt = seam.at
      break midfield
    let
      pa = anchors[bestPair[0]]
      pb = anchors[bestPair[1]]
      vertical = abs(pa.x - pb.x) >= abs(pa.y - pb.y)
      a0 = if vertical: pa.x else: pa.y
      a1 = if vertical: pb.x else: pb.y
      span = abs(a1 - a0)
      mid = (a0 + a1) div 2
      # The middle third of the run between the two bases: outside it a cut
      # line is measuring a base's own approach, not the midfield.
      seam = midfieldSeam(maxWall, w, h, vertical,
        mid - span div 6, mid + span div 6)
    result.midAxisVertical = vertical
    result.midCrossCount = seam.count
    result.midOpenFrac = seam.openFrac
    result.midSeamAt = seam.at

  # --- chokepoints --------------------------------------------------------
  # Candidates are local minima of the distance transform on the medial axis,
  # sampled at cell resolution; each survivor must then be a GENUINE cut —
  # remove its clearance disc and see whether a base pair actually falls apart.
  # Topology without the cut test finds every doorway in a wall that nobody
  # has to walk through.
  var chokes: seq[int]
  block chokepoints:
    if baseCell.len < 2: break chokepoints
    # Candidates are narrow floor on a near-shortest base-to-base route; each
    # then has to be a GENUINE cut — remove its clearance disc and see whether
    # a base pair actually falls apart.
    #
    # An earlier version also demanded that a candidate be a LOCAL MINIMUM of
    # the distance transform among its neighbouring cells, as a cheap way to
    # thin the candidate list. That filter is what made the detector return
    # zero for every map in the pool AND for a synthetic board with two walls
    # and one door punched through each: the cell holding the doorway records
    # its widest interior pixel, and the cells at the doorway's shoulders
    # record floor pinched against the wall, so the doorway is never the local
    # minimum. Topology decides this, not a ridge heuristic — the cut test is
    # the filter, and everything before it is only there to bound the cost.
    var candidates: seq[tuple[clear, cell: int]]
    for i in 0 ..< g.open.len:
      if not g.open[i]: continue
      if g.clearPx[i] > ChokeMaxClearPx: continue
      # The spawn-pocket mouth is a genuine cut on EVERY map — the arena
      # reports one 22px from each pedestal — and it is the engine's geometry,
      # not the author's. Excluded for the same reason the route endpoints are.
      if nearBase[i]: continue
      var onRoute = false
      for a in 0 ..< baseCell.len:
        for b in a + 1 ..< baseCell.len:
          if baseCell[b] < 0: continue
          if dists[a][i] < 0 or dists[b][i] < 0: continue
          if dists[a][baseCell[b]] < 0: continue
          if dists[a][i] + dists[b][i] <= dists[a][baseCell[b]] + 4:
            onRoute = true
      if onRoute: candidates.add (g.clearPx[i], i)
    # Narrowest first, capped: the tightest floor is where a cut can be, and
    # the cap keeps a giant board's cost bounded without changing the answer
    # on any board small enough to test exhaustively.
    candidates.sort(proc (x, y: tuple[clear, cell: int]): int =
      cmp(x.clear, y.clear))
    if candidates.len > ChokeCandidateCap: candidates.setLen(ChokeCandidateCap)
    var blockedCell = newSeq[bool](g.open.len)
    var reach = newSeq[bool](g.open.len)
    for cand in candidates:
      let
        c = cand.cell
        px = g.cellX(c)
        py = g.cellY(c)
        cutR = g.clearPx[c] + PlayerHalf
      # Skip anything already inside a confirmed chokepoint's disc: two minima
      # a doorway apart are one doorway seen twice.
      var dup = false
      for k in chokes:
        let
          dx = px - g.cellX(k)
          dy = py - g.cellY(k)
          span = max(2 * g.clearPx[k], 2 * RouteCellPx)
        if dx * dx + dy * dy <= span * span: dup = true
      if dup: continue
      for i in 0 ..< g.open.len:
        blockedCell[i] = false
        if not g.open[i]: continue
        let
          dx = g.cellX(i) - px
          dy = g.cellY(i) - py
        if dx * dx + dy * dy <= cutR * cutR: blockedCell[i] = true
      var isCut = false
      for a in 0 ..< baseCell.len:
        if baseCell[a] < 0 or blockedCell[baseCell[a]]: continue
        for i in 0 ..< reach.len: reach[i] = false
        var queue = @[baseCell[a]]
        reach[baseCell[a]] = true
        var head = 0
        while head < queue.len:
          let u = queue[head]
          inc head
          for v in adj[u]:
            if not reach[v] and not blockedCell[v]:
              reach[v] = true
              queue.add v
        for b in 0 ..< baseCell.len:
          if b == a or baseCell[b] < 0: continue
          if dists[a][baseCell[b]] >= 0 and not reach[baseCell[b]]:
            isCut = true
        if isCut: break
      if isCut: chokes.add c

  result.chokeCount = chokes.len
  for c in chokes:
    result.chokeX.add g.cellX(c)
    result.chokeY.add g.cellY(c)
  if chokes.len > 0:
    var tightest = high(int)
    for c in chokes:
      tightest = min(tightest, g.clearPx[c])
    result.chokeMinClearPx = tightest

  # One vantage that can KILL INTO every chokepoint is one camper who owns the
  # map. Range-capped at the LETHAL envelope, not at gun range: see
  # `IsovistRangePx` for why that cap was ~4x too wide, and note the direction
  # — a tighter cap makes this penalty fire LESS often, which is the point.
  #
  # Run at both radii so the re-cut is a printed before/after on every map
  # rather than an assertion. The line-of-sight test is the expensive half and
  # the range test is a subtraction, so the second radius is nearly free.
  block isovist:
    if chokes.len == 0:
      result.chokeCovered = false
      result.chokeCoveredAtGunRange = false
      break isovist
    if chokes.len == 1:
      # A single forced doorway is trivially covered — by standing on it. True
      # at any radius, so both readings agree here by construction.
      result.chokeCovered = true
      result.chokeCoveredAtGunRange = true
      result.chokeCoverX = g.cellX(chokes[0])
      result.chokeCoverY = g.cellY(chokes[0])
      break isovist
    for i in 0 ..< g.open.len:
      if not g.open[i]: continue
      if result.chokeCovered and result.chokeCoveredAtGunRange: break
      let
        vx = g.cellX(i)
        vy = g.cellY(i)
      var
        lethalRange = true
        gunRange = true
      for c in chokes:
        let
          dx = g.cellX(c) - vx
          dy = g.cellY(c) - vy
          d2 = dx * dx + dy * dy
        if d2 > IsovistRangePx * IsovistRangePx: lethalRange = false
        if d2 > VisionPairRangePx * VisionPairRangePx: gunRange = false
      if not gunRange: continue    ## the wider of the two: nothing to learn here
      var sees = true
      for c in chokes:
        if not losClear(minWall, w, h, vx, vy,
                        g.cellX(c), g.cellY(c)):
          sees = false
          break
      if not sees: continue
      result.chokeCoveredAtGunRange = true
      if lethalRange and not result.chokeCovered:
        result.chokeCovered = true
        result.chokeCoverX = vx
        result.chokeCoverY = vy

  # --- chokepoint PINCH LENGTH --------------------------------------------
  # The detector above answers "is this floor a genuine cut, and how WIDE is
  # it". That cannot tell a 40px doorway from a 40 x 400px shooting gallery:
  # both are one cut at 40px clearance and they scored identically. The missing
  # dimension is LENGTH, and the length that matters is unbroken sightline, not
  # arc — a passage that bends resets the defender's clock at every corner.
  #
  # `map_lanes.auditCorridorPinches` is that predicate, already derived (66px
  # allowed at a 30px pinch, grading to 132px at 62px+) and already calibrated
  # against this same control. Reused whole rather than reimplemented, on the
  # module's own rule 3, and run on `maxWall` — the pessimistic mask for
  # movement, which is the mask its own doc string asks for.
  block pinch:
    if anchors.len < 2: break pinch
    let audit = auditCorridorPinches(maxWall, w, h, anchors)
    result.routeWidthPx = audit.routeWidthPx
    result.pinchGateCount = audit.gates.len
    result.pinchMandatoryCount = audit.chokepoints.len
    # `chokepoints` is the MANDATORY subset — a gallery you can walk around is
    # a flank, not a kill box, and the arena settles that: it ships a straight
    # 188px channel of 36px floor and plays well because it is one optional
    # lane among eight.
    var worst = low(int)
    for r in audit.chokepoints:
      if r.excessPx > worst:
        worst = r.excessPx
        result.chokeExposedPx = r.exposedPx
        result.chokeAllowedPx = r.allowedPx
    result.chokeExcessPx = if worst == low(int): 0 else: worst

  # --- visibility graph ---------------------------------------------------
  block visibility:
    var sample: seq[(int, int)]
    var stride = RouteCellPx * 2
    while true:
      sample.setLen(0)
      var cy = stride div 2
      while cy < h:
        var cx = stride div 2
        while cx < w:
          if corridor[cy * w + cx]: sample.add (cx, cy)
          cx += stride
        cy += stride
      if sample.len <= VisibilitySampleCap or stride > max(w, h): break
      stride = int(float(stride) * 1.3) + 1
    result.visSamples = sample.len
    result.visSampleStridePx = stride
    if sample.len < 4: break visibility
    var
      degree = newSeq[float](sample.len)
      lethalDegree = newSeq[float](sample.len)
    for a in 0 ..< sample.len:
      for b in a + 1 ..< sample.len:
        let
          dx = sample[a][0] - sample[b][0]
          dy = sample[a][1] - sample[b][1]
          d2 = dx * dx + dy * dy
        if d2 > VisionPairRangePx * VisionPairRangePx: continue
        if losClear(minWall, w, h, sample[a][0], sample[a][1],
                    sample[b][0], sample[b][1]):
          degree[a] += 1.0
          degree[b] += 1.0
          # The lethal twin rides the SAME line-of-sight test — the expensive
          # half — so it costs one comparison. See the audit note on the type.
          if d2 <= IsovistRangePx * IsovistRangePx:
            lethalDegree[a] += 1.0
            lethalDegree[b] += 1.0
    proc summarize(d: seq[float]): tuple[mean, frac, cv: float] =
      var total = 0.0
      for v in d: total += v
      let mean = total / d.len.float
      var varSum = 0.0
      for v in d:
        let e = v - mean
        varSum += e * e
      (mean, mean / float(d.len - 1),
       if mean > 0.0: sqrt(varSum / d.len.float) / mean else: 0.0)
    let wide = summarize(degree)
    result.visDegreeMean = wide.mean
    result.visDegreeFrac = wide.frac
    result.visDegreeCv = wide.cv
    result.visDegreeP10 = percentileOf(degree, 0.10)
    result.visDegreeP90 = percentileOf(degree, 0.90)
    let lethal = summarize(lethalDegree)
    result.visLethalDegreeMean = lethal.mean
    result.visLethalDegreeFrac = lethal.frac
    result.visLethalDegreeCv = lethal.cv

# ---------------------------------------------------------------------------
# Scoring: banded sub-scores, calibrated against the arena
# ---------------------------------------------------------------------------

proc subScore(band: Band, value: float): float =
  ## 1.0 inside the band, falling linearly to 0 over `margin` outside it.
  if value >= band.lo and value <= band.hi: return 1.0
  let d = if value < band.lo: band.lo - value else: value - band.hi
  clamp(1.0 - d / max(band.margin, 1e-9), 0.0, 1.0)

proc metricValue*(m: MapMetrics, name: string): float =
  ## The named metric as a float, so bands stay data rather than code.
  case name
  of "interiorFrac": m.interiorFrac
  of "exposedFrac": m.exposedFrac
  of "longRunFrac": m.longRunFrac
  of "longRunPxFrac": m.longRunPxFrac
  of "diagLongRunFrac": m.diagLongRunFrac
  of "diagLongRunPxFrac": m.diagLongRunPxFrac
  of "sightlineMaxPx": m.sightlineMaxPx.float
  of "openRunP95Px": m.openRunP95Px.float
  of "chokeExcessPx": m.chokeExcessPx.float
  of "standCoverGapMaxPx": m.standCoverGapMaxPx.float
  of "visLethalDegreeCv": m.visLethalDegreeCv
  of "routeCountMin", "routeCountDesign": m.routeCountMin.float
  of "routeCapacityFrac": m.routeCapacityFrac
  of "chokeCoveredPenalty":
    if m.chokeCount > 0 and m.chokeCovered: 1.0 else: 0.0
  of "bottleneckPx": m.bottleneckPx.float
  of "chokeCount": m.chokeCount.float
  of "collisionCoverRatio": m.collisionCoverRatio
  of "collisionRoutes": m.collisionRoutes.float
  of "standCoverMin": m.standCoverMin
  of "standRingOpenMin": m.standRingOpenMin
  of "standRingSpread": m.standRingOpenMax - m.standRingOpenMin
  of "standCoverSpread": m.standCoverMax - m.standCoverMin
  of "midCrossCount": m.midCrossCount.float
  of "midOpenFrac": m.midOpenFrac
  of "detourMax": m.detourMax
  of "visDegreeFrac": m.visDegreeFrac
  of "visDegreeCv": m.visDegreeCv
  of "coverPermille": m.coverPermille.float
  else: 0.0

const ArenaControl* = "measured on the hand-authored arena, 2026-08-06"

const ArenaLargeControl* = """
THE SECOND CONTROL, AND IT BREACHES FOUR BANDS.

`map_eval` prepends `arena` to every batch and has never scored `arena-large`,
so the repo's other hand-authored map has never been a control at all. Scored
as one (tools/stick_probe.nim), it breaches:

  interiorFrac    0.100  [0.25..0.65]   arena 0.342
  longRunFrac     0.169  [-1.00..0.15]  arena 0.104
  visDegreeCv     0.295  [0.30..1.20]   arena 0.524
  sightlineMaxPx  1149   [..1050]       arena 758

DECIDED ON EVIDENCE, per the rule that a metric flagging the control is wrong
and one that skips the control is worse — this is a finding about the CONTROL,
not about the bands, and the reason is that arena-large is a 30% GEOMETRIC
UPSCALE of arena. Same obstacle inventory, +69% area. Nothing was designed; the
furniture simply moved apart. So its enclosure fraction falls, its open runs
lengthen, and its exposure evens out, all without an authoring decision. The
three fraction bands are measuring that dilution correctly.

`sightlineMaxPx` is the one that is not a dilution artifact: 1149 px of
unbroken open line between two places a player can stand, on a map whose gun
reaches 1050 px. That is a lane neither end can contest, and it is exactly the
defect the validator's horizontal rule exists to prevent — the rule misses it
because it only ever looks along rows.

WHAT WAS NOT DONE, and deliberately: the bands were NOT widened to admit
arena-large. Widening interiorFrac to 0.10 would retire the single highest-
weight discriminator in the suite (the pool's median is 0.12; the band exists
to separate buildings from scatter). arena-large is evidence that the fraction
bands are not scale-free, which is real and is filed as its own work — it is
not a licence to spend them.
"""

let DefaultBands*: seq[Band] = @[
  # Every bound below is calibrated against TWO measured things: the
  # hand-authored arena (the control, which must sit comfortably inside every
  # band) and the 20 curated pool seeds (the population the generator actually
  # produces today). `control:` records the arena's measured value so a bound
  # can never drift away from the thing that justified it, and `map_eval`
  # re-checks the control against every band on every run.
  #
  # A band with `lo` far below any reachable value is a one-sided CAP: only its
  # upper bound means anything.

  # Architecture — the single highest-value static metric, and the one the
  # current generator is furthest from. The arena is honest SCATTER by design,
  # so its 34% is the FLOOR to beat, not the target; the pool's median is 12%.
  Band(name: "interiorFrac", lo: 0.25, hi: 0.65, margin: 0.22, weight: 3.0,
       kind: bandSoft, control: 0.342,
       note: "enclosed floor (>=6 of 8 dirs blocked @120px). arena 34.2%, " &
         "pool median 11.8% — the scatter-vs-buildings discriminator"),
  Band(name: "exposedFrac", lo: -1.0, hi: 0.20, margin: 0.20, weight: 1.0,
       kind: bandSoft, control: 0.038,
       note: "wide-open floor (<=1 of 8 blocked). arena 3.8%, pool median 22%"),
  # Vision. Guns are map-wide (1050px), so what governs a fight is how far you
  # can see before geometry cuts the angle.
  Band(name: "longRunFrac", lo: -1.0, hi: 0.15, margin: 0.12, weight: 1.5,
       kind: bandSoft, control: 0.104,
       note: "share of open axis runs over 600px. arena 10.4%, pool median " &
         "3.3%. Control moved 11.0% -> 10.4% when runs stopped being measured " &
         "through the unoccupiable border gutter; the bound did not move"),
  # THE DIAGONAL, which until now was measured and did not gate at all. Two
  # bands, because the two things worth stopping are different shapes.
  Band(name: "sightlineMaxPx", lo: -1.0, hi: float(SightlineCapPx),
       margin: 350.0, weight: 2.0, kind: bandSoft, control: 758.0,
       note: "LONGEST unbroken open line between two standable points, on " &
         "ANY of the four scan axes. Capped at GunRange=1050: a lane longer " &
         "than the gun's own reach cannot be contested from either end. " &
         "arena 758 (diagonal), pool median 818, pool max 1074. BREACHED BY " &
         "arena-large at 1149 and by four curated pool seeds at 1074 — see " &
         "ArenaLargeControl. Note the carrying axis: on 13 of 36 measured " &
         "maps the longest line is DIAGONAL, which the axis scan and the " &
         "hard validator are both blind to"),
  Band(name: "diagLongRunPxFrac", lo: -1.0, hi: 0.15, margin: 0.15,
       weight: 1.5, kind: bandSoft, control: 0.010,
       note: "share of open floor sitting on a DIAGONAL line over 600px, " &
         "pixel-weighted so it is the same measurement as the axis form. " &
         "arena 1.0%, arena-large 18.3%, pool median 2.7%, pool max 14.3%. " &
         "CALIBRATED ON AN AXIS-ALIGNED POPULATION and that is the caveat " &
         "that matters: today's lattice generator cannot build a diagonal " &
         "lane, so this bound has never been stressed. The moment the new " &
         "generator emits shapeDiagonal and polygon masses the distribution " &
         "moves and this bound must be re-cut against a FRESH population, " &
         "not assumed to still separate anything"),
  # Routes. Capacity in 26px corridor units, measured base-approach to
  # base-approach so the engine's own spawn pocket is not the answer.
  # TWO BANDS ON ONE NUMBER, and which is which is load-bearing. The design
  # intends at least THREE vertex-disjoint routes; only the >= 2 band rejects.
  # Build for 3, and read the hard one when asking what actually gates.
  Band(name: "routeCountMin", lo: 2.0, hi: 1.0e6, margin: 2.0, weight: 1.5,
       kind: bandHard, control: 8.0,
       note: "THE GATE. A map with one route is a corridor. This is the " &
         "bound that REJECTS, and it enforces 2 — one fewer than the design " &
         "asks for. `routeCountDesign` below carries the intended 3 and only " &
         "costs score. arena 8, arena-large 12, pool min 2"),
  Band(name: "routeCountDesign", lo: 3.0, hi: 1.0e6, margin: 1.0, weight: 1.5,
       kind: bandSoft, control: 8.0,
       note: "THE INTENT, which does not gate: >= 3 vertex-disjoint routes, " &
         "so that sealing one still leaves a choice rather than a corridor. " &
         "Soft on purpose — three curated pool seeds ship at exactly 2 and " &
         "making this hard would reject them today. Same number as " &
         "`routeCountMin`; separate band so the report says out loud which " &
         "bound is enforcing and which is aspiring"),
  Band(name: "routeCapacityFrac", lo: 0.12, hi: 0.50, margin: 0.25,
       weight: 2.0, kind: bandSoft, control: 0.316,
       note: "route capacity / board short side, in cells: the scale-free " &
         "form. arena 0.32, pool 0.4-0.6 (wider midfields, less structure)"),
  # Chokepoints. Zero is a field; too many is a map of doorways. The arena has
  # zero, so this is a pure cap — the FLOOR here would flag the control.
  Band(name: "chokeCount", lo: -1.0, hi: 6.0, margin: 4.0, weight: 1.0,
       kind: bandSoft, control: 0.0,
       note: "genuine cut vertices on a base-to-base route. arena 0"),
  Band(name: "chokeCoveredPenalty", lo: -1.0, hi: 0.0, margin: 1.0,
       weight: 1.5, kind: bandSoft, control: 0.0,
       note: "1 when ONE 259px isovist can KILL INTO every chokepoint — one " &
         "camper owns every route. The radius was GunRange=1050 and was " &
         "therefore ~4x too wide (P(hit) is 0.14 there); see IsovistRangePx. " &
         "Re-cutting it took the flag off 3 of the 5 maps that carried it — " &
         "those were maps whose chokepoints merely fell in one FIELD OF VIEW"),
  # THE PINCH LENGTH. Until this band existed a 40px doorway and a 40 x 400px
  # shooting gallery scored identically: the detector measured width and never
  # length, so the difference between a chokepoint and a kill box was invisible.
  Band(name: "chokeExcessPx", lo: -1.0e6, hi: 0.0,
       margin: float(MaxExposedRunPx), weight: 2.0, kind: bandSoft,
       control: 0.0,
       note: "how far the worst UNAVOIDABLE pinch's unbroken sightline " &
         "overruns what a player can clear alive at that pinch's own width " &
         "(66px at 30px wide, grading to 132px at 62px+). Margin is one whole " &
         "extra kill's travel. arena 0 and arena-large 0 — arena has 28 pinch " &
         "gates and ZERO mandatory ones, which is the right answer: its 188px " &
         "channel of 36px floor is one optional lane among eight. Four pool " &
         "seeds breach, worst +83px. Exposure, not arc length: a passage that " &
         "bends resets the defender's clock at every corner"),
  # Where the teams meet should have MORE cover than the map average, or the
  # first contact of every match is a sprint into open ground.
  Band(name: "collisionCoverRatio", lo: 0.70, hi: 2.40, margin: 0.60,
       weight: 1.5, kind: bandSoft, control: 1.456,
       note: "cover within 200px of the collision point vs map average. " &
         "arena 1.46, pool median 0.83, pool min 0.05"),
  # The objective. NOTE the upper bound is nearly structural: the engine carves
  # protected floor around every pedestal, so no map can have a heavily walled
  # stand ring. The arena's 89% is the LOWEST in the whole measured set; the
  # pool sits at 94-100%, i.e. naked stands.
  Band(name: "standRingOpenMin", lo: 0.25, hi: 0.95, margin: 0.08, weight: 1.5,
       kind: bandSoft, control: 0.892,
       note: "openness of the ring around the least-open stand. arena 89.2%, " &
         "pool 93.6-100%"),
  Band(name: "standRingSpread", lo: -1.0, hi: 0.10, margin: 0.15, weight: 2.0,
       kind: bandSoft, control: 0.0,
       note: "stand-ring openness gap between teams — objective fairness. " &
         "A symmetric map must score 0 and the arena does"),
  Band(name: "standCoverSpread", lo: -1.0, hi: 0.04, margin: 0.08, weight: 2.0,
       kind: bandSoft, control: 0.0,
       note: "stand cover gap between teams — objective FAIRNESS, and a " &
         "fairness measure CANNOT EXPRESS A FLOOR: two equally naked stands " &
         "both score 0 here and pass. The two bands below are the floor this " &
         "one structurally cannot be"),
  # THE ABSOLUTE STAND-SIDE COVER FLOOR — the one causally-established property
  # in the suite that was going unenforced. Two bands, because the fraction and
  # the distance say different things and only one of them is scale-free.
  Band(name: "standCoverMin", lo: float(StandCoverFloorPermille) / 1000.0,
       hi: 1.0e6, margin: 0.015, weight: 1.5, kind: bandSoft, control: 0.072,
       note: "wall fraction within 200px of the LEAST-COVERED stand. A pure " &
         "NAKEDNESS detector and nothing more, and the reason it cannot be a " &
         "quality bar is arena-large: the same furniture on a 69% bigger " &
         "board drops from arena's 7.2% to 2.6% without one obstacle moving " &
         "relative to the stand. So the fraction is not scale-free and any " &
         "bar high enough to mean something would flag a control. Floor 1.5%, " &
         "pool min 2.0% — it does NOT bite on today's population, and it is " &
         "here so that a stand with literally nothing beside it cannot score " &
         "a clean 0 on the fairness band and pass"),
  Band(name: "standCoverGapMaxPx", lo: -1.0e6, hi: float(MaxExposedRunPx),
       margin: float(MaxExposedRunPx), weight: 2.0, kind: bandSoft,
       control: 83.0,
       note: "THE FLOOR WITH TEETH: distance from the worst-served stand to " &
         "the nearest cover, border ring excluded. Bounded by " &
         "MaxExposedRunPx=132 — how far a player travels while a shooter " &
         "kills them — so a stand whose nearest cover is further than that " &
         "is a stand a carrier cannot leave alive. Scale-free, because 132px " &
         "is physics and not a share of the board. arena 83 (37% slack), " &
         "arena-large 111, pool median 125, pool max 176; seven measured maps " &
         "breach. This is the band the objective was missing"),
  # Midfield: the count and the fraction, together, always.
  Band(name: "midCrossCount", lo: 3.0, hi: 12.0, margin: 2.5, weight: 1.5,
       kind: bandSoft, control: 5.0,
       note: "distinct ways across the TIGHTEST midfield cut. arena 5, " &
         "pool 2-12 (independently matches mw2's hand count of 5 for arena)"),
  Band(name: "midOpenFrac", lo: 0.10, hi: 0.70, margin: 0.20, weight: 1.0,
       kind: bandSoft, control: 0.412,
       note: "how much of that cut line is open at all. arena 41%, " &
         "pool median 53%. Read WITH the count: low count + high fraction " &
         "is a field, low count + low fraction is a corridor"),
  # Shape.
  Band(name: "detourMax", lo: 1.10, hi: 1.90, margin: 0.35, weight: 1.0,
       kind: bandSoft, control: 1.295,
       note: "walked route / straight line, worst base pair. arena 1.30, " &
         "pool median 1.14 — a 1.01 detour is a straight sprint"),
  Band(name: "visDegreeCv", lo: 0.30, hi: 1.20, margin: 0.30, weight: 1.0,
       kind: bandSoft, control: 0.524,
       note: "unevenness of exposure across the board. arena 0.52, " &
         "pool median 0.28 — a uniform board has no good and bad ground"),
]

proc scoreBands*(
  m: MapMetrics, bands: seq[Band] = DefaultBands
): seq[BandResult] =
  ## Every band scored against one map, with the slack left at each bound.
  for band in bands:
    let
      value = m.metricValue(band.name)
      sub = band.subScore(value)
      slack = min(value - band.lo, band.hi - value)
    # Slack is judged against the MARGIN, not against the band's own width. A
    # one-sided cap sets `lo` far below any reachable value, so a span-relative
    # test would call every such band "tight" the moment the value sat anywhere
    # in the safe half — a warning that fires on everything warns about nothing.
    result.add BandResult(
      band: band, value: value, sub: sub,
      tight: sub >= 1.0 and slack < 0.35 * band.margin,
      breached: sub < 1.0)

proc staticScore*(m: MapMetrics, bands: seq[Band] = DefaultBands): float =
  ## The single weighted scalar a ranker sorts on: [0,1], 1.0 = every band
  ## satisfied. Deliberately a thin weighted mean of banded sub-scores so a
  ## downstream caller can re-weight without re-deriving anything.
  ##
  ## An INVALID map scores 0: the hard gates are the validator's, not ours.
  if not m.valid: return 0.0
  var total, weight = 0.0
  for r in m.scoreBands(bands):
    total += r.sub * r.band.weight
    weight += r.band.weight
  if weight <= 0.0: 0.0 else: total / weight

proc bandReport*(m: MapMetrics, bands: seq[Band] = DefaultBands): string =
  ## A human-readable slack table. Rule 5: a "tight" warning prints next to
  ## every bound so the margin stays visible rather than being quietly spent
  ## by the next change.
  var lines: seq[string]
  for r in m.scoreBands(bands):
    let mark =
      if r.breached: "BREACH"
      elif r.tight: "tight "
      else: "      "
    lines.add &"  {mark} {r.band.name:<20} {r.value:8.3f}  " &
      &"[{r.band.lo:.2f}..{r.band.hi:.2f}] sub={r.sub:.2f} w={r.band.weight:.1f}"
  lines.join("\n")

# ---------------------------------------------------------------------------
# The generator's ranker. `arena.generateCtfMap` draws K candidates and ships
# the best one by this score; it reaches the function through a hook because
# the import only runs one way (this module measures maps, so it imports
# `arena`, so `arena` cannot import it back). Installed at module-init time,
# and `sim` imports this module, so every binary that speaks CTF ranks with
# the same rubric — see `arena.setMapFitness` for what a missing hook means.
# ---------------------------------------------------------------------------

proc staticFitness(gameMap: CtfMap): float {.nimcall, gcsafe, raises: [].} =
  ## `staticScore` of a freshly measured map, and 0 for anything that throws.
  ## A metric that raises must not be able to abort map generation: the score
  ## is an ORDERING, and an unrankable candidate simply loses.
  ##
  ## `cast(gcsafe)`: the only globals this reaches are `DefaultBands` and the
  ## tunable consts — `let`/`const`, built at module init, never written again.
  ## The cast is required because `tools/map_editor.nim` serves over mummy and
  ## generates maps from request threads, so the hook has to be callable there.
  {.cast(gcsafe).}:
    try:
      evaluateMap(gameMap).staticScore()
    except CatchableError, Defect:
      0.0

setMapFitness(staticFitness, "map_metrics.staticScore")
