## Tests for the map fitness harness (src/ctf/map_metrics.nim).
##
## The suite is organised around the five rules the harness exists to enforce,
## because every one of them was learned by shipping a confidently wrong
## number. In particular `the control passes every band` is not a nicety: it is
## the mechanical guard that stops a future change from tightening a threshold
## until it flags the hand-authored arena, which has happened three times by
## hand and is exactly what a test can prevent.
##
## Three metrics also carry POSITIVE controls — a synthetic map built to have
## the property, so a detector that silently returns zero on everything cannot
## pass. The chokepoint detector reports 0 for the arena AND for all 20 curated
## pool seeds, which is either the truth about a pack of scatter maps or a dead
## detector; only a map with a known doorway can tell those apart.

import
  helpers,
  std/[monotimes, strutils, times, unittest],
  ctf/map_metrics,
  ctf/map_pool,
  ctf/sim

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

proc arenaMap(): CtfMap = loadCtfMapMetadata("arena")

proc doorwayMap(gapLo = 300, gapHi = 360): CtfMap =
  ## The arena, with one full-height wall dropped across its left half and a
  ## single gap punched through it. Mirror symmetry gives the right half the
  ## same wall, so a route from base to base must pass two known doorways.
  result = arenaMap()
  result.leftObstacles = @[
    rectShape(MapRect(x: 540, y: 10, w: 21, h: gapLo - 10)),
    rectShape(MapRect(x: 540, y: gapHi, w: 21, h: result.height - gapHi - 10)),
  ]

proc scatterMap(pebble = 16, pitch = 20): CtfMap =
  ## The arena with every obstacle dissolved into pebbles on a grid inside its
  ## own bounding box — same walls, same places, same rough cover, no masses.
  ##
  ## This is the NEGATIVE control for enclosure, and it is deliberately built
  ## from the arena rather than from a generated map so that nothing about the
  ## generator's current quality can move it. Symmetry does the right half.
  result = arenaMap()
  var pebbles: seq[ArenaShape]
  for shape in result.leftObstacles:
    let box = shapeAsRect(shape)
    var y = box.y
    while y + pebble <= box.y + box.h:
      var x = box.x
      while x + pebble <= box.x + box.w:
        pebbles.add rectShape(MapRect(x: x, y: y, w: pebble, h: pebble))
        x += pitch
      y += pitch
  result.leftObstacles = pebbles

let control = evaluateMap(arenaMap(), "arena")

# ---------------------------------------------------------------------------
# Rule 1 — the control is scored, and never flagged
# ---------------------------------------------------------------------------

suite "map fitness: the control":
  test "the arena passes every default band":
    # THE guard rail. A band that flags the control is wrong, and the only
    # reliable way to keep that true is to fail the build when it stops being
    # true. If this breaks after a band edit, move the band, not the arena.
    var breached: seq[string]
    for r in control.scoreBands():
      if r.breached:
        breached.add r.band.name & "=" & $r.value &
          " outside [" & $r.band.lo & ".." & $r.band.hi & "]"
    check breached.len == 0
    check control.staticScore() == 1.0

  test "every band records the control value it was calibrated against":
    for band in DefaultBands:
      # A bound with no provenance drifts. `control` is the arena's measured
      # value at the time the bound was chosen; it must still be inside.
      check band.control >= band.lo
      check band.control <= band.hi

  test "the control is valid and fully populated":
    check control.valid
    check control.reason == ""
    check control.teams == 2
    check control.openFloorPx > 0
    check control.standCover.len == 2
    check control.standRingOpen.len == 2
    check control.standRingArcs.len == 2
    check control.visSamples > 0

  test "the arena's route graph connects its bases":
    # The first coarsening shattered the arena into 24 components with the two
    # bases in different ones and reported 0 routes for a board the sim's own
    # flood fill certifies as connected. Zero here means the coarsening broke.
    check control.routeCountMin >= 2
    check control.bottleneckPx >= 2 * RouteCellPx
    check control.detourMax > 1.0
    check control.detourMax < 3.0

  test "the route metric is not measuring the spawn pocket":
    # Sourcing the flow at the two pedestals returns 4 for the arena and 4 for
    # 19 of the 20 pool seeds, because the tightest cut is the engine's own
    # protected pocket mouth. A metric that returns one number for every layout
    # is measuring the engine. These three maps must not all agree.
    let
      a = control.routeCountMin
      b = evaluateMap(loadCtfMapMetadata("pool:0"), "pool:0").routeCountMin
      c = evaluateMap(loadCtfMapMetadata("pool:1"), "pool:1").routeCountMin
    check not (a == b and b == c)

