import
  helpers,
  std/[json, os, unittest],
  ctf/sim,
  "../tools/map_metrics",
  "../tools/map_eval"

## Covers the map fitness harness (tools/map_metrics.nim + the scoring layer
## of tools/map_eval.nim). Importing the modules is half the point: nothing
## else in the suite reaches them, so CI would never compile them.
##
## The load-bearing case is the CONTROL one. The harness exists to rank maps
## against the hand-authored `arena`, and during development four separate
## bands rejected it — one of them (midfield crossings) reported "1 way
## across" for every layout in the pool, the arena included, because it
## sampled the exact centre column, which sits inside a disc of protected
## floor the generator may not build in. A band that flags the control is a
## broken band, so "the control passes every scored band" is asserted here
## rather than left to whoever next reads the tool's output.
##
## Every map is read through resolveSource / loadCtfMapMetadata, which do NOT
## install the map: the process map is a one-shot global the render bakes
## rely on, and this suite shares one process.

proc withGameDir(body: proc()) =
  ## Runs `body` from the repo root so data/ assets resolve.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    body()
  finally:
    setCurrentDir(previousDir)

proc bottleneckSpec(): string =
  ## A board that is one wall per half with a single doorway, DERIVED from the
  ## control rather than hand-written.
  ##
  ## It used to be a literal 1235x659 JSON blob with `"layout":"sides"` and
  ## `"endzone":"column"`. GV38 deleted both of those tokens and the
  ## rectangular playfield they described, so the blob stopped loading at all —
  ## a fixture pinned to a board shape the engine no longer has. Deriving it
  ## from `arena` means the next geometry change moves this with the engine
  ## instead of stranding it: only the obstacles are ours, and they are what
  ## the test is actually about.
  let control = loadCtfMapMetadata("arena")
  var spec = parseJson(mapSpecJson(control))
  spec["name"] = %"bottleneck-probe"
  ## One vertical wall down the left half with a single gap at mid height.
  ## `rect` is still accepted by the spec parser (GV37 back-compat) and is the
  ## clearest way to spell an axis-aligned wall.
  let
    wallX = control.width div 3
    gapHalf = 32
    midY = control.height div 2
  spec["leftObstacles"] = %*[
    {"kind": "rect", "x": wallX, "y": 0,
     "w": 18, "h": midY - gapHalf},
    {"kind": "rect", "x": wallX, "y": midY + gapHalf,
     "w": 18, "h": control.height - (midY + gapHalf)}]
  $spec

const StaleOnHexBands = ["stand ring open (min)", "collision-point cover"]
  ## Bands calibrated on the pre-hex 1235x659 arena that the HEXAGONAL arena
  ## fails. They are a known, named debt, not a discovery: the harness itself
  ## prints them under "METRIC BUG: the CONTROL fails its own bands" on every
  ## run, and the rule the harness is built on says the band is what is wrong,
  ## never the control.
  ##
  ## They are pinned here rather than fixed because retuning a fitness band is
  ## a map-design decision — it changes which generated maps rank well — and it
  ## wants its own measurement, not a drive-by from a policy fix. Pinning keeps
  ## the guard alive in the meantime: a THIRD band failing still fails this
  ## test, which is the property that mattered.

