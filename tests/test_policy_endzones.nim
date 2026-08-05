## The reference policy's answer to "where does a carry SCORE", held against
## the sim's own zone predicate.
##
## This is the regression guard for a bug that has now cost two measurement
## rounds. Both times the policy answered that question with a coordinate it
## DERIVED — a "home column" at `MapW * 150 div 1235` — and both times the
## engine had put the capture zone somewhere that literal does not reach: on 3
## of 8 generated rectangular seeds first, then on every hexagonal board, where
## the zone is a DISC and a column at a lane `y` never enters one.
##
## What makes this test worth having is that it does not restate the policy's
## geometry. It takes the marker the ENGINE emits (`labelEndzone` over the
## sim's own `captureZone`), runs the POLICY's parser and aim over that exact
## string, and asks the SIM's `inCaptureZone` whether the resulting point
## scores. A test that recomputed the disc centre itself would have passed
## against the broken policy too.
import
  helpers,
  std/[sets, strutils, unittest],
  ctf/[arena, global, labels, sim, sim_types],
  ../players/baseline/baseline/endzones

proc markersFor(gameMap: CtfMap): seq[EndzoneMark] =
  ## Every team's endzone marker, spelled exactly as the engine spells it.
  var labels: seq[string]
  for team in gameMap.teams():
    let zone = gameMap.captureZone(team)
    labels.add labelEndzone(teamText(team), LabelEndzoneShapeDisc,
      zone.xLo, zone.yLo, zone.xHi, zone.yHi)
  parseEndzoneMarks(labels)

suite "policy endzone geometry":
  test "the aim SCORES on every map, by the sim's own predicate":
    ## The bug, stated as a test: on each of these boards the retired
    ## `MapW * 150 div 1235` column is checked too, and it must be the thing
    ## that fails — otherwise this map is not exercising the bug and the pass
    ## is vacuous.
    var offBoards = 0
    for (source, seed) in [("arena", 0), ("arena-large", 0), ("gen", 4242),
        ("gen", 1337), ("gen", 2026)]:
      var config = defaultGameConfig()
      config.teams = 2
      config.mapPath = source
      config.mapSeed = seed
      let
        gameMap = resolveCtfMapMetadata(config)
        marks = markersFor(gameMap)
      check marks.len == gameMap.teamCount()
      for team in gameMap.teams():
        let
          i = marks.endzoneIndex(teamText(team))
          zone = gameMap.captureZone(team)
        check i >= 0
        let aim = marks[i].captureAim(0)
        check zone.inCaptureZone(int(aim.x), int(aim.y))
        ## The lane axis is half the bug: a column at ANY lane y must be
        ## checked, not just the zone's own row.
        let column = (if team == Red: gameMap.width * 150 div 1235
                      else: gameMap.width - 1 - gameMap.width * 150 div 1235)
        if not zone.inCaptureZone(column, gameMap.height div 2):
          inc offBoards
      ## Every board's mid-height lane is the ONLY lane the old column could
      ## ever have scored from; the two border lanes never can.
      for team in gameMap.teams():
        let zone = gameMap.captureZone(team)
        check not zone.inCaptureZone((zone.xLo + zone.xHi) div 2, 40)
        check not zone.inCaptureZone((zone.xLo + zone.xHi) div 2,
          gameMap.height - 40)
    ## Not a vacuous pass: the retired literal really is outside the zone on
    ## the generated boards.
    check offBoards > 0

  test "a disc aims at its centre and every probe stays in the box":
    let mark = EndzoneMark(color: "red", shape: LabelEndzoneShapeDisc,
      x0: 100, y0: 200, x1: 300, y1: 400)
    ## A disc is answered by the centre at every tick — no sweep, because the
    ## centre is proven inside.
    for tick in [0, 1, 89, 90, 450, 100_000]:
      check mark.captureAim(tick) == (x: 200.0, y: 300.0)

  test "an UNRECOGNIZED shape token degrades, it does not break":
    ## The additive-vocabulary contract: a token added after this build shipped
    ## must still yield the stated corners. Dropping the marker would send the
    ## carrier back to a derived guess, which is the whole bug.
    var mark: EndzoneMark
    check parseEndzoneMark("endzone red trapezoid 100,200 300,400", mark)
    check mark.shape == "trapezoid"
    check mark.boxCentre() == (x: 200.0, y: 300.0)
    ## It opens at the box centre...
    check mark.captureAim(0) == (x: 200.0, y: 300.0)
    ## ...then sweeps, and every probe is STRICTLY inside the bounding box, so
    ## no probe can wander off the zone's box the way the column did.
    var seen: HashSet[ZonePoint]
    for phase in 0 ..< 5:
      let p = mark.captureAim(phase * UnknownZoneProbeTicks)
      check p.x > float(mark.x0) and p.x < float(mark.x1)
      check p.y > float(mark.y0) and p.y < float(mark.y1)
      seen.incl p
    check seen.len == 5                      # five distinct probes
    ## The cycle is deterministic and closed.
    check mark.captureAim(5 * UnknownZoneProbeTicks) == mark.captureAim(0)

  test "the spectator glow overlay is not mistaken for a zone":
    ## `endzone <color> power <n>` shares the prefix and carries no box. It
    ## splits into three fields, which is what excludes it — the shape
    ## vocabulary is deliberately NOT the discriminator, since that is what
    ## made a new token fatal.
    var mark: EndzoneMark
    check not parseEndzoneMark("endzone red power 3", mark)
    check not parseEndzoneMark("endzone red disc 100,200", mark)
    check not parseEndzoneMark("endzone red disc 100,200 300", mark)
    check not parseEndzoneMark("endzone red disc a,b 300,400", mark)
    check not parseEndzoneMark("player red right", mark)

  test "a colour with no marker reports absent instead of guessing":
    let marks = parseEndzoneMarks(
      ["endzone red disc 100,200 300,400",
       "endzone blue disc 900,200 1100,400"])
    check marks.len == 2
    check marks.endzoneIndex("red") == 0
    check marks.endzoneIndex("blue") == 1
    check marks.endzoneIndex("green") == -1

  test "the emitted shape vocabulary is still one this build recognizes":
    ## Not a duplicate of tests/test_label_contract.nim, which checks that the
    ## marker is EMITTED. This checks the policy side of the same seam: if the
    ## engine's vocabulary grows, the policy's disc fast-path silently stops
    ## applying to the new token and the sweep takes over — correct, but slower
    ## and worth knowing about deliberately rather than discovering in a field
    ## measurement.
    check LabelEndzoneShapes == [LabelEndzoneShapeDisc]
