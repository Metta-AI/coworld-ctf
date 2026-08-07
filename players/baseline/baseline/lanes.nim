## The reference policy's LANE geometry, extracted so a test can hold it to the
## sim instead of restating it.
##
## Sibling of `endzones.nim`, and it exists for the same reason one step later.
## `endzones.nim` fixed where a carry SCORES; this is about where the flankers
## STAND. Both are absolute pixel offsets the policy derives from the board's
## dimensions, and the hexagon is unforgiving of that in a way the rectangle
## never was: on a rectangle, `y = 40` was floor for the board's whole width,
## so an x offset could not be wrong. On a hexagon the width AT that row is a
## function of the size class.
##
## `tools/policy_lane_probe.nim` measured it over 11 boards. From the standard
## class up, all 8 posts are floor — the flat top edge of a flat-top hexagon
## reaches `width/4` from centre, which is 280px at standard against a
## `FlankDepth` of 260, so **20 pixels of margin**. On the SMALL class, 951px
## wide, that edge reaches only ~238px and all four flank posts land inside the
## hull's border ring, on both seeds tested. Structural — a property of the
## class, not of the terrain.
##
## Nothing crashed and nothing logged. Two of six seats walked at a wall for
## the whole episode.
##
## So the constants live here, and `tests/test_policy_lanes.nim` asks the SIM's
## own walkability predicate about the points they produce, on every size class
## the generator can draw. A test that recomputed the offsets itself would have
## passed against the broken policy too.

const
  LaneInset* = 40
    ## `LaneTop` = this, `LaneBottom` = height - this. The open corridors above
    ## and below the mirrored obstacles on the old rectangular board.
  FlankDepth* = 260
    ## How far past centre the wide flankers run, in px. Also settable at
    ## compile time in `baseline.nim` via `-d:tuneFlankDepth=N`; this is the
    ## shipped default and the value the test measures against.
  StandoffDepth* = 200
    ## The counter-punch stations' offset from centre, in px.

import ctf/hex

const HullMargin* = 12
  ## How much daylight a lane post keeps between itself and the hull, in px.
  ## `ArenaBorder` is 10, so this clears the border ring by 2 — enough that the
  ## post is standable rather than merely inside the hexagon.

proc laneDepth*(depth, width, height, y: int): int =
  ## `depth` px from centre along row `y`, pulled in until the point clears the
  ## hull. Returns `depth` unchanged wherever the board affords it, which is
  ## every class from standard up.
  ##
  ## SCANNED against `insideHex` / `hexEdgeDist`, the engine's own boundary
  ## predicate, rather than derived from trigonometry — the same choice
  ## `arena.nim`'s `homeDepthWindow` makes, and for the same reason: a closed
  ## form has to be re-derived for every orientation and cannot go stale
  ## quietly, whereas this cannot go stale at all. The policy imports
  ## `ctf/hex`, which is pure and pulls in only `std/math`, so the bot binary's
  ## dependency cone is unchanged.
  let
    board = hexBoard(width, height)
    cx = width div 2
  result = depth
  while result > 0:
    if board.insideHex(cx - result, y) and
        board.hexEdgeDist(cx - result, y) >= float(HullMargin) and
        board.insideHex(cx + result, y) and
        board.hexEdgeDist(cx + result, y) >= float(HullMargin):
      return
    dec result

proc lanePosts*(width, height: int): seq[tuple[name: string, x, y: int]] =
  ## Every point the flank and standoff roles steer to on a `width x height`
  ## board, both team sides, with the depth already pulled inside the hull.
  ##
  ## These are UNCONDITIONAL targets — unlike the carrier's lane pick, which
  ## since GV38 charges a lane for every unwalkable sample and so retires a
  ## wall lane on its own. That is why the clamp lives here rather than being
  ## left to the runtime snap: on the small class the raw post is outside the
  ## hull on EVERY seed, and no snap radius is defined to cross a border ring
  ## the map can never open.
  let cx = width div 2
  for (label, dx) in [("flank", FlankDepth), ("standoff", StandoffDepth)]:
    for sign in [-1, 1]:
      for (lane, y) in [("Top", LaneInset), ("Bottom", height - LaneInset)]:
        result.add((label & lane & (if sign < 0: "W" else: "E"),
                    cx + sign * laneDepth(dx, width, height, y), y))