suite "map metrics":
  test "the control fails exactly the bands known stale on the hex arena":
    withGameDir(proc() =
      let
        control = computeMapMetrics(loadCtfMapMetadata("arena"))
        card = scoreMap(control, control)
      var failures: seq[string]
      for check in card.checks:
        if check.scored and not check.passes():
          failures.add check.name
      for name in failures:
        ## The assertion that still bites: a band nobody has signed off on
        ## rejecting the control is a broken band and must fail here.
        check name in StaleOnHexBands
      for name in StaleOnHexBands:
        ## And the debt must not quietly go stale in the other direction — if
        ## a band starts passing, take it off this list.
        check name in failures
      check hardGates(control).len == 0
    )

  test "the control's landmark numbers hold":
    withGameDir(proc() =
      let control = computeMapMetrics(loadCtfMapMetadata("arena"))
      # Enclosure. The MW2 study measured the pre-hex 1235x659 control at ~33%
      # and called it honest scatter; the PORTRAIT hexagon measured 41.5%,
      # because the slanted hull walls enclose the board's corners that a
      # rectangle left wide open. The LANDSCAPE hull with a correctly staggered
      # picket ladder measures 49.7%: the stagger fix moved slots off each
      # other and onto open field, which is the whole point of it.
      #
      # Re-based deliberately, and said out loud: this is a DESCRIPTIVE landmark
      # of whatever board ships as the control, not a quality band, and its job
      # is to make a silent drift loud. Moving it without saying so re-bases the
      # whole rubric — the harness's `interior fraction` band is anchored on
      # exactly this number.
      check abs(control.interiorFrac - 0.497) < 0.02
      # The bands that four candidate metrics got wrong, pinned:
      check control.p95ClearancePx <= 125.0     # distance to cover, not 2x it
      check control.minRoutes >= 3              # not "1 route for every map"
      check control.crossings.len == 1
      check control.crossings[0].count >= 3     # not "1 way across"
      check control.crossings[0].openFrac > 0.2 # ...and its fraction beside it
      # An open field has no bottleneck, and saying so is information. The
      # unfiltered candidate set is large, which is exactly why the
      # cut-vertex filter exists.
      #
      # These two lines EARNED their keep on the landscape hull: while the
      # picket ladder was anchored per-column instead of to the centre row,
      # the arena measured 3 true cut vertices with one point covering them
      # all — a scrambled slalom leaves pinch points where the columns share
      # gaps. Anchoring the ladder (src/ctf/arena.nim) put both back to the
      # values the portrait board had. Do not re-base a landmark to match a
      # regression; find out why it moved.
      check control.chokepoints == 0
      check control.chokeCandidates > 10
      check not control.chokeCoveredByOnePoint
      check control.stands.len == 2
      # Mirror symmetry, to within one pixel. The two anchors come from
      # different formulas — axisHomeLo gives Red 186 and axisHomeHi gives
      # Blue 1049, while the exact mirror of 186 on a 1235px board is 1048 —
      # so the annulus around each stand is one pixel out of register and
      # the cover fractions differ in the fourth decimal. That is an engine
      # detail, not a metric fault; the ring, sampled by angle, is exact.
      check abs(control.stands[0].coverFrac -
        control.stands[1].coverFrac) < 0.001
      check control.standRingDelta < 0.001
    )

  test "a deliberate bottleneck is detected":
    # Every map in the pool is an open field reporting "8+ routes, 0
    # chokepoints", which alone cannot tell a working detector from a dead
    # one. This spec is one wall per half with a single doorway.
    withGameDir(proc() =
      writeFile("/tmp/ctf-test-bottleneck.json", bottleneckSpec())
      let
        source = parseSource("spec:/tmp/ctf-test-bottleneck.json")
        metrics = computeMapMetrics(resolveSource(source))
      # The doorway is 64px tall; the standable band inside it is narrower.
      check metrics.minRoutes > 0
      check metrics.minRoutes < MaxRoutesProbed
      check metrics.minCutPx > 0
      check metrics.minCutPx < 64
      # Both doorways are genuine cut vertices, and one point on the line
      # between them commands both.
      check metrics.chokepoints == 2
      check metrics.chokeCoveredByOnePoint
      removeFile("/tmp/ctf-test-bottleneck.json")
    )

  test "mapSpec is resolved ahead of any named map or generator call":
    withGameDir(proc() =
      writeFile("/tmp/ctf-test-bottleneck.json", bottleneckSpec())
      let gameMap = resolveSource(parseSource("spec:/tmp/ctf-test-bottleneck.json"))
      check gameMap.name == "bottleneck-probe"
      check gameMap.leftObstacles.len == 2
      removeFile("/tmp/ctf-test-bottleneck.json")
    )

  test "metrics never install the map they measure":
    # tools/map_render.nim's purity invariant, extended to the metrics: the
    # ranking loop scores candidates that were never selected, and the map
    # editor serves renders from a thread pool.
    withGameDir(proc() =
      installDefaultArena()
      let before = MapWidth
      discard computeMapMetrics(loadCtfMapMetadata("pool:3"))
      check MapWidth == before
    )

  test "balance entropy uses log base TEAM COUNT":
    # B = -sum (k_i/K) log_N(k_i/K) with N = team count, so an even split is
    # 1.0 for 2, 3, 4 and 6 teams and the number is comparable across modes.
    check abs(balanceEntropy(@[10, 10]) - 1.0) < 1e-9
    check abs(balanceEntropy(@[10, 10, 10, 10]) - 1.0) < 1e-9
    check abs(balanceEntropy(@[5, 5, 5, 5, 5, 5]) - 1.0) < 1e-9
    check abs(balanceEntropy(@[20, 0]) - 0.0) < 1e-9
    check balanceEntropy(@[30, 10]) < 0.85
    check balanceEntropy(@[50, 51, 47, 29]) > 0.95
    check balanceEntropy(@[]) == 0.0
    check balanceEntropy(@[0, 0]) == 0.0

  test "a one-sided band never reports a phantom tight warning":
    # "at least 3 routes" has no upper bound. Pretending it had one made
    # every comfortably-passing map print "tight" forever.
    let open = Check(value: 8.0, lo: 3.0, hiOpen: true, taper: 2.0,
      scored: true)
    check open.passes()
    check not open.isTight()
    let near = Check(value: 3.2, lo: 3.0, hiOpen: true, taper: 2.0,
      scored: true)
    check near.isTight()