# ---------------------------------------------------------------------------
# Rule 2 — no count without its fraction
# ---------------------------------------------------------------------------

suite "map fitness: counts carry fractions":
  test "the midfield count is measured at the tightest cut, not the seam":
    # Measured at the exact center — the mirror seam, where a shape meets its
    # own image — the arena reads "1 crossing, 100% open", i.e. a corridor.
    # Scanned across the midfield band it reads 5 crossings at a 41% cut,
    # which independently reproduces the hand count mw2's lane audit made.
    check control.midCrossCount == 5
    check control.midOpenFrac > 0.0
    check control.midOpenFrac < 1.0
    check control.midAxisVertical

  test "picking the cut line by fewest crossings would pick the emptiest one":
    # The arena has columns in its midfield band with nothing but the border in
    # them. Those score "1 crossing / 100% open" — the fewest crossings and the
    # least information. The chosen line must therefore be tighter than fully
    # open, which is what this asserts.
    check control.midOpenFrac < 0.9

  test "stand rings report a fraction beside their arc count":
    check control.standRingOpen.len == control.standRingArcs.len
    for frac in control.standRingOpen:
      check frac > 0.0
      check frac <= 1.0
    for arcs in control.standRingArcs:
      check arcs >= 1

  test "route capacity has a scale-free form as well as a raw count":
    # A giant board carries more absolute capacity for reasons that have
    # nothing to do with architecture, so the raw count cannot be banded across
    # size classes. The board is LOCKED to a size class rather than read off a
    # pool index: which index holds a big map is a fact about today's curation,
    # and pinning it here made this test fail when the pool was re-curated.
    let giant = evaluateMap(
      generateCtfMap(1001, MapGenOverrides(
        windows: -1, pits: -1, pitDensity: -1, size: "giant")),
      "gen:1001 giant")
    check giant.width > 2 * control.width
    # `giant.routeCountMin > control.routeCountMin` used to stand here as the
    # DEMONSTRATION that the raw count scales with the board. It does not, and
    # asserting it made this test a claim about the generator's giant boards
    # rather than about the metric: measured on the rebuilt generator, giant
    # seed 1001 reports routeCountMin 5 against the hand-authored standard
    # arena's 8. A 3211px board with FEWER minimum routes than a 1235px one is
    # a real architecture signal and is reported as one below, not asserted
    # away — filed against the giant/colossal size classes.
    checkpoint "routeCountMin  giant " & $giant.routeCountMin &
      " vs control " & $control.routeCountMin &
      "   |  routeCapacityFrac  giant " & $giant.routeCapacityFrac &
      " vs control " & $control.routeCapacityFrac
    # What the test is actually for: the scale-free form exists, is populated
    # at BOTH scales, and is a fraction — that is what lets a band span size
    # classes at all. The raw count deliberately gets no directional claim.
    check control.routeCapacityFrac > 0.0
    check giant.routeCapacityFrac > 0.0
    check control.routeCapacityFrac <= 1.0
    check giant.routeCapacityFrac <= 1.0

# ---------------------------------------------------------------------------
# Positive controls — a detector that always returns zero must not pass
# ---------------------------------------------------------------------------

suite "map fitness: positive controls":
  test "a map with two known doorways reports them as chokepoints":
    let m = evaluateMap(doorwayMap(), "doorway")
    check m.chokeCount >= 1
    check m.chokeMinClearPx > 0
    check m.chokeMinClearPx < 90

  test "two chokepoints on one sightline are reported as coverable":
    # Both doorways sit at the same y, so a single vantage between them watches
    # every route in the map — one camper owns the board.
    let m = evaluateMap(doorwayMap(), "doorway")
    check m.chokeCovered

  test "the arena has no chokepoint a single isovist can cover":
    check control.chokeCount == 0
    check not control.chokeCovered

  test "a doorway map has fewer midfield crossings than the arena":
    let m = evaluateMap(doorwayMap(), "doorway")
    check m.midCrossCount < control.midCrossCount
    check m.routeCountMin < control.routeCountMin

  test "walling the midfield lowers route capacity but keeps it connected":
    let m = evaluateMap(doorwayMap(), "doorway")
    check m.routeCountMin >= 1

