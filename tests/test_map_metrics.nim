import
  helpers,
  std/[os, unittest],
  ctf/sim,
  "../tools/map_eval"

## Covers the map fitness harness: `ctf/map_metrics` (the measurements),
## `ctf/map_score` (the bands, the gates and the best-of-K ranker, both
## re-exported by `ctf/sim`) and the simulation layer of `tools/map_eval`.
## Importing the tool is half the point: nothing else in the suite reaches
## it, so CI would never compile it.
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

const BottleneckSpec = """
{"name":"bottleneck-probe","genSeed":0,"width":969,"height":1119,
 "flagRing":70,"captureClear":210,"spawnClearW":70,"spawnClearH":130,
 "gunRange":1050,"symmetry":"mirrorHex","layout":"hex2","endzone":"disc",
 "endzoneRadius":97,"homeDepth":650,
 "medKitSpawns":[[483,373],[483,746]],
 "medKitCandidates":[[483,373],[483,746]],
 "trenches":[],
 "leftObstacles":[
   {"kind":"rect","x":300,"y":0,"w":18,"h":460},
   {"kind":"rect","x":300,"y":524,"w":18,"h":595}]}
"""
  ## One 18px wall per half, spanning the hull with a single 64px doorway, on
  ## the STANDARD hexagon. It sits at x=300 — left of the flag ring (which
  ## starts at x=414 and is protected floor that would have carved a second
  ## doorway) and right of Red's endzone disc. The mirror gives Blue the
  ## matching wall, so a base-to-base route must pass exactly two doorways.

suite "map metrics":
  test "the control passes every band the harness scores":
    withGameDir(proc() =
      let
        control = computeMapMetrics(loadCtfMapMetadata("arena"))
        card = scoreMap(control, control)
      var failures: seq[string]
      for check in card.checks:
        if check.scored and not check.passes():
          failures.add check.name
      check failures.len == 0
      # A perfect control is not a coincidence: bands are anchored on it.
      check card.score > 0.99
      check hardGates(control).len == 0
    )

  test "the control's landmark numbers hold":
    withGameDir(proc() =
      let control = computeMapMetrics(loadCtfMapMetadata("arena"))
      # Enclosure: the MW2 study measured this same control at ~33% and
      # called it honest scatter. It is the floor every generated map has to
      # clear, so a drift here silently re-bases the whole rubric.
      check abs(control.interiorFrac - 0.325) < 0.02
      # The bands that four candidate metrics got wrong, pinned:
      check control.p95ClearancePx <= 125.0     # distance to cover, not 2x it
      check control.minRoutes >= 3              # not "1 route for every map"
      check control.crossings.len == 1
      check control.crossings[0].count >= 3     # not "1 way across"
      check control.crossings[0].openFrac > 0.2 # ...and its fraction beside it
      # An open field has no bottleneck, and saying so is information. The
      # unfiltered candidate set is large, which is exactly why the
      # cut-vertex filter exists.
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
      writeFile("/tmp/ctf-test-bottleneck.json", BottleneckSpec)
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
      writeFile("/tmp/ctf-test-bottleneck.json", BottleneckSpec)
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
