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
  std/[monotimes, strutils, times, unittest],
  ctf/map_metrics,
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
    # size classes.
    let giant = evaluateMap(loadCtfMapMetadata("pool:1"), "pool:1")
    check giant.width > 2 * control.width
    check giant.routeCountMin > control.routeCountMin
    check control.routeCapacityFrac > 0.0
    check giant.routeCapacityFrac > 0.0

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

  test "the curated pool sits below the hand-authored control":
    # The point of the whole epic, stated as a measurement: today's generator
    # produces scatter, and the measuring stick has to say so before anything
    # tries to fix it.
    var best = 0.0
    for i in 0 ..< 20:
      best = max(best, evaluateMap(
        loadCtfMapMetadata("pool:" & $i), "pool").staticScore())
    check best < control.staticScore()

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