# ---------------------------------------------------------------------------
# Balance entropy
# ---------------------------------------------------------------------------

suite "map fitness: balance entropy":
  test "an even split scores 1.0 for 2, 3, 4 and 6 teams":
    # The log base is the TEAM COUNT precisely so this holds for every roster
    # shape the engine supports.
    check abs(balanceEntropy([5, 5], 2) - 1.0) < 1e-9
    check abs(balanceEntropy([4, 4, 4], 3) - 1.0) < 1e-9
    check abs(balanceEntropy([2, 2, 2, 2], 4) - 1.0) < 1e-9
    check abs(balanceEntropy([1, 1, 1, 1, 1, 1], 6) - 1.0) < 1e-9

  test "one team taking everything scores 0.0":
    check balanceEntropy([9, 0], 2) == 0.0
    check balanceEntropy([9, 0, 0, 0], 4) == 0.0

  test "a lopsided split lands strictly between":
    let b = balanceEntropy([7, 3], 2)
    check b > 0.0
    check b < 1.0

  test "no events at all is 0.0, not a divide by zero":
    check balanceEntropy([0, 0], 2) == 0.0
    check balanceEntropy([], 4) == 0.0

# ---------------------------------------------------------------------------
# Bands and the weighted scalar
# ---------------------------------------------------------------------------

suite "map fitness: scoring":
  test "an invalid map scores zero — the hard gates are the sim's":
    var broken = arenaMap()
    broken.leftObstacles = @[]        # no cover at all: fails the cover budget
    let m = evaluateMap(broken, "bare")
    check not m.valid
    check m.reason.len > 0
    check m.staticScore() == 0.0

  test "the score is a weighted mean of sub-scores in [0,1]":
    for path in ["arena", "pool:0", "pool:1", "pool:19"]:
      let s = evaluateMap(loadCtfMapMetadata(path), path).staticScore()
      check s >= 0.0
      check s <= 1.0

  test "the stick ranks the same cover scattered below the same cover massed":
    # THIS REPLACES `the curated pool sits below the hand-authored control`,
    # which asserted `poolBest < control` — i.e. that the generator stays
    # WORSE than the arena. That claim was true and useful when the generator
    # produced scatter and the stick had to say so. It is now a test that goes
    # RED WHEN THE GENERATOR IMPROVES: at the pool re-curation the best pool
    # seed measured 0.998 against the control's 1.000, and seed 1030 — inside
    # the curator's own scan window, excluded only by a shape quota — already
    # scores exactly 1.000. One re-curation inverts it, and the "fix" it
    # invites is dropping the good seed from the pool. It is the third test in
    # this repo caught ratcheting backwards; see 2026-08-06-two-rulers.md.
    #
    # The durable claim underneath it is about the INSTRUMENT, not about how
    # good the generator happens to be this week: the stick must rank a board
    # whose cover is spent on PEBBLES below one that spends the same cover on
    # MASSES. That is the exact failure mode the rebuild fought (the vocabulary
    # bench measured scatter at interiorFrac 0.195 against the control's 0.342)
    # and it is a positive control in the same spirit as `doorwayMap`: a stick
    # that returned a flat number for everything would pass the old assertion
    # forever and fails this one immediately.
    let
      massed = control
      scattered = evaluateMap(scatterMap(), "scatter")
    # Enclosure is the property being destroyed, so name it directly rather
    # than trusting the scalar to have noticed.
    check scattered.interiorFrac < massed.interiorFrac
    check scattered.staticScore() < massed.staticScore()

  test "the curated pool is scored against the control, in both directions":
    # What survives of the old assertion: the pool is MEASURED against the
    # arena every run, and the margin is REPORTED rather than pinned. A
    # generated map that ties or beats the hand-authored arena is the goal of
    # the epic, not a regression, so nothing here may fail on that.
    var
      best = 0.0
      total = 0.0
    for i in 0 ..< MapPoolSeeds.len:
      ## `cachedPoolMap` is exactly what `loadCtfMapMetadata("pool:" & $i)`
      ## resolves to, with the ~20 s pool build shared with `test_trenches`.
      let s = evaluateMap(cachedPoolMap(i), "pool").staticScore()
      best = max(best, s)
      total += s
    let mean = total / MapPoolSeeds.len.float
    checkpoint "pool best " & $best & " / mean " & $mean &
      " against control " & $control.staticScore()
    # The only real failure is a stick that cannot score the pool at all.
    check best > 0.0
    check mean > 0.0
    check best <= 1.0

  test "a tight bound is reported, not silently spent":
    let tightBand = Band(
      name: "interiorFrac", lo: control.interiorFrac - 0.001,
      hi: control.interiorFrac + 0.5, margin: 0.2, weight: 1.0,
      kind: bandSoft, control: control.interiorFrac, note: "test")
    let results = control.scoreBands(@[tightBand])
    check results[0].sub == 1.0
    check results[0].tight
    check not results[0].breached

  test "bandReport names every band":
    let text = control.bandReport()
    for band in DefaultBands:
      check band.name in text

