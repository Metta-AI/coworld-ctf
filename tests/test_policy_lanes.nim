## The reference policy's LANE posts, held to the sim's own walkability.
##
## Sibling of `test_policy_endzones.nim`, one step further into the same
## mistake. That one guards where a carry SCORES; this guards where the
## flankers STAND. Both are absolute pixel offsets the policy derives from the
## board's dimensions, and both were safe on a rectangle for a reason that
## stopped being true: on a rectangle `y = 40` was floor for the board's whole
## width, so an x offset could not be wrong. On a hexagon the width AT that row
## is a function of the size class.
##
## As with the endzone test, this does NOT restate the policy's geometry — it
## imports `baseline/lanes`, runs the policy's own offsets, and asks the SIM
## whether the resulting points are floor. A test that recomputed the offsets
## itself would have passed against the broken policy too.
##
## The failure it was written for, measured with `tools/policy_lane_probe.nim`:
## on the SMALL class (951x824) all four flank posts sit inside the hull's
## border ring, on both seeds tested. Two of six seats walked at a wall for a
## whole episode, with no crash and no log line.
import
  std/[strformat, unittest],
  ctf/[arena, sim, sim_types],
  ../players/baseline/baseline/lanes

proc boardsBySizeClass(): seq[tuple[label: string, gameMap: CtfMap]] =
  ## Every size class a random draw may pick, plus both hand-authored arenas.
  ## The classes are what matter — the flank offsets are absolute pixels, so
  ## the class WIDTH is what decides whether they clear the hull's shoulder —
  ## but the two authored boards are in because they are what the league
  ## actually seats.
  result.add(("arena", loadCtfMapMetadata("arena")))
  result.add(("arena-large", loadCtfMapMetadata("arena-large")))
  var seed = 7001
  for size in HexSizeNames:
    var config = defaultGameConfig()
    config.teams = 2
    config.mapPath = "gen"
    config.mapSeed = seed
    config.mapGen.size = size
    result.add((&"gen:{seed} ({size})", resolveCtfMapMetadata(config)))
    inc seed

suite "policy lane geometry":
  test "every flank and standoff post is ON THE PLAYFIELD":
    ## The hull, not the terrain. A post inside an obstacle is ordinary — the
    ## policy's cover snap walks off it — but a post OUTSIDE the hexagon is
    ## permanent on every seed of that class, and no snap radius is defined to
    ## reach across a border ring the map can never open.
    for (label, gameMap) in boardsBySizeClass():
      let board = gameMap.mapBoard()
      for (name, x, y) in lanePosts(gameMap.width, gameMap.height):
        checkpoint &"{label} {gameMap.width}x{gameMap.height}: {name} " &
          &"({x},{y}) is off the hexagon"
        check x >= 0 and x < gameMap.width
        check y >= 0 and y < gameMap.height
        ## `insideHex` is the hull; the border ring is a further `ArenaBorder`
        ## px of wall inside it, and a post in the ring is just as unreachable
        ## as one in the void — so the margin is asserted, not just membership.
        check board.insideHex(x, y)
        check board.hexEdgeDist(x, y) >= float(ArenaBorder)

  test "the clamp is a NO-OP from the standard class up":
    ## The other half of the contract, and the one that keeps the clamp
    ## honest: it must rescue the small class WITHOUT quietly re-tuning every
    ## other board. If a future change starts pulling standard-class flankers
    ## in, that is a behaviour change to the shipped policy and it should have
    ## to argue for itself here rather than arrive as a side effect.
    for size in ["standard", "large", "huge", "giant"]:
      let (w, h) = (hexBoardOf(size).width, hexBoardOf(size).height)
      for (depth, y) in [(FlankDepth, LaneInset), (FlankDepth, h - LaneInset),
                         (StandoffDepth, LaneInset),
                         (StandoffDepth, h - LaneInset)]:
        checkpoint &"{size}: depth {depth} at y={y} was clamped"
        check laneDepth(depth, w, h, y) == depth

  test "the SMALL class is the one that needed it, and by how much":
    ## Names the arithmetic so the clamp cannot become a mystery. A flat-top
    ## hexagon's top edge reaches `(width - 1) / 4` from centre; `FlankDepth`
    ## is an absolute 260px, and the two cross between small and standard.
    let
      small = hexBoardOf("small")
      standard = hexBoardOf("standard")
    check (small.width - 1) div 4 < FlankDepth
    check (standard.width - 1) div 4 > FlankDepth
    ## So small clamps and standard does not — measured, not asserted from the
    ## inequality above, because the hull widens over the 40px lane inset and
    ## that widening is exactly what decides it.
    check laneDepth(FlankDepth, small.width, small.height, LaneInset) <
      FlankDepth
    check laneDepth(FlankDepth, standard.width, standard.height, LaneInset) ==
      FlankDepth