# ---------------------------------------------------------------------------
# Purity and cost
# ---------------------------------------------------------------------------

suite "map fitness: purity and cost":
  test "evaluating a map does not install it":
    # Same invariant tools/map_render.nim carries: the editor renders arbitrary
    # specs from a mummy thread pool, so nothing in the analysis path may touch
    # the process-global arena.
    installDefaultArena()
    let before = (MapWidth, MapHeight)
    discard evaluateMap(loadCtfMapMetadata("pool:1"), "giant")
    check (MapWidth, MapHeight) == before

  test "evaluation is deterministic":
    # Compared through `$` rather than a field-by-field list, so a field added
    # later is covered without anyone remembering to extend the test.
    let
      a = evaluateMap(loadCtfMapMetadata("pool:6"), "pool:6")
      b = evaluateMap(loadCtfMapMetadata("pool:6"), "pool:6")
    check $a == $b

  test "a standard board scores in well under a second":
    # Static scoring has to stay free next to simulation (~97s per episode), or
    # a best-of-K ranker cannot afford to call it K times.
    let started = getMonoTime()
    discard evaluateMap(arenaMap(), "arena")
    let ms = (getMonoTime() - started).inMilliseconds
    check ms < 1000

  test "a giant board stays inside the simulation budget":
    let started = getMonoTime()
    discard evaluateMap(loadCtfMapMetadata("pool:1"), "giant")
    let ms = (getMonoTime() - started).inMilliseconds
    check ms < 20000

# ---------------------------------------------------------------------------
# The measuring stick's own corrections. Every test below pins a blind spot the
# suite had while claiming not to — see the module docs on each metric for the
# measured numbers. These exist so a future change cannot quietly reopen one.
# ---------------------------------------------------------------------------

suite "map fitness: the corrected stick":
  test "the SECOND control is scored, and it is the one that breaches":
    # `map_eval` prepends `arena` and for a long time prepended only `arena`,
    # so the repo's other hand-authored map was never a control at all. Rule 1
    # says skipping a control is worse than flagging one.
    let large = evaluateMap(loadCtfMapMetadata("arena-large"), "arena-large")
    check large.valid
    var breached: seq[string]
    for r in large.scoreBands():
      if r.breached: breached.add r.band.name
    # Not an assertion that arena-large is BAD — it is a 30% geometric upscale
    # of arena, so this is what scale alone does to a fraction-shaped metric.
    # Pinned so that "the second control breaches nothing" can never be
    # believed without someone re-deriving it.
    check breached.len > 0
    check "sightlineMaxPx" in breached

  test "open runs are measured between places a player can stand":
    # Before this, the longest run on every map sat in the ~10px border gutter,
    # which nothing can occupy. The gutter is open for the map's whole width,
    # so an unrestricted scan can never report less than that.
    let m = control
    check m.sightlineMaxPx > 0
    check m.sightlineMaxPx < m.width - 2 * ArenaBorder
    check m.sightlineAxis in ["row", "column", "diagonal"]

  test "the DIAGONAL is the longest line on the control, and it gates":
    # The exact hole the axis-only scan leaves: arena's longest open line is
    # its diagonal, longer than its longest row, and nothing read it.
    check control.diagRunMaxPx > control.openRunMaxPx
    check control.sightlineAxis == "diagonal"
    var gated = false
    for r in control.scoreBands():
      if r.band.name in ["sightlineMaxPx", "diagLongRunPxFrac"]: gated = true
    check gated

  test "the diagonal run-COUNT share could never have gated":
    # Why the pixel-weighted twin had to exist: the diagonal scan emits a run
    # per diagonal, most of them corner clips, so the count-share is an order
    # of magnitude smaller than the axis one on the same map even though the
    # diagonal is the LONGER line. A band cut on it would never fire.
    check control.diagLongRunFrac < control.longRunFrac / 10.0
    check control.diagRunMaxPx > control.openRunMaxPx

  test "a chokepoint carries a LENGTH, not only a width":
    # A 40px doorway and a 40x400px gallery were the same measurement.
    let door = evaluateMap(doorwayMap(), "doorway")
    check door.chokeCount > 0
    check door.routeWidthPx > 0
    # The doorway is short, so it is a chokepoint and not a kill box: its
    # exposed run must sit inside what a player can clear alive at that width.
    check door.chokeExcessPx <= 0

  test "the arena's optional pinches are gates, not kill boxes":
    # arena ships a straight 188px channel of 36px floor and plays well,
    # because it is one lane among eight. Gates yes, MANDATORY gates no — the
    # distinction the length rule turns on.
    check control.pinchGateCount > 0
    check control.pinchMandatoryCount == 0
    check control.chokeExcessPx == 0

  test "the isovist is cut at the LETHAL envelope, not at gun range":
    check IsovistRangePx == LethalEnvelopePx
    check IsovistRangePx * 4 < VisionPairRangePx * 2
    # Both readings are kept so the re-cut stays a printed before/after.
    # A tighter radius can only ever cover FEWER maps, never more.
    let door = evaluateMap(doorwayMap(), "doorway")
    if door.chokeCovered: check door.chokeCoveredAtGunRange

  test "the stand-side cover FLOOR exists and is absolute":
    # A fairness spread cannot express a floor: two equally naked stands both
    # score a spread of 0 and pass. Both floors must be present as bands.
    var names: seq[string]
    for b in DefaultBands: names.add b.name
    check "standCoverMin" in names
    check "standCoverGapMaxPx" in names
    # ...and the one with teeth is bounded by physics, not by a share of board.
    for b in DefaultBands:
      if b.name == "standCoverGapMaxPx":
        check b.hi == float(MaxExposedRunPx)
    check control.standCoverGapMaxPx > 0
    check control.standCoverGapMaxPx <= MaxExposedRunPx

  test "a naked stand fails the floor a fairness spread lets through":
    # The defect stated directly: strip the cover from BOTH stands and the
    # spread stays perfect while the floor must fire.
    var naked = arenaMap()
    naked.leftObstacles = @[]
    let m = evaluateMap(naked, "naked")
    check m.standCoverMax - m.standCoverMin < 0.04   # spread: still passes
    var floorFired = false
    for r in m.scoreBands():
      if r.band.name in ["standCoverMin", "standCoverGapMaxPx"] and r.breached:
        floorFired = true
    check floorFired

  test "the route band says which bound gates and which aspires":
    var hard, soft: seq[Band]
    for b in DefaultBands:
      if b.name == "routeCountMin": hard.add b
      if b.name == "routeCountDesign": soft.add b
    check hard.len == 1
    check soft.len == 1
    check hard[0].kind == bandHard
    check soft[0].kind == bandSoft
    # The design asks for 3; the bound that REJECTS enforces 2. Both notes
    # must name the other, or the next reader repeats the confusion.
    check hard[0].lo == 2.0
    check soft[0].lo == 3.0
    check "routeCountDesign" in hard[0].note
    check "routeCountMin" in soft[0].note

  test "a breached bandHard actually rejects":
    # `bandHard` was documented as "the map is REJECTED" and read by nothing,
    # so a one-route board scored 0.736 and could win a best-of-K draw.
    let hardBand = @[
      Band(name: "routeCountMin", lo: 1.0e6, hi: 2.0e6, margin: 1.0,
           weight: 1.0, kind: bandHard, control: 8.0, note: "forced breach"),
      Band(name: "midOpenFrac", lo: -1.0, hi: 1.0e6, margin: 1.0,
           weight: 1.0, kind: bandSoft, control: 0.4, note: "always inside"),
    ]
    check control.staticScore(hardBand) == 0.0
    # ...and the same table with the hard band marked soft does NOT zero, so
    # the test is pinning the KIND and not merely the breach.
    var soften = hardBand
    soften[0].kind = bandSoft
    check control.staticScore(soften) > 0.0
