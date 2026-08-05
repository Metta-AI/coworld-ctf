## The installed map: hand-authored arena geometry (obstacles, anchors,
## spawn pockets, capture zones, shape transforms, spinning-diamond
## fixed-point geometry), the procedural generator + its validators, the
## mapSpec JSON round-trip, the process-global map INSTALL
## (selectCtfMap/loadCtfMap — including the import-time default-arena
## install every consumer relies on), and the per-pixel wall/trench/window
## queries. Stage 3 of docs/plans/2026-08-01-sim-split.md; sim.nim
## re-exports this module, so existing consumers are unchanged.

import
  std/[json, math, strutils],
  jsony, pixie,
  sim_types, hex

import map_pool

export hex

const
  Sqrt3Num* = 265
  Sqrt3Den* = 153
    ## sqrt(3) as the exact rational 265/153 (1.7320261..., 1.4e-5 low). Every
    ## 60-degree geometry that has to be EXACT — hexagonal obstacle membership,
    ## the canonical bar axes — is written against this pair rather than
    ## against `Sqrt3`, for the same reason `pointInPolygon` is integer and the
    ## diagonal test is int64: a float predicate rounds differently under a
    ## mirror and the two halves of the board stop being bit-identical masks.
    ## The kernel's float `Sqrt3` stays where floats are already the answer
    ## (distances, the boundary's normalization).

  BarAxisFlat* = [
    (306, 0), (153, 265), (-153, 265), (-306, 0), (-153, -265), (153, -265)]
    ## The six canonical bar axes, 60 degrees apart in the SCREEN frame,
    ## closed under exact 60-degree rotation: rotating entry `k` by +60 gives
    ## entry `k+1` EXACTLY, because 306*cos60 = 153 and 306*sin60 = 265.0006
    ## rounds into the same rational sqrt(3) the rest of the file uses. A bar
    ## authored on one of these is therefore congruent to all six of its
    ## rotational images, with no float in the loop.

proc barShape*(cx2, cy2, halfLong, halfPerp, axisX, axisY: int;
               window = false): ArenaShape =
  ## An oriented bar from its DOUBLED center, its half-extents (in units of
  ## `|axis|` doubled pixels, see `ArenaShape`), and an integer axis.
  ArenaShape(kind: shapeBar, window: window, cx2: cx2, cy2: cy2,
             halfLong: halfLong, halfPerp: halfPerp, axisX: axisX, axisY: axisY)

proc rectShape*(r: MapRect, window = false): ArenaShape =
  ## The axis-aligned bar covering exactly the pixels of a rectangle — the
  ## replacement for the deleted `shapeRect`, and exact for EVEN extents
  ## because the center is stored doubled. Trenches are stored as shapes and
  ## the generator digs rectangular pits, so this bridge stays.
  barShape(2 * r.x + r.w - 1, 2 * r.y + r.h - 1, r.w - 1, r.h - 1, 1, 0, window)

proc diamondShape*(cx, cy, radius: int, window = false): ArenaShape =
  ## The L1 ball of radius `radius` — the old `shapeDiamond`, expressed
  ## EXACTLY as a bar on the (1, 1) axis. With `halfLong = halfPerp = 2r` the
  ## two slab tests read `|dx + dy| <= r` and `|dx - dy| <= r`, whose
  ## intersection is `|dx| + |dy| <= r`: the same integer predicate, the same
  ## pixels, the same mirror exactness the spinning-diamond art depends on.
  barShape(2 * cx, 2 * cy, 2 * radius, 2 * radius, 1, 1, window)

proc hexShape*(cx, cy, radius: int, flatTop = false,
               window = false): ArenaShape =
  ## A regular hexagonal obstacle: integer center, circumradius in px.
  ArenaShape(kind: shapeHex, window: window, hexCx2: 2 * cx, hexCy2: 2 * cy,
             hexR2: 2 * radius, flatTop: flatTop)

proc asDiamond*(shape: ArenaShape): tuple[ok: bool, cx, cy, radius: int] =
  ## Recognizes the bars that ARE diamonds (see `diamondShape`), which is what
  ## the spinning-obstacle machinery selects on. Returns `ok = false` for every
  ## other shape, including bars on the (1, 1) axis whose center or radius
  ## would not land on integers.
  if shape.kind != shapeBar or shape.halfLong != shape.halfPerp or
      abs(shape.axisX) != 1 or abs(shape.axisY) != 1 or
      shape.halfLong mod 2 != 0 or
      shape.cx2 mod 2 != 0 or shape.cy2 mod 2 != 0:
    return (false, 0, 0, 0)
  (true, shape.cx2 div 2, shape.cy2 div 2, shape.halfLong div 2)

proc barHalfExtents(shape: ArenaShape): tuple[ex2, ey2: int] =
  ## The bar's DOUBLED axis-aligned half-extents, rounded UP so a bounding box
  ## built from them is always a superset of the bar's pixels.
  let
    l = shape.axisX * shape.axisX + shape.axisY * shape.axisY
    sx = shape.halfLong * abs(shape.axisX) + shape.halfPerp * abs(shape.axisY)
    sy = shape.halfLong * abs(shape.axisY) + shape.halfPerp * abs(shape.axisX)
  ((sx + l - 1) div l, (sy + l - 1) div l)

proc validateMapRect(name: string, rect: MapRect, width, height: int) =
  ## Raises if one map rectangle is outside the map.
  if rect.w <= 0 or rect.h <= 0:
    raise newException(CtfError, "Map " & name & " size must be positive.")
  if rect.x < 0 or rect.y < 0 or
      rect.x + rect.w > width or rect.y + rect.h > height:
    raise newException(CtfError, "Map " & name & " is outside the map.")

proc validateMapPoint(name: string, point: MapPoint, width, height: int) =
  ## Raises if one map point is outside the map.
  if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
    raise newException(CtfError, "Map " & name & " is outside the map.")

proc shapeAsRect*(s: ArenaShape): MapRect =
  ## The tight bounding box of one shape — EXACT for an axis-aligned bar, so a
  ## rectangular trench round-trips through `rectShape` unchanged. Trench
  ## generation and the rect-edge trench art work in rectangles; this bridges
  ## them to the shape-typed `trenches` field.
  case s.kind
  of shapeBar:
    let
      (ex2, ey2) = s.barHalfExtents()
      x0 = floorDiv(s.cx2 - ex2, 2)
      y0 = floorDiv(s.cy2 - ey2, 2)
    MapRect(x: x0, y: y0,
            w: ceilDiv(s.cx2 + ex2, 2) - x0 + 1,
            h: ceilDiv(s.cy2 + ey2, 2) - y0 + 1)
  of shapeHex:
    ## A hexagon of circumradius R fits in the R-square either way round.
    let
      r = ceilDiv(s.hexR2, 2)
      x0 = floorDiv(s.hexCx2, 2) - r
      y0 = floorDiv(s.hexCy2, 2) - r
    MapRect(x: x0, y: y0, w: 2 * r + 2, h: 2 * r + 2)
  of shapeDisc:
    MapRect(x: s.cx - s.radius, y: s.cy - s.radius,
            w: 2 * s.radius + 1, h: 2 * s.radius + 1)
  of shapeDiagonal:
    let half = s.thickness div 2 + 1
    MapRect(x: min(s.x0, s.x1) - half, y: min(s.y0, s.y1) - half,
            w: abs(s.x1 - s.x0) + 2 * half, h: abs(s.y1 - s.y0) + 2 * half)
  of shapePolygon:
    if s.points.len == 0:
      MapRect(x: 0, y: 0, w: 0, h: 0)
    else:
      var
        x0 = s.points[0].x
        y0 = s.points[0].y
        x1 = s.points[0].x
        y1 = s.points[0].y
      for p in s.points:
        x0 = min(x0, p.x); y0 = min(y0, p.y)
        x1 = max(x1, p.x); y1 = max(y1, p.y)
      MapRect(x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1)

## THE FIELD-SIZE AXIS. Every ratio below is keyed to the board's SHORT axis
## (its height, i.e. twice the hexagon's apothem), never to its width.
##
## That is not a style choice, it is what survives the orientation flip. Under
## the portrait convention the short axis WAS the width, so these read
## `width`; when the board went landscape the short axis moved to the height
## and the width grew by 2/sqrt(3) for the very same amount of field. Keying to
## the width would have silently inflated every endzone, shout radius and
## grenade range by 15.5% as a side effect of a rendering-orientation decision.
## The apothem is the orientation-independent measure of "how much field", so
## every number here is unchanged across the flip.

proc maxEndzoneRadius*(across: int): int =
  ## The endzone radius ceiling for a board of this SHORT-AXIS extent. The
  ## classic EndzoneRadiusMax was authored for the standard field (it keeps the
  ## two zones clear of the center ring); a bigger board supports a
  ## proportionally larger zone — the generator draws the radius as a fraction
  ## of the same axis, and the oversize classes draw past 220. Smaller boards
  ## keep the classic cap rather than tightening a bound existing configs were
  ## allowed to use.
  max(EndzoneRadiusMax, across * EndzoneRadiusMax div HexStandardHeight)

proc minEndzoneRadius*(across: int): int =
  ## The endzone radius FLOOR for a board of this SHORT-AXIS extent.
  ## `EndzoneRadiusMin` was authored against the old 1235-wide square field and
  ## is a hard 90; the hex classes are smaller across at equal playfield area
  ## (the standard measures 969), so a flat 90 sat ABOVE what the small class's
  ## own radius draw produces and every small-class seed raised instead of
  ## generating.
  ##
  ## Scaled by the short axis, floored at the pedestal art plus a margin —
  ## which is what the constant was protecting in the first place (the pedestal
  ## and its endzone pits have to fit inside the scoring disc).
  max(PedestalCoverSize div 2 + 12,
      min(EndzoneRadiusMin, across * EndzoneRadiusMin div 1235))

proc endzoneFloorAt*(
  x, y, anchorX, anchorY, radius: int, disc: bool
): bool =
  ## Whether a point sits on one endzone's protected floor: the scoring shape
  ## grown by the wall margin, so the ring the carrier crosses is never flush
  ## against a wall.
  let
    grown = radius + EndzoneWallMargin
    dx = abs(x - anchorX)
    dy = abs(y - anchorY)
  if dx > grown or dy > grown:
    return false
  if disc:
    return dx * dx + dy * dy <= grown * grown
  true

proc mapBoard*(gameMap: CtfMap): HexBoard {.inline.} =
  ## The hexagon inscribed in this map's bounding box. ONE boundary predicate
  ## for the whole codebase (`hex.nim`); nothing here re-derives it.
  hexBoard(gameMap.width, gameMap.height)

proc validateMap(gameMap: CtfMap) =
  ## Raises if a loaded map has invalid geometry.
  if gameMap.width <= 1 or gameMap.height <= 1:
    raise newException(CtfError, "Map dimensions must be positive.")
  ## Any group transitive on 3 or 6 spawns contains a 120-degree rotation,
  ## which confines the bounding-box aspect to [sqrt(3)/2, 2/sqrt(3)]. The old
  ## 1235x659 board is at 1.874 — far outside it. Refusing an out-of-band board
  ## here is the hex analogue of the old "rot90 needs a square map" validator,
  ## and it refuses for exactly the same reason: the alternative is a silently
  ## team-unfair obstacle image.
  if not gameMap.mapBoard().aspectOk():
    raise newException(
      CtfError, "A hex arena's bounding box must be within [0.866, 1.155]; " &
        $gameMap.width & "x" & $gameMap.height & " is " &
        formatFloat(gameMap.mapBoard().aspect(), ffDecimal, 3) & ".")
  case gameMap.symmetry
  of symMirrorHex, symRot180:
    if gameMap.layout != layoutHex2:
      raise newException(
        CtfError, "Mirror/rot180 symmetry seats exactly 2 teams.")
  of symKlein4:
    if gameMap.layout != layoutHex4:
      raise newException(CtfError, "Klein-four symmetry seats exactly 4 teams.")
  of symRot120, symRot60:
    ## The 3- and 6-team groups are NOT pixel-exact, so their orbits have to be
    ## walked in cube space and rasterized once. That pipeline is Stage 2b;
    ## refusing here is better than shipping a rounded rotation, which is
    ## precisely the failure the old rot90 validator existed to prevent.
    raise newException(
      CtfError, "rot120 / rot60 symmetry needs the cube-space orbit " &
        "rasterizer (hex Stage 2b); not generated yet.")
  if gameMap.layout == layoutHex6:
    raise newException(
      CtfError, "6-team hex needs the Team enum widened (hex Stage 4).")
  if gameMap.homeDepth != 0 and
      (gameMap.homeDepth < HomeDepthMin or gameMap.homeDepth > HomeDepthMax):
    raise newException(
      CtfError, "Map home depth must be " & $HomeDepthMin & ".." &
        $HomeDepthMax & " permille (0 = the classic " &
        $ClassicHomeDepth & ").")
  if gameMap.endzoneRadius < minEndzoneRadius(gameMap.height) or
      gameMap.endzoneRadius > maxEndzoneRadius(gameMap.height):
    raise newException(
      CtfError, "Map endzone radius must be " &
        $minEndzoneRadius(gameMap.height) & ".." &
        $maxEndzoneRadius(gameMap.height) & " px.")
  validateMapPoint("center", gameMap.center, gameMap.width, gameMap.height)
  for i, room in gameMap.rooms:
    validateMapRect(
      "room " & $i,
      MapRect(x: room.x, y: room.y, w: room.w, h: room.h),
      gameMap.width,
      gameMap.height
    )
  for i, trench in gameMap.trenches:
    validateMapRect(
      "trench " & $i, shapeAsRect(trench), gameMap.width, gameMap.height)

const
  ArenaName = "arena"
  ArenaLargeName = "arena-large"
  ArenaBorder* = 10            ## perimeter wall thickness in px.

  EndzoneApron* = 60
    ## How far past the scoring ring terrain is kept out, so the base's
    ## approaches cannot be sealed.
    ##
    ## DERIVED, and the derivation is why it cannot simply be shrunk to make
    ## room for something else: `collectMapDiagnostics` demands four cardinal
    ## gates at `endzoneRadius + MinCorridorWidth div 2 + 4` (r + 17) be
    ## reachable, an obstacle centred at the apron edge reaches 30px back in
    ## toward the base, and the gate then needs a player half-width of daylight.
    ## 30 + 17 + 13 = 60. Cutting it to 40 seals a gate on 87 of 200 seeds.

  ## Warm CRT-phosphor arena (REPLAY_DESIGN §3 art-lock): neutral-warm grey
  ## polished-concrete floor, warm-stone cover, the two team colors the only
  ## saturated channels — never the cold blue-slate default the house style
  ## forbids.
  ArenaBorderColor* = rgba(44, 34, 25, 255)


proc homeDepthOf(gameMap: CtfMap): int =
  ## The map's home-anchor depth permille, defaulting to the classic 700 so
  ## a zero-valued map (a hand-built test fixture, an old replay spec) keeps
  ## the historical anchors.
  if gameMap.homeDepth > 0: gameMap.homeDepth else: ClassicHomeDepth

proc axisHomeLo(center, depth: int): int =
  ## Returns the low-edge home anchor along one axis: `depth` permille of the
  ## way back from the center (700 = the classic 30%-from-the-edge home-x).
  ## At 700 this is exactly the historical `center * 7 div 10`.
  center - (center * depth div 1000)

proc mapGroup*(gameMap: CtfMap): seq[HexSym] =
  ## The D6 subgroup this map's terrain was authored against, in TEAM ORDER.
  ## The map's `symmetry` field decides, never its team count: the 2-team
  ## board has two different groups of order 2 (a mirror and a half turn) and
  ## picking the wrong one is the shields-in-the-spray-cans' terrain bug.
  case gameMap.symmetry
  of symMirrorHex: @[hexE, hexMir90]
  of symRot180: GroupC2
  of symRot120: GroupC3
  of symKlein4: GroupV4
  of symRot60: GroupC6

proc teamOp*(gameMap: CtfMap, team: Team): HexSym =
  ## The D6 element carrying RED's world onto `team`'s. The ORDER of
  ## `mapGroup` is a contract exactly as `rot90Quarter`'s quarter-turn count
  ## was on the square board: team `i` is group element `i`, forever.
  let group = gameMap.mapGroup()
  group[min(int(team), group.high)]

proc pixelImage*(gameMap: CtfMap, p: MapPoint, op: HexSym): MapPoint =
  ## One point carried by a PIXEL-EXACT D6 element. Only four of the twelve act
  ## exactly on a square pixel lattice — the identity, the two axis mirrors,
  ## and the half turn — and those four are precisely the group V4 plus its
  ## subgroups, i.e. every symmetry the 2- and 4-team boards use. The other
  ## eight involve sin 60 and MUST be walked in cube space instead (plan
  ## section 0.2); asking for one here is a bug, not a rounding question.
  case op
  of hexE: p
  of hexMir0: MapPoint(x: p.x, y: gameMap.height - 1 - p.y)
  of hexMir90: MapPoint(x: gameMap.width - 1 - p.x, y: p.y)
  of hexRot180:
    MapPoint(x: gameMap.width - 1 - p.x, y: gameMap.height - 1 - p.y)
  else:
    raise newException(
      CtfError, "D6 element " & $op & " is not exact on a pixel lattice; " &
        "walk its orbit in cube coordinates instead.")

proc teamImagePoint*(gameMap: CtfMap, red: MapPoint, team: Team): MapPoint =
  ## RED's point carried onto `team`'s side of the board by the map's OWN
  ## symmetry.
  ##
  ## Which symmetry is not a detail: the terrain was built with exactly one of
  ## them, and only that one carries Red's surroundings onto the image. On a
  ## rot180 board a MIRRORED copy lands in the rotation of some other Red spot
  ## instead — which is how the shields came to sit in the terrain of the spray
  ## cans, and the cans in the terrain of the shields. That bug is the reason
  ## this abstraction exists, and it survived the move to hex unchanged.
  gameMap.pixelImage(red, gameMap.teamOp(team))

proc teamAnchorAt*(gameMap: CtfMap, team: Team, d: int): MapPoint =
  ## One team's home anchor at an ARBITRARY depth permille, so the depth
  ## solver can evaluate a candidate through exactly the code that will later
  ## place the base. `teamAnchor` is this at the map's own depth.
  let
    cx = gameMap.center.x
    cy = gameMap.center.y
  result =
    case gameMap.layout
    of layoutHex2:
      ## The horizontal axis: RED left, BLUE right. `hex.nim` keeps the 2-team
      ## orbit here deliberately — `teamHomeX` and every deployed league policy
      ## encode it.
      ##
      ## On the FLAT-TOP board this axis runs VERTEX TO VERTEX (it was
      ## edge-midpoint to edge-midpoint while the board was portrait), so it is
      ## the board's LONG axis and the hull is `R` away rather than `A`. The
      ## depth permille is NOT transferable across that change: behind a base on
      ## a vertex ray the hull closes in at `cos 30`, so a permille that left
      ## the apron 13px of daylight on the portrait board leaves it 3px SHORT
      ## here. `homeDepthWindow` re-solves it from the budgets instead.
      MapPoint(x: axisHomeLo(cx, d), y: cy)
    else:
      ## Off-axis seed. V4 carries a seed at angle t to {t, -t, 180-t, 180+t},
      ## whose gaps are equal only at t = 45 degrees, so the 4-team seed sits
      ## on the DIAGONAL rather than on a lattice axis (plan section 0.1).
      ## 707/1000 is cos 45 to four places — integer, so the seed is a pure
      ## function of the board and its three images are exact.
      let radial = min(cx, cy) * d div 1000
      MapPoint(x: cx - radial * 707 div 1000, y: cy - radial * 707 div 1000)
  if team != Red:
    result = gameMap.teamImagePoint(result, team)

proc teamAnchor*(gameMap: CtfMap, team: Team): MapPoint =
  ## Returns one team's home anchor: the center of its protected spawn
  ## pocket, where its pedestal stands.
  ##
  ## RED seeds the orbit and every other team's anchor is RED's carried by the
  ## map's own symmetry, so the homes are EXACTLY images of one another.
  ## Deriving the far anchor from a mirrored FORMULA instead (the old
  ## `axisHomeHi`) put it a pixel off the orbit on an even board — a fairness
  ## difference, not a rounding detail.
  gameMap.teamAnchorAt(team, gameMap.homeDepthOf())

proc homeDepthWindow*(gameMap: CtfMap): tuple[lo, hi: int] =
  ## The depth permilles at which this map's base anchor satisfies BOTH
  ## budgets at once:
  ##
  ## - IN FRONT: apron, then the scoring ring, then a corridor of real field
  ##   before the center ring — or the two bases fight over the middle.
  ## - BEHIND: apron, then room for one obstacle between the endzone and the
  ##   hull — or the base is flush against the wall and its back approaches
  ##   vanish.
  ##
  ## Solved by SCANNING the legal permilles and evaluating each candidate
  ## through the real `teamAnchorAt` + `hexEdgeDist`, not by trigonometry.
  ## That is deliberate: the clearance behind a base depends on whether its ray
  ## points at a vertex (`cos 30` falloff), at an edge midpoint (no falloff), or
  ## anywhere between, and the 2-team ray swapped categories when the board went
  ## landscape. A closed form would have to be re-derived for every layout and
  ## every orientation; this cannot go stale. 401 iterations of integer math,
  ## run once per map build.
  let
    reserved = gameMap.endzoneRadius + EndzoneApron
    front = reserved + gameMap.flagRing + 50
    behind = float(reserved + 40)
    board = gameMap.mapBoard()
  result = (lo: 0, hi: -1)
  for d in HomeDepthMin .. HomeDepthMax:
    let
      a = gameMap.teamAnchorAt(Red, d)
      dx = a.x - gameMap.center.x
      dy = a.y - gameMap.center.y
    if dx * dx + dy * dy < front * front:
      continue                      ## too shallow: crowds the center ring.
    if board.hexEdgeDist(a.x, a.y) < behind:
      break                         ## too deep: the apron is cut by the hull.
    if result.hi < result.lo:
      result.lo = d
    result.hi = d

proc spawnPocketHalf*(gameMap: CtfMap, team: Team): tuple[w, h: int] =
  ## The half-extents of one team's protected spawn pocket, around its anchor.
  ##
  ## Every symmetry a hex board can wear that is exact on pixels (mirror, half
  ## turn, and V4) preserves the coordinate AXES, so the upright box is its own
  ## image and one box serves every team — unlike the old rot90 boards, where
  ## the odd quarters had to carry the transposed H x W box or 7.6% of the
  ## board disagreed with its own quarter turn.
  discard team
  (gameMap.spawnClearW, gameMap.spawnClearH)

proc teamHomeX*(gameMap: CtfMap, team: Team): int =
  ## Returns the home-edge x anchor for one team's spawn strip and pedestal.
  gameMap.teamAnchor(team).x

proc flagHome*(gameMap: CtfMap, team: Team): MapPoint =
  ## Returns the pedestal position for one team's flag, at the center of the
  ## team's protected spawn pocket.
  gameMap.teamAnchor(team)

proc trenchSquareAt(cx, cy: int): MapRect =
  ## A TrenchSize×TrenchSize dug pit centered on (cx, cy). Like obstacle
  ## sizes, the pit never scales with the map's size class.
  MapRect(
    x: cx - TrenchSize div 2,
    y: cy - TrenchSize div 2,
    w: TrenchSize,
    h: TrenchSize
  )

proc rectsIntersect(a, b: MapRect): bool =
  ## Returns true when the two rectangles overlap by at least one pixel.
  a.x < b.x + b.w and b.x < a.x + a.w and
    a.y < b.y + b.h and b.y < a.y + a.h

proc defaultCtfRooms(gameMap: CtfMap): seq[Room] =
  ## The room annotation set every map shares: an informal center zone plus
  ## one base room per team. The endzone IS the base on a hex board, so the
  ## room is the scoring disc's bounding box.
  result.add Room(name: "Center", x: gameMap.width div 2 - 80,
    y: gameMap.height div 2 - 80, w: 160, h: 160)
  let r = gameMap.endzoneRadius
  for team in gameMap.teams():
    let
      anchor = gameMap.teamAnchor(team)
      name = teamText(team)
    result.add Room(
      name: name[0].toUpperAscii() & name[1 .. ^1] & " Base",
      x: anchor.x - r, y: anchor.y - r, w: 2 * r, h: 2 * r
    )

proc captureZone*(gameMap: CtfMap, team: Team): CaptureZone =
  ## Returns one team's home capture zone: the DISC around its base anchor.
  ## Every edge is an inner threshold, so the paint rings the whole zone and a
  ## carrier scores from whichever side they reach.
  ##
  ## All-disc is the hex decision: it is the one endzone geometry already
  ## invariant under every rotation the board admits, so it needs no separate
  ## fairness argument and no new art. The old column / square / corner / arm
  ## zones were all straight-edged artifacts of a rectangular board.
  let
    anchor = gameMap.teamAnchor(team)
    r = gameMap.endzoneRadius
  CaptureZone(
    xLo: anchor.x - r, xHi: anchor.x + r,
    yLo: anchor.y - r, yHi: anchor.y + r,
    disc: true, anchorX: anchor.x, anchorY: anchor.y, radius: r
  )

proc inCaptureZone*(zone: CaptureZone, x, y: int): bool =
  ## Returns whether a map point sits inside one capture zone.
  if x < zone.xLo or x > zone.xHi or y < zone.yLo or y > zone.yHi:
    return false
  if zone.disc:
    let
      dx = x - zone.anchorX
      dy = y - zone.anchorY
    return dx * dx + dy * dy <= zone.radius * zone.radius
  true

proc mirrorX(rect: MapRect, width: int): MapRect =
  ## Mirrors one rectangle across the vertical center line of a width-px map.
  MapRect(x: width - rect.x - rect.w, y: rect.y, w: rect.w, h: rect.h)

proc mirrorY(rect: MapRect, height: int): MapRect =
  ## Mirrors one rectangle across the horizontal center line.
  MapRect(x: rect.x, y: height - rect.y - rect.h, w: rect.w, h: rect.h)

proc rot180(rect: MapRect, width, height: int): MapRect =
  ## Rotates one rectangle 180 degrees about the map center.
  MapRect(
    x: width - rect.x - rect.w,
    y: height - rect.y - rect.h,
    w: rect.w,
    h: rect.h
  )

proc pixelImage*(shape: ArenaShape, op: HexSym, width, height: int): ArenaShape =
  ## One obstacle carried by a PIXEL-EXACT D6 element — the shape-level twin of
  ## `pixelImage(MapPoint, ...)`, and the only transform any Stage-2 map needs.
  ##
  ## Every kind transforms in CLOSED FORM here, with no rounding anywhere: a
  ## bar's doubled center reflects exactly and its axis flips one component; a
  ## hexagon is invariant under both axis mirrors and the half turn, so only
  ## its center moves; the diagonal's endpoints and the polygon's vertices
  ## reflect one integer at a time. That exactness is the whole team-fairness
  ## proof — a mirrored obstacle rasterizes to a bit-for-bit mirrored mask.
  ##
  ## `hexRot60`/`hexRot120` and the four diagonal mirrors are absent on
  ## purpose: sin 60 is irrational on a square pixel lattice, and rotating in
  ## floats and rounding would reintroduce exactly the unfairness the old
  ## "rot90 needs a square map" refusal existed to prevent. Their orbits belong
  ## in cube space (plan section 0.2).
  let
    fx = (op == hexMir90 or op == hexRot180)   ## flips x
    fy = (op == hexMir0 or op == hexRot180)    ## flips y
  case op
  of hexE, hexMir0, hexMir90, hexRot180: discard
  else:
    raise newException(
      CtfError, "D6 element " & $op & " is not exact on a pixel lattice; " &
        "walk its orbit in cube coordinates instead.")
  template mx(v: int): int = (if fx: width - 1 - v else: v)
  template my(v: int): int = (if fy: height - 1 - v else: v)
  template mx2(v: int): int = (if fx: 2 * (width - 1) - v else: v)
  template my2(v: int): int = (if fy: 2 * (height - 1) - v else: v)
  case shape.kind
  of shapeDisc:
    ArenaShape(kind: shapeDisc, window: shape.window,
      cx: mx(shape.cx), cy: my(shape.cy), radius: shape.radius)
  of shapeBar:
    ## A reflection negates one component of the axis and leaves the
    ## half-extents alone: the two slab tests come back with their signs
    ## flipped inside the absolute values, so the pixel set is exactly the
    ## reflected one. A half turn negates the whole offset, which a bar is
    ## already symmetric under, so its axis is untouched.
    ArenaShape(kind: shapeBar, window: shape.window,
      cx2: mx2(shape.cx2), cy2: my2(shape.cy2),
      halfLong: shape.halfLong, halfPerp: shape.halfPerp,
      axisX: (if fx: -shape.axisX else: shape.axisX),
      axisY: (if fy: -shape.axisY else: shape.axisY))
  of shapeHex:
    ## Both axis mirrors and the half turn map a regular hexagon's vertex set
    ## onto itself whichever way it is turned, so orientation is preserved.
    ArenaShape(kind: shapeHex, window: shape.window,
      hexCx2: mx2(shape.hexCx2), hexCy2: my2(shape.hexCy2),
      hexR2: shape.hexR2, flatTop: shape.flatTop)
  of shapeDiagonal:
    ArenaShape(kind: shapeDiagonal, window: shape.window,
      x0: mx(shape.x0), y0: my(shape.y0),
      x1: mx(shape.x1), y1: my(shape.y1), thickness: shape.thickness)
  of shapePolygon:
    var pts = newSeq[MapPoint](shape.points.len)
    for i, p in shape.points:
      pts[i] = MapPoint(x: mx(p.x), y: my(p.y))
    ArenaShape(kind: shapePolygon, window: shape.window, points: pts)

proc `==`*(a, b: ArenaShape): bool =
  ## Field-wise equality (Nim derives no `==` for case objects); lets whole
  ## CtfMap values compare, which the map-spec round-trip tests rely on.
  if a.kind != b.kind or a.window != b.window:
    return false
  case a.kind
  of shapeDisc:
    a.cx == b.cx and a.cy == b.cy and a.radius == b.radius
  of shapeBar:
    a.cx2 == b.cx2 and a.cy2 == b.cy2 and a.halfLong == b.halfLong and
      a.halfPerp == b.halfPerp and a.axisX == b.axisX and a.axisY == b.axisY
  of shapeHex:
    a.hexCx2 == b.hexCx2 and a.hexCy2 == b.hexCy2 and a.hexR2 == b.hexR2 and
      a.flatTop == b.flatTop
  of shapeDiagonal:
    a.x0 == b.x0 and a.y0 == b.y0 and a.x1 == b.x1 and a.y1 == b.y1 and
      a.thickness == b.thickness
  of shapePolygon:
    a.points == b.points

proc symmetryImages*(gameMap: CtfMap, rect: MapRect): seq[MapRect] =
  ## Returns one rectangle's full orbit under the map's own symmetry, original
  ## first, deduplicated — which handles a center-straddling rectangle without
  ## re-deriving the half-pixel symmetry axis.
  result.add rect
  for op in gameMap.mapGroup():
    let image =
      case op
      of hexE: rect
      of hexMir0: rect.mirrorY(gameMap.height)
      of hexMir90: rect.mirrorX(gameMap.width)
      of hexRot180: rect.rot180(gameMap.width, gameMap.height)
      else:
        raise newException(
          CtfError, "rectangle orbits need a pixel-exact symmetry; " & $op &
            " does not have one.")
    if image notin result:
      result.add image

proc symmetryImages*(gameMap: CtfMap, point: MapPoint): seq[MapPoint] =
  ## Returns one point's full orbit under the map's own symmetry, original
  ## first. Images go through teamImagePoint so pickups authored by the editor
  ## cannot regress to mirroring on rot180 terrain.
  result.add point
  for team in gameMap.teams():
    let image = gameMap.teamImagePoint(point, team)
    if image notin result:
      result.add image

proc inRect*(x, y: int, rect: MapRect): bool =
  ## Returns true when (x, y) lies inside the rectangle.
  x >= rect.x and x < rect.x + rect.w and
    y >= rect.y and y < rect.y + rect.h

proc pointInPolygon*(x, y: int, pts: seq[MapPoint]): bool =
  ## Integer even-odd point-in-polygon over a closed ring. An edge is counted
  ## only when the scan line at `y` lies STRICTLY between the edge's endpoints
  ## (`ylo < y < yhi`). That strict straddle is the key: it is symmetric under
  ## the integer coordinate reflections the map uses — mirror (x -> w-1-x) and
  ## rot180 (x,y -> w-1-x, h-1-y) — so a polygon and its symmetry image
  ## rasterize to bit-for-bit mirror-symmetric wall masks. That exactness is
  ## the team-fairness invariant the diamond (integer-offset) and diagonal
  ## (int64) tests also protect. Edges that merely touch the scan line at a
  ## vertex are skipped identically on both sides, so at worst a shape loses a
  ## 1px sliver at a y-extremum — symmetrically, so fairness holds. int64
  ## throughout: cross products of map-scale coords overflow int32 on wasm.
  if pts.len < 3:
    return false
  var
    minx = pts[0].x
    maxx = pts[0].x
    miny = pts[0].y
    maxy = pts[0].y
  for p in pts:
    minx = min(minx, p.x); maxx = max(maxx, p.x)
    miny = min(miny, p.y); maxy = max(maxy, p.y)
  if x < minx or x > maxx or y < miny or y > maxy:
    return false
  var
    inside = false
    j = pts.len - 1
  for i in 0 ..< pts.len:
    let
      xi = pts[i].x
      yi = pts[i].y
      xj = pts[j].x
      yj = pts[j].y
      ylo = min(yi, yj)
      yhi = max(yi, yj)
    if y > ylo and y < yhi:
      # Strict straddle => dy != 0. Flip when the sample is left of the edge's
      # intersection with the scan line: x < xi + (xj-xi)*(y-yi)/(yj-yi),
      # cross-multiplied by the (signed) edge dy so there is no division.
      let
        dyv = int64(yj - yi)
        lhs = int64(x - xi) * dyv
        rhs = int64(xj - xi) * int64(y - yi)
      if (if dyv > 0: lhs < rhs else: lhs > rhs):
        inside = not inside
    j = i
  inside

proc inBar*(x, y: int, shape: ArenaShape): bool {.inline.} =
  ## Integer membership for an oriented bar: two slab tests on the DOUBLED
  ## offset from the bar's center. int64 because `dx2 * axisX` reaches ~3e6 on
  ## a 60-degree axis (whose components are 153 and 265) on a colossal board,
  ## and products of those overflow int32 on wasm.
  let
    dx2 = int64(2 * x - shape.cx2)
    dy2 = int64(2 * y - shape.cy2)
    ux = int64(shape.axisX)
    uy = int64(shape.axisY)
  abs(dx2 * ux + dy2 * uy) <= int64(shape.halfLong) and
    abs(dy2 * ux - dx2 * uy) <= int64(shape.halfPerp)

proc inHexShape*(x, y: int, shape: ArenaShape): bool {.inline.} =
  ## Integer membership for a regular hexagonal obstacle: three opposed pairs
  ## of half-planes, exactly as the arena boundary is tested, with sqrt(3) as
  ## the rational 265/153 so the predicate never touches a float.
  ##
  ## For a FLAT-TOP hexagon of circumradius R the three slabs are
  ##   |dx + dy/sqrt(3)| <= R,  |dx - dy/sqrt(3)| <= R,  |dy| <= R*sqrt(3)/2,
  ## which clear their denominators into the integer forms below. A POINTY-TOP
  ## hexagon is the same test with the two axes swapped.
  let
    dx2 = int64(2 * x - shape.hexCx2)
    dy2 = int64(2 * y - shape.hexCy2)
    (a, b) = if shape.flatTop: (dx2, dy2) else: (dy2, dx2)
    r2 = int64(shape.hexR2)
  abs(a * Sqrt3Num + b * Sqrt3Den) <= r2 * Sqrt3Num and
    abs(a * Sqrt3Num - b * Sqrt3Den) <= r2 * Sqrt3Num and
    2 * abs(b) * Sqrt3Den <= r2 * Sqrt3Num

proc inShape*(x, y: int, shape: ArenaShape): bool =
  ## Returns true when (x, y) lies inside one arena shape.
  case shape.kind
  of shapeDisc:
    let
      dx = x - shape.cx
      dy = y - shape.cy
    dx * dx + dy * dy <= shape.radius * shape.radius
  of shapeBar:
    inBar(x, y, shape)
  of shapeHex:
    inHexShape(x, y, shape)
  of shapePolygon:
    pointInPolygon(x, y, shape.points)
  of shapeDiagonal:
    ## Bounding-box rejection first, then point-to-segment distance in
    ## integers: (x, y) is inside when its distance to the segment is at
    ## most half the wall thickness. Angle-general, so a 60-degree chevron
    ## works exactly as the 45-degree ones always did.
    let half = shape.thickness div 2 + 1
    if x < min(shape.x0, shape.x1) - half or
        x > max(shape.x0, shape.x1) + half or
        y < min(shape.y0, shape.y1) - half or
        y > max(shape.y0, shape.y1) + half:
      false
    else:
      # 64-bit throughout: dx*dx + dy*dy reaches ~2.2e9 for these segments,
      # past int32 max, so on a 32-bit target (wasm) the plain-int form would
      # overflow. int64 is exact on every target and the comparison is unchanged.
      let
        vx = int64(shape.x1 - shape.x0)
        vy = int64(shape.y1 - shape.y0)
        wx = int64(x - shape.x0)
        wy = int64(y - shape.y0)
        len2 = vx * vx + vy * vy
        t = clamp(wx * vx + wy * vy, 0'i64, len2)
        dx = wx * len2 - t * vx
        dy = wy * len2 - t * vy
      dx * dx + dy * dy <=
        int64(shape.thickness) * int64(shape.thickness) * len2 * len2 div 4

proc buildArenaObstacles*(gameMap: CtfMap): seq[ArenaShape] =
  ## The full obstacle set: every seed shape plus its image(s) under the map's
  ## symmetry group, precomputed once per map selection so the per-pixel wall
  ## test never re-transforms. Images are deduplicated, so a seed sitting on a
  ## mirror axis is stamped once rather than twice.
  for shape in gameMap.leftObstacles:
    for op in gameMap.mapGroup():
      let image = shape.pixelImage(op, gameMap.width, gameMap.height)
      if image notin result:
        result.add image

## Spinning-diamond geometry lives up here, ahead of mapWallAt, because
## the terrain validator has to reason about the whole turn.

const
  DiamondSpinFrames* = 16      ## steps across 90° (a diamond is 4-fold symmetric).
  DiamondSpinTicksPerFrame* = 4  ## ~2.7s per quarter turn at 24 ticks/s.
  DiamondRotShift = 16         ## fixed-point fraction bits of the spin table.
  DiamondRotOne = 1'i64 shl DiamondRotShift
  ## cos(frame * 5.625°), scaled by 2^16. Geometry must not use host libm.
  ## sin(frame) is the same table read from the other end.
  DiamondCos: array[DiamondSpinFrames + 1, int64] = [
    65536'i64, 65220'i64, 64277'i64, 62714'i64, 60547'i64,
    57798'i64, 54491'i64, 50660'i64, 46341'i64, 41576'i64,
    36410'i64, 30893'i64, 25080'i64, 19024'i64, 12785'i64,
    6424'i64, 0'i64
  ]

proc diamondFrameIndex*(frame: int): int {.inline.} =
  ## Wraps any signed frame counter into 0 ..< DiamondSpinFrames.
  ((frame mod DiamondSpinFrames) + DiamondSpinFrames) mod DiamondSpinFrames


proc rotatedDiamondCovers*(
  radius, frame, dxNum, dyNum, denom: int
): bool =
  ## Integer rotated-L1 membership: is the offset (dxNum/denom, dyNum/denom)
  ## map pixels from a diamond's center inside it at `frame`? Keeping the
  ## division symbolic lets the collision masks (denom = 2) and the scale× art
  ## rasterizer (denom = 2·scale) share ONE predicate, so the drawn silhouette
  ## and the geometry cannot drift apart.
  ##
  ## Both samplers measure from the diamond's center pixel, NOT from pixel
  ## centers half a pixel to its right. Under the x-mirror (x -> width-1-x)
  ## a +0.5 offset does not flip sign, so a half-pixel sample would make each
  ## diamond's footprint the mirror of its twin's translated by one pixel —
  ## the arena's obstacle union is exactly mirror-symmetric and team fairness
  ## rests on it. On integer offsets the mirror is exact. As a bonus, frame 0
  ## then reproduces the plain |dx| + |dy| <= r diamond that
  ## isAnimatedDiamondPixel bakes the hole for.
  let
    index = diamondFrameIndex(frame)
    ca = DiamondCos[index]
    sa = DiamondCos[DiamondSpinFrames - index]
    rx = int64(dxNum) * ca + int64(dyNum) * sa
    ry = -int64(dxNum) * sa + int64(dyNum) * ca
  abs(rx) + abs(ry) <= int64(radius) * int64(denom) * DiamondRotOne

const DiamondSpinBand = 80
  ## Half-width, in map pixels, of the center column whose diamonds spin.

type SpinFootprint* = enum
  ## Which shape a spinning diamond presents to an offline (uninstalled-map)
  ## wall test. Live play always uses the exact per-frame silhouette; these
  ## are for validation, which must hold across the WHOLE turn and so needs
  ## the bound that points the right way for each invariant.
  spinRest       ## the resting diamond, i.e. what the art bake carves out.
  spinSwept      ## union over the turn: nothing outside this is ever stone.
  spinAlways     ## intersection over the turn: this is stone at every frame.

proc nearSpinAxis(center, span: int): bool {.inline.} =
  ## Is a shape centered at `center` inside the spin band of an axis `span`
  ## pixels long? Measured against the SYMMETRY AXIS at (span - 1)/2, not
  ## against the map's center pixel: on an even span the two differ by half a
  ## pixel, and a diamond whose image fell on the other side of the threshold
  ## would spin while its twin stayed baked stone. Doubling both sides keeps
  ## the comparison exact in integers.
  abs(2 * center - (span - 1)) < 2 * DiamondSpinBand

proc isSpinningDiamond*(gameMap: CtfMap, shape: ArenaShape): bool {.inline.} =
  ## The diamonds flanking the center of the field are the ones drawn — and,
  ## since GV28, COLLIDED — as spinning stone. A "diamond" is now a bar on the
  ## (1, 1) axis with equal half-extents (`asDiamond`); the pixels, and so the
  ## spin, are unchanged.
  ##
  ## The selected set must be CLOSED under the map's symmetry group, or one
  ## team gets rotating cover where another gets solid stone. The authored rule
  ## is a vertical band down the center column, which both the vertical mirror
  ## and the half turn preserve. V4 adds the horizontal mirror, which does NOT
  ## preserve it — but that mirror fixes x, so the band is closed under V4 too.
  ## Under rot120/rot60 it would not be, which is one more reason those groups
  ## wait for the cube-space pipeline.
  let d = shape.asDiamond()
  d.ok and nearSpinAxis(d.cx, gameMap.width)

proc buildAnimatedDiamonds*(
  gameMap: CtfMap, obstacles: seq[ArenaShape]
): seq[tuple[cx, cy, radius: int]] =
  ## The eight diamonds flanking the center of the field (column 5 and its
  ## x-mirror): drawn as slowly rotating sprites instead of baked wall art.
  ## Since GV28 the rotation is REAL: the bake leaves them out of every
  ## collision layer and the sim stamps the live rotated footprint into the
  ## movement, bullet, and vision masks as the frame advances
  ## (applyDiamondGeometry).
  for shape in obstacles:
    if gameMap.isSpinningDiamond(shape):
      let d = shape.asDiamond()
      result.add((d.cx, d.cy, d.radius))


## ---------------------------------------------------------------------------
## Procedural terrain (GameVersion 25). Canonical play draws a validated map
## from the curated pool (map_pool.nim); mapPath "gen" generates straight from
## a seed. Every layout is authored for the LEFT half only and completed by
## the map's symmetry, so team fairness is structural. The generator is fully
## deterministic (own splitmix64, never std/random) so one seed names one map
## on every platform, including wasm.
## ---------------------------------------------------------------------------

const
  GenMapName* = "gen"
  PoolMapName* = "pool"
  MinCorridorWidth = 26      ## narrowest corridor for the 13px footprint.
  MapGenMaxAttempts = 100
  MapSizeNames = ["small", "standard", "large", "huge", "giant"]
  CenterFeatureNames = ["bracket", "ring", "walls"]
  ## Interior cover budget, in permille of the non-protected interior that is
  ## obstacle wall. The hand-tuned arena sits inside this band; layouts
  ## outside it play too open or too clogged and are re-rolled. Public so
  ## tooling can report a measured figure against the band it is judged by
  ## rather than restating the numbers.
  CoverPermilleMin* = 40
  CoverPermilleMax* = 170

type
  MapRng = object
    state: uint64

  ColumnFamily = enum
    colStubs        ## 18px-wide rect stubs, border-anchored at the ends.
    colDiamonds
    colDiscs
    colChevrons     ## 45-degree zigzag wall segments.

proc next(rng: var MapRng): uint64 =
  ## splitmix64: tiny, statistically solid, identical on every target.
  rng.state = rng.state + 0x9E3779B97F4A7C15'u64
  var z = rng.state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc pick(rng: var MapRng, bound: int): int =
  ## Uniform 0..bound-1 (modulo bias is immaterial at these bounds).
  int(rng.next() mod uint64(bound))

proc pickRange(rng: var MapRng, lo, hi: int): int =
  lo + rng.pick(hi - lo + 1)

proc coin(rng: var MapRng): bool =
  (rng.next() and 1'u64) == 1

proc shuffle[T](rng: var MapRng, items: var seq[T]) =
  for i in countdown(items.high, 1):
    let j = rng.pick(i + 1)
    swap(items[i], items[j])

proc mapSizeScale(sizeName: string): float =
  ## Field-scale factor for one size class, shared with `hex.nim`'s
  ## `HexClassScale`. If one moves, both move.
  HexClassScale[hexSizeClass(sizeName)]

proc scaledGenShell(sizeName: string): CtfMap =
  ## Field dimensions and clearances for one size class: the standard hexagon
  ## from `hex.nim` plus the standard-arena clearances scaled by the class
  ## factor. Obstacle SIZES never scale — bigger fields get roomier corridors,
  ## exactly like arena-large.
  let
    cls = hexSizeClass(sizeName)
    board = hexBoardOf(cls)
    scale = HexClassScale[cls]
  proc s(value: int): int = int(round(float(value) * scale))
  result.width = board.width
  result.height = board.height
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = s(70)
  ## Retained in the map spec (old replays pin it) but INERT since GV38: it
  ## sized the column endzones' protected home strip, and the hex arena has no
  ## straight home border to pin a strip to.
  result.captureClear = s(210)
  result.spawnClearW = s(70)
  result.spawnClearH = s(130)
  result.gunRange = GunRange  # fixed, never scaled with the field (GV34).

proc mapProtectedFloorAt*(gameMap: CtfMap, x, y: int): bool =
  ## isProtectedFloor for a map that is NOT installed as the process map:
  ## the generator and validators run on candidates before any selection.
  ##
  ## On a hex board this is the endzone discs plus the center flag ring, and
  ## nothing else: there is no straight home border for a protected column to
  ## be pinned to, and the wilderness behind each base is ordinary field the
  ## terrain may build on.
  for team in gameMap.teams():
    let anchor = gameMap.teamAnchor(team)
    if endzoneFloorAt(x, y, anchor.x, anchor.y, gameMap.endzoneRadius,
        gameMap.endzone == ezDisc):
      return true
  let
    dcx = x - gameMap.center.x
    dcy = y - gameMap.center.y
  dcx * dcx + dcy * dcy <= gameMap.flagRing * gameMap.flagRing

proc mapBorderWallAt*(gameMap: CtfMap, x, y: int): bool {.inline.} =
  ## THE boundary rule, in its uninstalled-map form: a pixel is border wall
  ## when it is within `ArenaBorder` of the hexagon's edge — or outside the
  ## hexagon altogether, since `hexEdgeDist` goes negative there and the six
  ## corners of the bounding box are permanent void.
  ##
  ## One predicate replaces the four-way rectangular test that `mapWallAt`,
  ## `isArenaWall`, `mapObstacleWallAtF`, and `mapShapeWallAtF` each spelled
  ## out separately. `tests/test_hex_arena.nim` sweeps a whole board asserting
  ## the four agree pixel-for-pixel; that sweep is the safety net.
  gameMap.mapBoard().hexEdgeDist(x, y) < float(ArenaBorder)

proc mapWallAt*(
  gameMap: CtfMap,
  obstacles: seq[ArenaShape],
  x, y: int,
  includeSpinning = true,
  spin = spinRest
): bool =
  ## Uninstalled-map wall test, matching isArenaWall's border + carve rules.
  ## `includeSpinning = false` drops the live diamonds, which is what the art
  ## bake needs to see under them; `spin` picks which bound of the turn a
  ## spinning diamond presents, for validation that must hold at every frame.
  if gameMap.mapBorderWallAt(x, y):
    return true
  if mapProtectedFloorAt(gameMap, x, y):
    return false
  for shape in obstacles:
    if gameMap.isSpinningDiamond(shape):
      if not includeSpinning:
        continue
      if spin != spinRest:
        let
          spot = shape.asDiamond()
          dx = x - spot.cx
          dy = y - spot.cy
          d2 = dx * dx + dy * dy
          r2 = spot.radius * spot.radius
        ## Two cheap circles bracket the answer: nothing outside the
        ## circumradius is ever stone, everything inside the inradius
        ## (2*d2 <= r2) is stone at every frame. Only the annulus between them
        ## depends on the angle, and there the sixteen frames are walked for
        ## real — the true intersection is a rosette strictly larger than the
        ## inscribed disc, and approximating it by that disc would reject maps
        ## whose lane is in fact blocked at every frame.
        if d2 > r2:
          continue
        if 2 * d2 <= r2:
          return true
        var everStone, alwaysStone = false
        alwaysStone = true
        for frame in 0 ..< DiamondSpinFrames:
          if rotatedDiamondCovers(spot.radius, frame, 2 * dx, 2 * dy, 2):
            everStone = true
          else:
            alwaysStone = false
        if (if spin == spinSwept: everStone else: alwaysStone):
          return true
        continue
    if inShape(x, y, shape):
      return true
  false

proc shapeBounds*(shape: ArenaShape): tuple[x0, y0, x1, y1: int] =
  ## Inclusive bounding box of one shape's membership: no pixel outside it
  ## can pass inShape. Diagonals reuse inShape's own rejection half-width, so
  ## the two can never disagree about where a segment's influence ends.
  case shape.kind
  of shapeDisc:
    (shape.cx - shape.radius, shape.cy - shape.radius,
      shape.cx + shape.radius, shape.cy + shape.radius)
  of shapeBar, shapeHex:
    let r = shapeAsRect(shape)
    (r.x, r.y, r.x + r.w - 1, r.y + r.h - 1)
  of shapeDiagonal:
    let half = shape.thickness div 2 + 1
    (min(shape.x0, shape.x1) - half, min(shape.y0, shape.y1) - half,
      max(shape.x0, shape.x1) + half, max(shape.y0, shape.y1) + half)
  of shapePolygon:
    if shape.points.len == 0:
      (0, 0, -1, -1)
    else:
      var
        x0 = shape.points[0].x
        y0 = shape.points[0].y
        x1 = shape.points[0].x
        y1 = shape.points[0].y
      for p in shape.points:
        x0 = min(x0, p.x); y0 = min(y0, p.y)
        x1 = max(x1, p.x); y1 = max(y1, p.y)
      (x0, y0, x1, y1)

proc rasterizeWallMasks*(
  gameMap: CtfMap, obstacles: seq[ArenaShape]
): tuple[maxWall, minWall: seq[bool]] =
  ## mapWallAt(spin = spinSwept) and mapWallAt(spin = spinAlways) for EVERY
  ## pixel at once, bit-identical to querying them one pixel at a time.
  ## mapWallAt scans the whole shape list per query, so a full-board sweep is
  ## area x shapes — billions of shape tests on an oversize board. Painting
  ## each shape over its own bounding box instead costs area + the sum of the
  ## box areas, and protected floor is only consulted where a shape actually
  ## covers. (A spinning diamond's swept rosette stays inside its circumradius
  ## — rotation preserves L2 and L1 >= L2 — so the resting bbox bounds every
  ## frame.)
  let
    w = gameMap.width
    h = gameMap.height
  var
    maxWall = newSeq[bool](w * h)
    minWall = newSeq[bool](w * h)
  for shape in obstacles:
    let
      bounds = shapeBounds(shape)
      x0 = max(bounds.x0, 0)
      y0 = max(bounds.y0, 0)
      x1 = min(bounds.x1, w - 1)
      y1 = min(bounds.y1, h - 1)
    if gameMap.isSpinningDiamond(shape):
      ## The same circumradius/inradius bracket as mapWallAt: only the
      ## annulus between them walks the sixteen frames.
      let
        spot = shape.asDiamond()
        r2 = spot.radius * spot.radius
      for y in y0 .. y1:
        for x in x0 .. x1:
          let
            dx = x - spot.cx
            dy = y - spot.cy
            d2 = dx * dx + dy * dy
          if d2 > r2:
            continue
          let i = y * w + x
          if 2 * d2 <= r2:
            maxWall[i] = true
            minWall[i] = true
            continue
          var everStone = false
          var alwaysStone = true
          for frame in 0 ..< DiamondSpinFrames:
            if rotatedDiamondCovers(spot.radius, frame, 2 * dx, 2 * dy, 2):
              everStone = true
            else:
              alwaysStone = false
          if everStone:
            maxWall[i] = true
          if alwaysStone:
            minWall[i] = true
    else:
      for y in y0 .. y1:
        for x in x0 .. x1:
          if inShape(x, y, shape):
            let i = y * w + x
            maxWall[i] = true
            minWall[i] = true
  ## Border and protected floor, in mapWallAt's precedence: the border ring
  ## is wall unconditionally, protected floor is floor no matter what shape
  ## covers it.
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      if gameMap.mapBorderWallAt(x, y):
        maxWall[i] = true
        minWall[i] = true
      elif maxWall[i] and mapProtectedFloorAt(gameMap, x, y):
        maxWall[i] = false
        minWall[i] = false
  (maxWall, minWall)

proc rasterizeRestWallMask*(
  gameMap: CtfMap,
  obstacles: seq[ArenaShape],
  protectedAt: proc (x, y: int): bool,
  includeSpinning = true
): seq[bool] =
  ## isArenaWall / mapWallAt(spin = spinRest) for every pixel at once — the
  ## bake-time twin of rasterizeWallMasks, painting resting silhouettes over
  ## their bounding boxes instead of scanning every shape per pixel.
  ## includeSpinning = false is mapWallAt's includeSpinning = false: the
  ## spinning diamonds stay out because the bake stamps their live rotation
  ## per frame. The protected-floor rule is a parameter because the installed
  ## map answers it from the Arena globals (isProtectedFloor) while an
  ## uninstalled candidate answers from the map itself (mapProtectedFloorAt);
  ## the caller passes whichever matches the per-pixel predicate it replaces.
  let
    w = gameMap.width
    h = gameMap.height
  result = newSeq[bool](w * h)
  for shape in obstacles:
    if not includeSpinning and gameMap.isSpinningDiamond(shape):
      continue
    let
      bounds = shapeBounds(shape)
      x0 = max(bounds.x0, 0)
      y0 = max(bounds.y0, 0)
      x1 = min(bounds.x1, w - 1)
      y1 = min(bounds.y1, h - 1)
    for y in y0 .. y1:
      for x in x0 .. x1:
        if inShape(x, y, shape):
          result[y * w + x] = true
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      if gameMap.mapBorderWallAt(x, y):
        result[i] = true
      elif result[i] and protectedAt(x, y):
        result[i] = false

const
  SightlineAxisCount* = 3
    ## A hexagon has SIX families of parallel chords, in two kinds. This
    ## validator scans the three EDGE-TO-EDGE ones — 90, 30 and 150 degrees on
    ## the flat-top hull — each of which runs between an opposite pair of
    ## parallel edges and maxes out at `2 * apothem` (968px on the standard
    ## class). `sightlinePixels` carries each family's parametrization.
    ##
    ## THESE ANGLES ARE A PROPERTY OF THE HULL AND TURN WITH IT. While the hull
    ## was pointy-top the edge-to-edge family was 0/60/120; the landscape flip
    ## rotated the hull 30 degrees and the family had to follow. Getting that
    ## wrong is silent in the worst way — the validator still runs, still
    ## passes, and simply stops looking where the lanes are.
    ## `tools/hex_range_probe.nim` caught exactly that, measuring a 950px open
    ## run at 87 degrees on a board whose validator was still scanning 0/60/120.
    ##
    ## THE OTHER THREE FAMILIES ARE STILL UNSCANNED, and that is now a MEASURED
    ## gap rather than an unexamined one. The vertex-to-vertex families (0, 60,
    ## 120 degrees on this hull) run corner to corner and reach
    ## `2 * circumradius` = 1118px. On the portrait board the unscanned long
    ## family ran vertically, ACROSS the play axis, so it cost little. On the
    ## landscape board it is the HORIZONTAL one — red base to blue base — and
    ## `hex_range_probe` measures a 1033px open run down it against a 1050px
    ## gun range: a real cross-field firing lane, with 17px of margin.
    ##
    ## Scanning all six was tried and REVERTED, with the number: the plug pass
    ## then adds roughly twice the cover and the generator's accept rate goes to
    ## 0 of 3197 seeds (61% rejected "too clogged", 18% still on sightlines).
    ## That is the tension the Stage 2 report already named — enforcing many
    ## axes against a `CoverPermilleMax` calibrated for ONE — and closing it
    ## needs the cover budget re-derived, which belongs to the generator epic.
    ## Raising the ceiling blind to make the sixth family fit would be trading a
    ## measured lane for an unmeasured one.
  SightlineStep* = 5
    ## Spacing between scanned lines, in intercept units. On the slanted axes
    ## one unit of intercept is 0.866 px of perpendicular separation, so this
    ## is the historical ~4px scan on all three.

proc sightlineMinSpan*(gameMap: CtfMap): int =
  ## How long an unblocked run has to be before it counts as a lane. On a
  ## rectangle every row spanned the whole board and no threshold was needed;
  ## on a hexagon the chords near the two vertices are arbitrarily short, and
  ## demanding cover on a 40px stub at the tip of the board would reject every
  ## map ever generated. 80% of the board's SHORT axis is the length of a chord
  ## roughly 60% of the way out to a vertex — past that the field is a wedge,
  ## not a lane.
  ##
  ## The short axis, not the width: all three chord families max out at exactly
  ## `2 * apothem` (they are 60-degree rotations of one another, and the hexagon
  ## is invariant under that), which is the board's HEIGHT on the landscape
  ## hull. Keyed to the width this threshold would sit at 92% of the longest
  ## chord instead of 80% and the rule would go nearly dead.
  ##
  ## 80%, not 90%. At 90% the raw pass rate is 93% instead of 77% — but a
  ## chord at 87% of the board width is still 843px on the standard class,
  ## well inside the 1050px gun range, i.e. a real end-to-end firing lane. The
  ## looser bound buys the number by excusing exactly the lanes this rule
  ## exists to refuse. See the cover-ceiling note in the hex report: enforcing
  ## THREE axes against a CoverPermilleMax calibrated for ONE is the actual
  ## tension, and it belongs to the generator epic, not to a threshold tweak.
  gameMap.height * 4 div 5

iterator sightlinePixels*(
  gameMap: CtfMap, axis, intercept: int
): tuple[x, y: int] =
  ## Every in-bounds pixel of one scan line, walked along the line's LONGER
  ## axis one pixel at a time so a one-pixel-thin wall can never be stepped
  ## over. No boundary test is needed here: the border ring AND the void
  ## outside the hexagon are both already `true` in every wall mask (see
  ## `mapBorderWallAt`), so a run clips itself at the hull.
  ##
  ## Axis 0 is the VERTICAL family (top edge to bottom edge), indexed by
  ## column. The slanted families are the 30- and 150-degree ones, parametrized
  ## `y = intercept +- 153*x div 265` — slope `+-tan 30`, so they run faster
  ## than they rise and x is the axis to step.
  if axis == 0:
    for y in 0 ..< gameMap.height:
      yield (intercept, y)
  else:
    let sign = if axis == 1: 1 else: -1
    for x in 0 ..< gameMap.width:
      let y = intercept + sign * (Sqrt3Den * x) div Sqrt3Num
      if y >= 0 and y < gameMap.height:
        yield (x, y)

iterator sightlineIntercepts*(gameMap: CtfMap, axis: int): int =
  ## The intercepts to scan on one axis, spaced `SightlineStep` apart. Axis 0
  ## is indexed by COLUMN; the slanted axes sweep a y-intercept range wide
  ## enough to carry every line that crosses the board.
  if axis == 0:
    var x = ArenaBorder + 2
    while x < gameMap.width - ArenaBorder:
      yield x
      x += 4
  else:
    let reach = (Sqrt3Den * gameMap.width) div Sqrt3Num + 2
    var c = (if axis == 1: -reach else: 0)
    let hi = (if axis == 1: gameMap.height else: gameMap.height + reach)
    while c < hi:
      yield c
      c += SightlineStep

proc sightlineOpenRun*(
  gameMap: CtfMap, wall: seq[bool], axis, intercept: int
): tuple[open: bool, x0, y0, x1, y1: int] =
  ## Whether one scan line carries an unblocked run at least
  ## `sightlineMinSpan` long, and the ENDPOINTS of the longest such run. The
  ## endpoints are what the generator's repair pass works from: an obstacle
  ## anywhere along a straight ray blocks it, so the repair gets to choose
  ## which point of the run to build on.
  let w = gameMap.width
  var
    runLen = 0
    startX, startY = 0
    bestLen = 0
    bestX0, bestY0, bestX1, bestY1 = 0
  for (x, y) in gameMap.sightlinePixels(axis, intercept):
    if wall[y * w + x]:
      runLen = 0
      continue
    if runLen == 0:
      startX = x
      startY = y
    inc runLen
    if runLen > bestLen:
      bestLen = runLen
      bestX0 = startX; bestY0 = startY; bestX1 = x; bestY1 = y
  if bestLen >= gameMap.sightlineMinSpan():
    return (true, bestX0, bestY0, bestX1, bestY1)
  (false, 0, 0, 0, 0)

proc rectOnOpenFloor(
  gameMap: CtfMap, obstacles: seq[ArenaShape], rect: MapRect
): bool =
  ## Returns true when every pixel of the rectangle is walkable floor on an
  ## uninstalled candidate map. Sampled on a 3px grid — finer than the
  ## thinnest wall feature (12px) — with the far edge column and row always
  ## included, so no wall can slip past the samples on any side.
  var xs, ys: seq[int]
  var x = rect.x
  while x < rect.x + rect.w - 1:
    xs.add x
    x += 3
  xs.add rect.x + rect.w - 1
  var y = rect.y
  while y < rect.y + rect.h - 1:
    ys.add y
    y += 3
  ys.add rect.y + rect.h - 1
  for sy in ys:
    for sx in xs:
      if mapWallAt(gameMap, obstacles, sx, sy):
        return false
  true

proc plugOpenSightlines*(gameMap: var CtfMap, budget: int) =
  ## Closes every straight lane at least `sightlineMinSpan` long on ANY of the
  ## hexagon's three axes, by adding hexagonal cover to the map's SEED half.
  ##
  ## A hexagon has three families of chords joining opposite edges where a
  ## rectangle had one that mattered, so the old "does the left half cover
  ## every row" shortcut no longer applies: this works against the fully
  ## symmetrized wall mask and re-rasterizes between passes.
  ##
  ## Plugs go on the ray's midpoint where they can (an obstacle anywhere on a
  ## straight ray blocks it, and the middle splits it most evenly), folded
  ## into the seed half when the midpoint lands on the far side — a ray and
  ## its symmetry image are either both open or both blocked, so plugging the
  ## image plugs the original too.
  ##
  ## Shared by the generator AND the hand-authored arena. The generator's
  ## validators never run on an authored map, so without this the default
  ## league arena could silently sit below the standard every generated map
  ## has to clear — and "no straight shot crosses the field" is a promise
  ## docs/RULES.md publishes to every policy author.
  let
    cy = gameMap.center.y
    redAnchorX = gameMap.teamHomeX(Red)
    apron = gameMap.endzoneRadius + EndzoneApron - EndzoneWallMargin
  var plugsLeft = budget
  for repairPass in 0 ..< 24:
    if plugsLeft <= 0:
      break
    let
      obstacles = buildArenaObstacles(gameMap)
      masks = rasterizeWallMasks(gameMap, obstacles)
    var plugged = 0
    for axis in 0 .. 2:
      for intercept in gameMap.sightlineIntercepts(axis):
        if plugsLeft <= 0:
          break
        let run = gameMap.sightlineOpenRun(masks.minWall, axis, intercept)
        if not run.open:
          continue
        ## Where along the run to build. Every legal position on the ray is
        ## tried, but the ORDER is rotated per ray by its own intercept.
        ##
        ## Searching every ray outward from its midpoint (the obvious order)
        ## makes the plugs converge: the midpoint of a ray through the middle
        ## of the board is the FLAG RING, which is protected floor, and the
        ## keep-out below pushes each plug just far enough out to be legal — so
        ## they land in a ring around the centre and SEAL IT. That is not
        ## hypothetical: it was 19 of 19 connectivity rejections, every one with
        ## 95-98% of the eroded floor reachable and only the core cut off.
        ## Rotating the order scatters them along the rays instead.
        var placed = false
        let
          halfSteps = max(abs(run.x1 - run.x0), abs(run.y1 - run.y0)) div 16
          spread = 2 * halfSteps + 1
        for t in 0 ..< max(1, spread):
          if placed:
            break
          block tryOne:
            let
              ## POSITIVE modulo, deliberately. Nim's `mod` takes the sign of
              ## its dividend, and the slanted axes sweep NEGATIVE intercepts —
              ## so the plain form yields a negative `num`, which extrapolates
              ## the plug BEFORE the run's start instead of interpolating along
              ## it, and drops hexes hundreds of pixels off the board.
              rot = (intercept div SightlineStep + t) mod max(1, spread)
              num = (rot + spread) mod max(1, spread)
              den = 2 * halfSteps
            if den == 0:
              break tryOne
            var
              px = run.x0 + (run.x1 - run.x0) * num div den
              py = run.y0 + (run.y1 - run.y0) * num div den
            if px > gameMap.center.x:
              px = gameMap.width - 1 - px
              if gameMap.symmetry == symRot180:
                py = gameMap.height - 1 - py
            ## Protected floor (the flag ring and every endzone disc) is never
            ## walled, and the endzone APRON must stay clear or the map loses
            ## the open flanks the validator demands.
            if mapProtectedFloorAt(gameMap, px, py):
              break tryOne
            if endzoneFloorAt(px, py, redAnchorX, cy, apron, true):
              break tryOne
            ## Keep a corridor's worth of clear ground OUTSIDE the flag ring,
            ## so the rotated order above cannot rebuild the ring it exists to
            ## avoid. Belt and braces, deliberately: the scatter alone fixed
            ## the measured failures, but the two together took connectivity
            ## rejections from 19 in 200 seeds to ZERO.
            let
              rdx = px - gameMap.center.x
              rdy = py - gameMap.center.y
              ringKeepOut = gameMap.flagRing + MinCorridorWidth + 30
            if rdx * rdx + rdy * rdy <= ringKeepOut * ringKeepOut:
              break tryOne
            gameMap.leftObstacles.add hexShape(px, py, 28)
            placed = true
        if not placed:
          continue
        dec plugsLeft
        inc plugged
    if plugged == 0:
      break

proc columnBand*(gameMap: CtfMap, x, margin: int): tuple[lo, hi: int] =
  ## The vertical span of column `x` that sits at least `margin` px inside the
  ## hexagon. This is the one structural change a hex board forces on the
  ## column generator: on a rectangle every column ran the full height, so the
  ## band was a constant; on a hexagon the columns nearer the vertical axis
  ## reach further up and down, which is exactly why the terrain reads as
  ## hexagonal rather than as a rectangle with the corners painted out.
  let
    board = gameMap.mapBoard()
    limit = float(margin)
    cy = gameMap.center.y
  if board.hexEdgeDist(x, cy) < limit:
    return (cy, cy - 1)      ## empty: the whole column is inside the wall.
  var lo = cy
  while lo > 0 and board.hexEdgeDist(x, lo - 1) >= limit:
    dec lo
  var hi = cy
  while hi < gameMap.height - 1 and board.hexEdgeDist(x, hi + 1) >= limit:
    inc hi
  (lo, hi)

proc generateMapAttempt*(
  seed: int, overrides: MapGenOverrides, teams = 2
): CtfMap =  ## One UNVALIDATED draw. Every top-level parameter is drawn unconditionally
  ## and THEN overridden if locked, so locking one knob never shifts the
  ## other draws for the same seed.
  ##
  ## HEX STAGE 2 generates 2-team boards only. The structure pass that fills a
  ## hexagon with genuinely hexagonal terrain (rings, wedges, cube-space
  ## orbits) is a separate epic; this is the minimal adaptation that emits a
  ## VALID hex map — terrain inside the hull, symmetric under the map's group,
  ## passing the validators.
  if teams != 2:
    raise newException(
      CtfError, "Hex Stage 2 generates 2-team maps only; " & $teams &
        " teams needs the cube-space orbit rasterizer (Stage 2b).")
  var rng = MapRng(state: uint64(seed))

  ## One draw over ALL size classes, in its historical stream slot.
  let sizeDraw = MapSizeNames[rng.pick(MapSizeNames.len)]
  let sizeName = if overrides.size.len > 0: overrides.size else: sizeDraw
  result = scaledGenShell(sizeName)
  result.name = "gen-" & $seed
  result.path = GenMapName
  result.genSeed = seed
  result.layout = layoutHex2

  let symDraw = if rng.coin(): symRot180 else: symMirrorHex
  result.symmetry =
    case overrides.symmetry
    of "": symDraw
    of "mirror", "mirrorHex": symMirrorHex
    of "rot180": symRot180
    of "rot120", "rot60", "klein4":
      raise newException(
        CtfError, "Map symmetry " & overrides.symmetry &
          " needs 3, 4, or 6 teams (hex Stage 2b).")
    else:
      raise newException(
        CtfError, "Unknown map symmetry: " & overrides.symmetry)
  if overrides.layout.len > 0 and overrides.layout notin ["sides", "hex2"]:
    raise newException(
      CtfError, "Map layout " & overrides.layout & " is not a 2-team layout.")

  ## Endzone. Every hex endzone is a DISC (the one rotation-invariant shape),
  ## so what used to be an archetype draw is now only its radius and the base
  ## depth. Both still come from the SEPARATE stream keyed off the same seed,
  ## so the main draw order never shifts.
  block endzoneDraw:
    if overrides.endzone notin ["", "disc"]:
      raise newException(
        CtfError, "The hex arena is all-disc; unknown map endzone: " &
          overrides.endzone)
    var ezRng = MapRng(state: uint64(seed) xor 0x5A17E9D3C0FFEE11'u64)
    discard ezRng.pick(4)      ## the retired archetype draw keeps its slot.
    result.endzone = ezDisc
    let
      ## The radius keeps a fraction of the board WIDTH; the DEPTH is then
      ## SOLVED from what the board can actually afford, not drawn blind.
      ##
      ## A deep base has to pay for two things at once on the same half-field,
      ## and the hex half-field is 484px where the rectangle's was 617:
      ##   IN FRONT — `anchorDist - (r + apron) - flagRing` px of ordinary
      ##     midfield, or the protected apron TOUCHES the always-open flag ring
      ##     and the row through both bases is a lane no obstacle may ever stand
      ##     in: permanently open, unpluggable, rejected every attempt.
      ##   BEHIND  — `A - anchorDist - (r + apron)` px of buildable ground, or
      ##     the WILDERNESS behind the base (the whole reason to move a base off
      ##     its edge, and a promise docs/RULES.md makes) comes out bare.
      ##
      ## Drawing the depth from a fixed range satisfies at most one of those.
      ## 520-620 ate the midfield; 600-700 ate the wilderness; and on the SMALL
      ## class the window between them is four permille wide, so no fixed range
      ## can be right for every size class at once. So the window is computed
      ## and the draw happens inside it — and if the radius is too big for the
      ## board to afford any window at all, the RADIUS gives way, because it is
      ## the parameter with slack.
      radiusDraw = result.height * ezRng.pickRange(89, 113) div 1000
      depthDraw = ezRng.pickRange(0, 1000)   ## resolved against the window
    result.endzoneRadius =
      if overrides.endzoneRadius > 0: overrides.endzoneRadius else: radiusDraw
    if overrides.baseDepth > 0:
      result.homeDepth = overrides.baseDepth
    else:
      ## Shrink the radius until the board can afford SOME depth, then pick one
      ## inside the affordable window with the drawn fraction.
      ##
      ## The window itself comes from `homeDepthWindow`, which measures the real
      ## anchor against the real hull. It used to be inlined here as
      ## `maxDist = halfField - reserved - 40`, which assumed the hull sits
      ## `halfField` away along the base's ray and closes in at rate 1. That was
      ## true while the 2-team axis ran to an EDGE MIDPOINT; on the landscape
      ## board it runs to a VERTEX, where the clearance is `cos 30` of the
      ## radial distance, and the inlined form overstated the affordable depth
      ## by 15%. Sharing one solver with `arenaHexCtfMap` is what keeps that
      ## correction from being applied in one place and forgotten in the other.
      let floorR = minEndzoneRadius(result.height)
      var window = (lo: 0, hi: -1)
      while true:
        window = result.homeDepthWindow()
        if window.lo <= window.hi or result.endzoneRadius <= floorR:
          break
        result.endzoneRadius = max(floorR, result.endzoneRadius - 4)
      result.homeDepth =
        if window.lo > window.hi:
          ## The class cannot host both at any depth. Split the difference
          ## rather than silently favouring one — the validators still judge
          ## the result, so this cannot ship a map that fails either way.
          clamp((HomeDepthMin + HomeDepthMax) div 2, HomeDepthMin, HomeDepthMax)
        else:
          clamp(window.lo + depthDraw * (window.hi - window.lo) div 1000,
                HomeDepthMin, HomeDepthMax)
    if result.homeDepth < HomeDepthMin or result.homeDepth > HomeDepthMax:
      raise newException(
        CtfError, "Config field mapBaseDepth must be " & $HomeDepthMin &
          ".." & $HomeDepthMax & ".")
    if result.endzoneRadius < minEndzoneRadius(result.height) or
        result.endzoneRadius > maxEndzoneRadius(result.height):
      raise newException(
        CtfError, "Config field mapEndzoneRadius must be " &
          $minEndzoneRadius(result.height) & ".." &
          $maxEndzoneRadius(result.height) & ".")
  result.rooms = result.defaultCtfRooms()

  let featureDraw = CenterFeatureNames[rng.pick(3)]
  let feature =
    if overrides.centerFeature.len > 0: overrides.centerFeature
    else: featureDraw
  if feature notin CenterFeatureNames:
    raise newException(CtfError, "Unknown map center feature: " & feature)

  ## The column counts were tuned on the standard field and the slots spread
  ## over the width, so the oversize classes multiply the draw bounds by their
  ## field scale; the three classic classes keep factor 1 exactly.
  let columnScale =
    if sizeName in ["huge", "giant", "colossal"]: mapSizeScale(sizeName)
    else: 1.0
  proc cols(value: int): int = int(round(float(value) * columnScale))
  let columnsDraw = rng.pickRange(cols(5), cols(7))
  let columns =
    if overrides.columns > 0: overrides.columns else: columnsDraw
  let maxColumns = max(24, cols(8))
  if columns < 3 or columns > maxColumns:
    raise newException(
      CtfError, "Config field mapColumns must be 3.." & $maxColumns & ".")

  let
    cy = result.center.y
    redAnchorX = result.teamHomeX(Red)
    ## Obstacle columns live between the base apron and the flag-ring flank;
    ## the ring and the endzones carve any overlap back out of the wall mask.
    ## A hex endzone is a disc well off the hull, so the columns start just
    ## inside the wall and terrain wraps the base on every side.
    xMin = ArenaBorder + 34
    xMax = result.center.x - 52
  ## Window-eligible shapes: (obstacle index, column, slot y).
  var eligible: seq[tuple[idx, col, y: int]]
  ## Trench pit candidates, resolved into actual digs after the columns
  ## exist: `instead` swaps its obstacle for a pit, `gap` sits in a
  ## cleared slot's corridor, `endzone` hugs the pedestal.
  const
    pitInstead = 0
    pitGap = 1
    pitEndzone = 2
  var pitCandidates: seq[tuple[kind, obstacleIdx, x, y: int]]

  for col in 0 ..< columns:
    let
      colX = xMin + ((2 * col + 1) * (xMax - xMin)) div (2 * columns)
      family = ColumnFamily(rng.pick(4))
      period = rng.pickRange(88, 120)
      ## Phases are STRATIFIED across columns (like the hand-authored arena's
      ## 0/+48/+24/+72 ladder) with a half-period jitter: fully random phases
      ## leave rows every column misses, which the sightline validator rejects.
      phase = (period * col div columns +
        rng.pick(max(1, period div 2))) mod period
      ## THE hex change: each column's usable span is the hexagon's own
      ## vertical extent at that x, not a board-wide constant.
      band = result.columnBand(colX, ArenaBorder + 30)
    var slotYs: seq[int]
    var slotY = band.lo + phase
    while slotY <= band.hi:
      slotYs.add slotY
      slotY += period
    if slotYs.len < 3:
      continue

    ## Clear-mask: drop each slot with probability 1/4, then guarantee at
    ## least one gap (a solid picket walls the lane off) and at least half
    ## the slots kept (a bare column gives no cover).
    var cleared = newSeq[bool](slotYs.len)
    var clearedCount = 0
    for i in 0 ..< slotYs.len:
      if rng.pick(4) == 0:
        cleared[i] = true
        inc clearedCount
    if clearedCount == 0:
      cleared[rng.pick(slotYs.len)] = true
      clearedCount = 1
    let minKept = (slotYs.len + 1) div 2
    while slotYs.len - clearedCount < minKept and clearedCount > 1:
      var idx = rng.pick(slotYs.len)
      while not cleared[idx]:
        idx = (idx + 1) mod slotYs.len
      cleared[idx] = false
      dec clearedCount

    var zig = rng.coin()
    for i, sy in slotYs:
      ## The endzone keeps an APRON of clear ground outside its ring: terrain
      ## that crowded the scoring disc would seal the very approaches that make
      ## an off-the-edge base worth building, and the open-flank validator
      ## would reject the map anyway.
      if endzoneFloorAt(colX, sy, redAnchorX, cy,
          result.endzoneRadius + EndzoneApron - EndzoneWallMargin, true):
        continue
      if cleared[i]:
        ## A cleared gap can hold a dug pit BETWEEN the column's obstacles
        ## — the corridor stays open to movement and fire.
        pitCandidates.add (pitGap, -1, colX, sy)
        continue
      ## Every kept slot can dig a trench INSTEAD of raising its obstacle
      ## — cover you stand in rather than behind.
      pitCandidates.add (pitInstead, result.leftObstacles.len, colX, sy)
      case family
      of colStubs:
        ## Stub ends whose gap to the hull would drop under the corridor
        ## minimum reach the wall instead — a sub-26px slit is impassable
        ## anyway and reads as a wart. On a hexagon "the wall" is a slanted
        ## edge, so the stub grows past the band end rather than to a
        ## constant y and the border carves it back.
        var top = sy - 30
        var bottom = sy + 30
        if i == 0 and top - band.lo < MinCorridorWidth:
          top = band.lo - ArenaBorder - 30
        if i == slotYs.len - 1 and band.hi - bottom < MinCorridorWidth:
          bottom = band.hi + ArenaBorder + 30
        ## The overshoot is deliberate — the hull carves the stub flush against
        ## a SLANTED wall, where a stub clamped to the band would leave a
        ## sliver of floor — but it must stay ON THE BOARD. Near the top and
        ## bottom vertices a column's band starts within 40px of the edge, so
        ## an unclamped overshoot runs off the canvas into negative y, where
        ## the rasterizer clips it and every reader has to remember that it did.
        top = clamp(top, 0, result.height - 1)
        bottom = clamp(bottom, top + 1, result.height - 1)
        result.leftObstacles.add rectShape(
          MapRect(x: colX - 9, y: top, w: 18, h: bottom - top))
        eligible.add (result.leftObstacles.high, col, sy)
      of colDiamonds:
        ## Hexagonal cover on a hexagonal board — the kind that is closed
        ## under the arena's own 60-degree rotation, where the old diamond
        ## (a C4 shape) was not.
        result.leftObstacles.add hexShape(colX, sy, 28)
        eligible.add (result.leftObstacles.high, col, sy)
      of colDiscs:
        result.leftObstacles.add ArenaShape(
          kind: shapeDisc, cx: colX, cy: sy, radius: 28)
        eligible.add (result.leftObstacles.high, col, sy)
      of colChevrons:
        ## Chevrons angled with the hull's own edges instead of across them;
        ## the point-to-segment test is angle-general, so this costs nothing.
        let (ya, yb) = if zig: (sy - 24, sy + 24) else: (sy + 24, sy - 24)
        result.leftObstacles.add ArenaShape(kind: shapeDiagonal,
          x0: colX - 14, y0: ya, x1: colX + 14, y1: yb, thickness: 12)
        zig = not zig

  ## Endzone trench pit candidates, authored on the RED side (the symmetry
  ## image gives Blue the exact counterpart): BEHIND the pedestal toward
  ## the hull, and ABOVE and BELOW it — each clear of the pedestal art.
  let
    pedestalClear = PedestalCoverSize div 2 + TrenchSize div 2
    pitOffset =
      max(pedestalClear,
        min(pedestalClear + 20,
          result.endzoneRadius - TrenchSize div 2 - EndzoneWallMargin))
  pitCandidates.add (pitEndzone, -1, redAnchorX - pitOffset, cy)
  pitCandidates.add (pitEndzone, -1, redAnchorX, cy - pitOffset)
  pitCandidates.add (pitEndzone, -1, redAnchorX, cy + pitOffset)

  ## Pit selection. DENSITY mode (default) rolls every candidate at its
  ## class chance scaled by pitDensity percent. COUNT mode (pits locked)
  ## shuffles the candidates and takes symmetric pairs until the requested
  ## total is met — an ODD total anchors its extra pit at the exact map
  ## center, the one spot that is its own image under mirror AND rot180.
  if overrides.pits < -1 or overrides.pits > 64:
    raise newException(CtfError, "Config field mapPits must be 0..64.")
  if overrides.pitDensity < -1 or overrides.pitDensity > 1000:
    raise newException(
      CtfError, "Config field mapPitDensity must be 0..1000.")
  let
    pitDensity = if overrides.pitDensity >= 0: overrides.pitDensity else: 100
    centerPit = trenchSquareAt(result.center.x, result.center.y)
    oddCenterPit = overrides.pits >= 0 and overrides.pits mod 2 == 1
    pitPairsWanted = if overrides.pits >= 0: overrides.pits div 2 else: -1
  var obstacleRemoved = newSeq[bool](result.leftObstacles.len)
  if pitPairsWanted >= 0:
    rng.shuffle(pitCandidates)
  for cand in pitCandidates:
    if pitPairsWanted >= 0:
      if result.trenches.len >= pitPairsWanted:
        break
    else:
      let baseChance =
        case cand.kind
        of pitInstead: 17
        of pitGap: 25
        else: 50
      if rng.pick(100) >= clamp(baseChance * pitDensity div 100, 0, 100):
        continue
    let pit = trenchSquareAt(cand.x, cand.y)
    var blocked = oddCenterPit and rectsIntersect(pit, centerPit)
    for accepted in result.trenches:
      if rectsIntersect(shapeAsRect(accepted), pit):
        blocked = true
        break
    if blocked:
      continue
    result.trenches.add rectShape(pit)
    if cand.kind == pitInstead:
      obstacleRemoved[cand.obstacleIdx] = true

  ## Swap the chosen `instead` obstacles out of the wall set. Window
  ## eligibility indexes leftObstacles, so compact both together.
  block removeSwappedObstacles:
    var remap = newSeq[int](result.leftObstacles.len)
    var compacted: seq[ArenaShape]
    for i, shape in result.leftObstacles:
      if obstacleRemoved[i]:
        remap[i] = -1
      else:
        remap[i] = compacted.len
        compacted.add shape
    result.leftObstacles = compacted
    var remappedEligible: seq[tuple[idx, col, y: int]]
    for entry in eligible:
      if remap[entry.idx] >= 0:
        remappedEligible.add (remap[entry.idx], entry.col, entry.y)
    eligible = remappedEligible

  ## Center feature, straddling the horizontal midline just outside the
  ## flag ring ("[" here; its symmetry image closes the right side).
  let bx = result.center.x - result.flagRing - 68
  case feature
  of "bracket":
    ## The GV16 windowed bracket: mid lane closed to movement and fire,
    ## glass pane over the midline for a fogless center sightline.
    result.leftObstacles.add rectShape(
      MapRect(x: bx, y: cy - 53, w: 28, h: 12))
    result.leftObstacles.add rectShape(
      MapRect(x: bx, y: cy - 41, w: 12, h: 24))
    result.leftObstacles.add rectShape(
      MapRect(x: bx, y: cy - 17, w: 12, h: 36), window = true)
    result.leftObstacles.add rectShape(
      MapRect(x: bx, y: cy + 19, w: 12, h: 23))
    result.leftObstacles.add rectShape(
      MapRect(x: bx, y: cy + 42, w: 28, h: 12))
  of "walls":
    ## Solid bar pair with an open (glassless) midline gap.
    result.leftObstacles.add rectShape(
      MapRect(x: bx, y: cy - 100, w: 12, h: 80))
    result.leftObstacles.add rectShape(
      MapRect(x: bx, y: cy + 20, w: 12, h: 80))
  else:
    discard  # "ring": the center stays fully open.

  ## Sightline repair, on all three hex axes — shared with the hand-authored
  ## arena, which has to hold exactly the same published promise.
  result.plugOpenSightlines(cols(120))

  ## Glass windows: fog sees through them, nothing passes them. Biased to
  ## the outermost column and the midline band, where sightlines matter.
  let windowsDraw = rng.pickRange(2, 4)
  let windowCount =
    if overrides.windows >= 0: overrides.windows else: windowsDraw
  if windowCount > 6:
    raise newException(CtfError, "Config field mapWindows must be 0..6.")
  var preferred, rest: seq[tuple[idx, col, y: int]]
  for entry in eligible:
    if entry.col == 0 or abs(entry.y - cy) < 70:
      preferred.add entry
    else:
      rest.add entry
  rng.shuffle(preferred)
  rng.shuffle(rest)
  let ranked = preferred & rest
  for i in 0 ..< min(windowCount, ranked.len):
    result.leftObstacles[ranked[i].idx].window = true

  ## Med kits. Two seeds are drawn on the board's vertical symmetry axis and
  ## each is expanded through its full symmetry orbit, so the candidate set is
  ## exactly its own image under whichever group the map drew.
  ##
  ## THE SEEDS SIT JUST OFF THE VERTICAL AXIS, and that is the whole trick. A
  ## point ON a symmetry axis is a FIXED POINT of the reflection across it, so
  ## its orbit has size ONE, not two: seeding at `(width - 1) div 2` collapsed
  ## both kits into a single central kit on every ODD-width mirror board
  ## (standard 969, giant 2519, colossal 5039) and then read `medKitSpawns[1]`
  ## out of bounds. The scheme it replaced — "x = W/2, y and H-1-y" — had the
  ## exact COMPLEMENTARY hole on even widths. Both were the same mistake:
  ## assuming an orbit's size instead of checking it.
  ##
  ## So the placement is off-axis on every width AND the orbit size is
  ## ASSERTED. `width div 2 - 1` and its image straddle the centre line by one
  ## pixel either way, which keeps both kits as central and as contested as the
  ## on-axis pair was meant to be, while giving the group nothing to fix.
  let
    axisX = result.width div 2 - 1
    y1 = rng.pickRange(result.height * 16 div 100, result.height * 34 div 100)
    y2 = rng.pickRange(result.height * 36 div 100, result.height * 47 div 100)
  proc kitOrbit(gameMap: CtfMap, seedPoint: MapPoint): seq[MapPoint] =
    ## One kit seed's full orbit, with its SIZE checked. A short orbit means
    ## the seed landed on a symmetry axis and the map would ship with fewer
    ## kits than the contract states — silently, and then out of bounds.
    result = gameMap.symmetryImages(seedPoint)
    doAssert result.len == gameMap.teamCount(),
      "med-kit seed " & $seedPoint & " has a stabilizer under " &
        $gameMap.symmetry & ": orbit is " & $result.len & ", not " &
        $gameMap.teamCount() & " — it is sitting on a symmetry axis."
  result.medKitCandidates = @[]
  for seedPoint in [MapPoint(x: axisX, y: y1), MapPoint(x: axisX, y: y2)]:
    for image in result.kitOrbit(seedPoint):
      result.medKitCandidates.add image
  result.medKitSpawns =
    if rng.coin():
      result.kitOrbit(MapPoint(x: axisX, y: y1))
    else:
      result.kitOrbit(MapPoint(x: axisX, y: y2))

  ## Finalize the trenches. Every left-half dig gets its image under the map's
  ## symmetry so neither team has a private pit; a dig that ended up under a
  ## wall (a sightline-repair plug can land on its slot) or on top of an
  ## already-accepted dig is dropped — and a dig whose image is blocked drops
  ## WITH it, fairness before density.
  block finalizeTrenches:
    let obstacles = buildArenaObstacles(result)
    var digs: seq[MapRect]
    if oddCenterPit:
      ## The odd pit sits dead center, inside the always-open flag ring.
      digs.add centerPit
    proc addPair(
      gameMap: CtfMap, digs: var seq[MapRect], trench: MapRect
    ): bool =
      ## Accepts one left-half dig plus its symmetry image when both sit
      ## on open floor clear of every accepted dig.
      let image =
        case gameMap.symmetry
        of symMirrorHex: trench.mirrorX(gameMap.width)
        of symRot180: trench.rot180(gameMap.width, gameMap.height)
        else: raiseAssert "2-team map with a non-2-team symmetry"
      if not rectOnOpenFloor(gameMap, obstacles, trench) or
          not rectOnOpenFloor(gameMap, obstacles, image):
        return false
      for accepted in digs:
        if rectsIntersect(accepted, trench) or
            rectsIntersect(accepted, image):
          return false
      digs.add trench
      if image != trench:
        digs.add image
      true
    for trench in result.trenches:
      discard result.addPair(digs, shapeAsRect(trench))
    ## COUNT mode: pairs lost to sightline-repair walls are topped back up
    ## from the unused candidates that cannot change the wall set.
    if pitPairsWanted >= 0:
      for cand in pitCandidates:
        if digs.len >= overrides.pits:
          break
        if cand.kind == pitInstead:
          continue
        discard result.addPair(digs, trenchSquareAt(cand.x, cand.y))
    result.trenches = @[]
    for d in digs:
      result.trenches.add rectShape(d)
  result.validateMap()

type
  MapDiagnosticArtifact* = enum
    ## Full-board diagnostic arrays callers may opt into. Summary diagnostics
    ## never retain these large buffers: a giant board has 5.5 million pixels,
    ## and the editor's threaded HTTP service may diagnose several maps at once.
    diagnosticWallMasks
    diagnosticCorridorOpen
    diagnosticReachable

  EndzoneGateState* = enum
    ## Whether one compact-endzone flank gate is usable by the eroded flood.
    gateOpen
    gateOffMap
    gateSealed

  EndzoneGateDiagnostic* = object
    ## The position and reachability state of one named compact-endzone gate.
    name*: string
    point*: MapPoint
    state*: EndzoneGateState

  MapDiagnostics* = object
    ## Play-quality measurements for one map. Scalar and compact sequence
    ## summaries are always populated. Full-board arrays are populated only
    ## when their matching MapDiagnosticArtifact is requested.
    reason*: string
    coverPermille*, minCoverPermille*: int
    openSightlineRows*: seq[int]
      ## Every open row in the validator's historical 4px scan, not every
      ## physical map row.
    redHomeOnOpenFloor*: bool
    unreachableTeams*: seq[Team]
    centerReachable*: bool
    endzoneGates*: seq[EndzoneGateDiagnostic]
    endzoneFlankChecked*: bool
    rearGateReachesCenterWithoutEndzone*: bool
    maxWall*, minWall*: seq[bool]
      ## Swept-union / always-stone masks; retained by diagnosticWallMasks.
    corridorOpen*: seq[bool]
      ## Player-width-eroded floor; retained by diagnosticCorridorOpen.
    reachable*: seq[bool]
      ## Eroded floor reachable from Red; retained by diagnosticReachable.

proc collectMapDiagnostics(
  gameMap: CtfMap,
  artifacts: set[MapDiagnosticArtifact],
  stopAfterFirstFailure: bool,
): MapDiagnostics =
  ## The shared staged implementation behind full editor diagnostics and the
  ## generator's first-failure validator. The latter preserves the old early
  ## exits, so rejected attempts do not pay for later distance/flood stages.
  template recordFailure(message: string) =
    if result.reason.len == 0:
      result.reason = message
    if stopAfterFirstFailure:
      return

  let
    w = gameMap.width
    h = gameMap.height
    obstacles = buildArenaObstacles(gameMap)
  ## A spinning diamond is not one shape, so validation cannot use one mask:
  ## these invariants point in OPPOSITE directions (GV29).
  ##   maxWall — the swept union. Use it where MORE wall is the pessimistic
  ##     case: a corridor that closes at any frame is not a corridor, and a
  ##     map that is too clogged at any frame is too clogged.
  ##   minWall — the intersection over the turn, stone at every frame. Use it
  ##     where LESS wall is pessimistic: a firing lane that opens at any frame
  ##     is an open lane, and cover that comes and goes cannot prop up the
  ##     cover floor.
  ## A sightline checked against the swept mask would let a map ship with a
  ## cross-map lane that opens on a clock: the diamonds reach 29 px along an
  ## axis at rest but only 20 px a third of a turn later, while the swept disc
  ## claims 30 px at all times. Two seeds in the pre-GV29 pool had exactly
  ## that defect, which is why the pool was re-curated with this change.
  var (maxWall, minWall) = rasterizeWallMasks(gameMap, obstacles)
  var minCoverPixels, coverPixels, interiorPixels = 0
  for y in 0 ..< h:
    for x in 0 ..< w:
      ## The cover-budget interior: the actually-playable field — everything
      ## inside the hull's border ring that is not protected floor. The void
      ## outside the hexagon is excluded by the same predicate that walls it,
      ## so the budget is measured against the PLAYFIELD (75% of the bounding
      ## box), never against the box.
      let interior =
        not gameMap.mapBorderWallAt(x, y) and
          not mapProtectedFloorAt(gameMap, x, y)
      if interior:
        inc interiorPixels
        if maxWall[y * w + x]:
          inc coverPixels
        if minWall[y * w + x]:
          inc minCoverPixels

  ## Cover budget: neither an open field nor a clogged maze — at EVERY frame,
  ## so the floor is measured on the cover that is always there and the
  ## ceiling on the cover that is ever there.
  let
    permille = coverPixels * 1000 div max(1, interiorPixels)
    minPermille = minCoverPixels * 1000 div max(1, interiorPixels)
  result.coverPermille = permille
  result.minCoverPermille = minPermille
  if minPermille < CoverPermilleMin:
    recordFailure("too open: " & $minPermille & " permille cover")
  if permille > CoverPermilleMax:
    recordFailure("too clogged: " & $permille & " permille cover")

  ## With map-wide guns no straight ray may survive a full lane down ANY of
  ## the hexagon's three axes. On the rectangle only the horizontal family
  ## mattered, because the other two board edges were the top and bottom
  ## walls; a hexagon has three pairs of opposite edges and a lane down any of
  ## them is the same cross-field snipe. `sightlineMinSpan` is what keeps the
  ## short chords near the two vertices from failing every map ever drawn.
  block sightlines:
    for axis in 0 .. 2:
      for intercept in gameMap.sightlineIntercepts(axis):
        if gameMap.sightlineOpenRun(minWall, axis, intercept).open:
          if axis == 0:
            result.openSightlineRows.add intercept
          if result.reason.len == 0:
            result.reason = "open sightline on axis " & $(60 * axis) &
              " deg at intercept " & $intercept
          if stopAfterFirstFailure:
            return
  if diagnosticWallMasks in artifacts:
    result.minWall = minWall
  else:
    minWall.setLen(0)

  ## Corridor + connectivity: chamfer 3-4 distance to the nearest wall,
  ## eroded by half the corridor minimum, then a flood fill — both flags and
  ## the center must connect through corridors the player footprint can
  ## actually use.
  var dist = newSeq[int32](w * h)
  for i in 0 ..< w * h:
    dist[i] = if maxWall[i]: 0'i32 else: int32.high div 2
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      if dist[i] == 0:
        continue
      var d = dist[i]
      if x > 0: d = min(d, dist[i - 1] + 3)
      if y > 0: d = min(d, dist[i - w] + 3)
      if x > 0 and y > 0: d = min(d, dist[i - w - 1] + 4)
      if x < w - 1 and y > 0: d = min(d, dist[i - w + 1] + 4)
      dist[i] = d
  for y in countdown(h - 1, 0):
    for x in countdown(w - 1, 0):
      let i = y * w + x
      if dist[i] == 0:
        continue
      var d = dist[i]
      if x < w - 1: d = min(d, dist[i + 1] + 3)
      if y < h - 1: d = min(d, dist[i + w] + 3)
      if x < w - 1 and y < h - 1: d = min(d, dist[i + w + 1] + 4)
      if x > 0 and y < h - 1: d = min(d, dist[i + w - 1] + 4)
      dist[i] = d
  let minChamfer = int32((MinCorridorWidth div 2) * 3)
  var open = newSeq[bool](w * h)
  for i in 0 ..< w * h:
    open[i] = dist[i] >= minChamfer
  dist.setLen(0)
  if diagnosticWallMasks in artifacts:
    result.maxWall = maxWall
  else:
    maxWall.setLen(0)

  let
    redHome = gameMap.flagHome(Red)
    startIndex = redHome.y * w + redHome.x
  var
    reached = newSeq[bool](w * h)
    queue: seq[int]
  result.redHomeOnOpenFloor = open[startIndex]
  if not result.redHomeOnOpenFloor:
    recordFailure("red flag home is not on open floor")
  else:
    reached[startIndex] = true
    queue.add startIndex
  var head = 0
  while head < queue.len:
    let i = queue[head]
    inc head
    for step in [-1, 1, -w, w]:
      let j = i + step
      if j >= 0 and j < w * h and open[j] and not reached[j]:
        ## Row wrap at the border can't happen: the border ring is wall,
        ## so open[] is false along every edge.
        reached[j] = true
        queue.add j
  for team in gameMap.teams():
    if team == Red:
      continue
    let home = gameMap.flagHome(team)
    if not reached[home.y * w + home.x]:
      result.unreachableTeams.add team
      let message =
        if gameMap.teamCount() == 2:
          "no " & $MinCorridorWidth & "px route between the flags"
        else:
          "no " & $MinCorridorWidth & "px route to the " &
            teamText(team) & " flag"
      recordFailure(message)
  result.centerReachable = reached[gameMap.center.y * w + gameMap.center.x]
  if not result.centerReachable:
    recordFailure("no " & $MinCorridorWidth & "px route to the center")

  ## Endzones must stay OPEN-FLANKED: a base you can only reach from the field
  ## side is a wall with a pedestal in front of it. Checked on Red alone —
  ## every symmetry the board can wear hands the other teams the exact image.
  block endzoneFlanks:
    let
      anchor = gameMap.teamAnchor(Red)
      gate = gameMap.endzoneRadius + MinCorridorWidth div 2 + 4
      gates = [
        (name: "behind", point: MapPoint(x: anchor.x - gate, y: anchor.y)),
        (name: "above", point: MapPoint(x: anchor.x, y: anchor.y - gate)),
        (name: "below", point: MapPoint(x: anchor.x, y: anchor.y + gate)),
        (name: "ahead", point: MapPoint(x: anchor.x + gate, y: anchor.y)),
      ]
    var allGatesOpen = true
    for g in gates:
      var state = gateOpen
      if g.point.x < 0 or g.point.y < 0 or
          g.point.x >= w or g.point.y >= h:
        state = gateOffMap
        allGatesOpen = false
        recordFailure("endzone gate " & g.name & " is off the map")
      elif not reached[g.point.y * w + g.point.x]:
        state = gateSealed
        allGatesOpen = false
        recordFailure("endzone gate " & g.name & " is sealed")
      result.endzoneGates.add EndzoneGateDiagnostic(
        name: g.name, point: g.point, state: state)

    ## ...and the way in from behind must not run THROUGH the endzone: fill
    ## from the rear gate with the zone itself forbidden and demand the
    ## center. That is the whole point of moving the base off the edge.
    if allGatesOpen:
      let zone = gameMap.captureZone(Red)
      var
        around = newSeq[bool](w * h)
        backQueue = @[gates[0].point.y * w + gates[0].point.x]
      result.endzoneFlankChecked = true
      around[backQueue[0]] = true
      head = 0
      while head < backQueue.len:
        let i = backQueue[head]
        inc head
        for step in [-1, 1, -w, w]:
          let j = i + step
          if j < 0 or j >= w * h or not open[j] or around[j]:
            continue
          if zone.inCaptureZone(j mod w, j div w):
            continue
          around[j] = true
          backQueue.add j
      result.rearGateReachesCenterWithoutEndzone =
        around[gameMap.center.y * w + gameMap.center.x]
      if not result.rearGateReachesCenterWithoutEndzone:
        recordFailure("no route around the endzone from behind the base")

  if diagnosticCorridorOpen in artifacts:
    result.corridorOpen = open
  if diagnosticReachable in artifacts:
    result.reachable = reached

proc mapDiagnostics*(
  gameMap: CtfMap,
  artifacts: set[MapDiagnosticArtifact] = {},
): MapDiagnostics =
  ## Computes every play-quality diagnostic for one map. Full-board artifact
  ## arrays are retained only when explicitly requested; scalar summaries and
  ## failure details are always complete.
  collectMapDiagnostics(gameMap, artifacts, stopAfterFirstFailure = false)

proc mapValidationReason*(diagnostics: MapDiagnostics): string =
  ## Returns the canonical first failure from a completed diagnostic pass.
  diagnostics.reason

proc validateGeneratedMap*(gameMap: CtfMap): string =
  ## Returns "" when the layout passes every play-quality invariant, else a
  ## human-readable failure reason. The generator's design intent lives HERE,
  ## not in the draws: anything that passes is fair game.
  collectMapDiagnostics(gameMap, {}, stopAfterFirstFailure = true).reason

proc generateCtfMap*(
  seed: int,
  overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1),
  teams = 2
): CtfMap =
  ## Generates a VALIDATED map: attempts seeds seed, seed+1, ... until one
  ## passes every validator. A locked-parameter combination that can never
  ## pass errors out after MapGenMaxAttempts.
  for attempt in 0 ..< MapGenMaxAttempts:
    let candidate = generateMapAttempt(seed + attempt, overrides, teams)
    if validateGeneratedMap(candidate).len == 0:
      return candidate
  raise newException(
    CtfError,
    "Map generation found no valid layout in " & $MapGenMaxAttempts &
      " attempts from seed " & $seed & " (over-constrained overrides?)."
  )

proc arenaHexObstacles(gameMap: CtfMap): seq[ArenaShape] =
  ## The hand-authored default arena's LEFT-HALF cover set, built from the
  ## board's own hexagon rather than typed out as pixel literals.
  ##
  ## The old 1235x659 tables could not survive the move: they were authored
  ## column by column against a straight top and bottom border, and on a
  ## pointy-top hull those columns run out of field at different heights.
  ## Deriving each column's vertical span from `hexEdgeDist` instead re-fits
  ## the layout to every size class for free, and it is the same slalom the
  ## arena always was — staggered columns whose in-column gaps are offset from
  ## their neighbours', so no straight cross-field ray survives while every
  ## corridor stays wider than the 13px player footprint.
  ##
  ## Left half only; `buildArenaObstacles` mirrors it. Nothing here is random.
  let
    board = gameMap.mapBoard()
    cx = gameMap.center.x
    cy = gameMap.center.y
    anchor = gameMap.teamAnchor(Red)
    apron = gameMap.endzoneRadius + EndzoneApron - EndzoneWallMargin
    ## The columns span the WHOLE half-field, wall to flag ring — not the gap
    ## between the base and the center. A hex base sits deep, so a span that
    ## started past its apron would crush five columns into a ~95px strip and
    ## leave the entire outer third of the board an empty run-up.
    xLo = ArenaBorder + 34
    xHi = cx - 52
    columns = 6
    period = 96
  for col in 0 ..< columns:
    let
      colX = xLo + ((2 * col + 1) * (xHi - xLo)) div (2 * columns)
      ## The classic 0 / +48 / +24 / +72 phase ladder, so each column's gaps
      ## sit opposite its neighbours' and no row is missed by all of them.
      phase = (period * col) div columns
    ## How far the field reaches above and below this column, on the hexagon.
    var span = 0
    while cy - span - 1 > 0 and
        board.hexEdgeDist(colX, cy - span - 1) >= float(ArenaBorder + 30):
      inc span
    if span < period:
      continue
    let slots = (2 * span) div period
    for i in 0 .. slots:
      let sy = cy - span + phase + i * period
      if sy < cy - span or sy > cy + span:
        continue
      ## One slot in four is cleared, so every column is a picket with real
      ## gaps rather than a wall; the cleared index walks with the column so
      ## the gaps stagger too.
      if (i + col) mod 4 == 0:
        continue
      ## Never build on the base's apron: those approaches are what make a
      ## deep base playable from every side.
      if endzoneFloorAt(colX, sy, anchor.x, cy, apron, true):
        continue
      case col mod 4
      of 0:
        result.add rectShape(MapRect(x: colX - 9, y: sy - 30, w: 18, h: 60))
      of 1:
        result.add hexShape(colX, sy, 28)
      of 2:
        result.add ArenaShape(kind: shapeDisc, cx: colX, cy: sy, radius: 28)
      else:
        ## A 60-degree chevron, angled with the hull rather than across it.
        result.add ArenaShape(kind: shapeDiagonal,
          x0: colX - 14, y0: sy - 24, x1: colX + 14, y1: sy + 24,
          thickness: 12)
  ## The GV16 windowed bracket, straddling the horizontal midline just outside
  ## the flag ring: the mid lane stays closed to movement, bullets, and spray,
  ## but its glass center pane gives both teams a fogless center sightline.
  let bx = cx - gameMap.flagRing - 68
  result.add rectShape(MapRect(x: bx, y: cy - 53, w: 28, h: 12))
  result.add rectShape(MapRect(x: bx, y: cy - 41, w: 12, h: 24))
  result.add rectShape(MapRect(x: bx, y: cy - 17, w: 12, h: 36), window = true)
  result.add rectShape(MapRect(x: bx, y: cy + 19, w: 12, h: 23))
  result.add rectShape(MapRect(x: bx, y: cy + 42, w: 28, h: 12))
  ## Two spinning diamonds per half, flanking the flag ring on the center
  ## column — the band `isSpinningDiamond` selects.
  result.add diamondShape(cx - 34, cy - gameMap.flagRing - 76, 30)
  result.add diamondShape(cx - 34, cy + gameMap.flagRing + 76, 30)

proc arenaHexCtfMap*(name: string, cls: HexSizeClass): CtfMap =
  ## The hand-tuned default arena on one hex size class. Obstacle SIZES never
  ## scale — a bigger field gets roomier corridors, exactly as `arena-large`
  ## always did.
  let
    board = hexBoardOf(cls)
    scale = HexClassScale[cls]
  proc s(value: int): int = int(round(float(value) * scale))
  result.name = name
  result.path = name
  result.width = board.width
  result.height = board.height
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = s(70)
  result.captureClear = s(210)
  result.spawnClearW = s(70)
  result.spawnClearH = s(130)
  result.gunRange = GunRange
  result.symmetry = symMirrorHex
  result.layout = layoutHex2
  result.endzone = ezDisc
  ## A permille of the board's SHORT axis (twice the apothem), which is the
  ## orientation-independent measure of field. Keyed to the WIDTH this would
  ## have grown 15.5% — a third more scoring area — purely because the board
  ## turned landscape.
  result.endzoneRadius = board.height * 101 div 1000
  ## RE-DERIVED, not carried over. The portrait arena shipped 650, which put
  ## the anchor 314px out along an EDGE-MIDPOINT ray with the hull 170px behind
  ## it and the apron needing 157 — 13px of daylight. The same 650 on the
  ## landscape board puts the anchor 363px out along a VERTEX ray, where the
  ## hull is only `cos 30 * 196 = 170`px away while the apron now needs 173: it
  ## fails, by 3px, silently, as an endzone clipped by the wall.
  ##
  ## So the depth is solved from the budgets instead, and the midpoint of the
  ## affordable window is taken — the same window the generator draws inside,
  ## so hand-authored and generated boards cannot drift apart.
  let window = result.homeDepthWindow()
  doAssert window.lo <= window.hi,
    "the " & name & " class affords no legal base depth"
  result.homeDepth = (window.lo + window.hi) div 2
  result.leftObstacles = arenaHexObstacles(result)
  ## Hold the SAME sightline standard every generated map must clear. The
  ## authored slalom closes most lanes on its own; this closes the rest, on
  ## every size class, without a table of hand-tuned pixel literals.
  result.plugOpenSightlines(120)
  result.medKitSpawns = @[
    MapPoint(x: result.width div 2, y: result.height div 3),
    MapPoint(x: result.width div 2, y: 2 * result.height div 3),
  ]
  result.medKitCandidates = result.medKitSpawns
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc arenaCtfMap(): CtfMap =
  ## The default arena: the hand-tuned STANDARD hexagon, 969x1119.
  arenaHexCtfMap(ArenaName, hxStandard)

proc arenaLargeCtfMap(): CtfMap =
  ## The arena-large variant: the same layout on the LARGE class, 1260x1455.
  arenaHexCtfMap(ArenaLargeName, hxLarge)

proc poolCtfMap*(
  index: int, overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
): CtfMap =
  ## One curated-pool map; the index wraps around the pool.
  let n = MapPoolSeeds.len
  generateCtfMap(MapPoolSeeds[((index mod n) + n) mod n], overrides)

proc shapeSpecNode(shape: ArenaShape): JsonNode =
  ## One obstacle as replay-spec JSON.
  result = newJObject()
  case shape.kind
  of shapeDisc:
    result["kind"] = %"disc"
    result["cx"] = %shape.cx
    result["cy"] = %shape.cy
    result["r"] = %shape.radius
  of shapeBar:
    ## DOUBLED center and half-extents go on the wire verbatim: a bar of even
    ## pixel extent has a half-pixel center, and halving it here would round a
    ## replay's geometry away.
    result["kind"] = %"bar"
    result["cx2"] = %shape.cx2
    result["cy2"] = %shape.cy2
    result["hl"] = %shape.halfLong
    result["hp"] = %shape.halfPerp
    result["ux"] = %shape.axisX
    result["uy"] = %shape.axisY
  of shapeHex:
    result["kind"] = %"hex"
    result["cx2"] = %shape.hexCx2
    result["cy2"] = %shape.hexCy2
    result["r2"] = %shape.hexR2
    if shape.flatTop:
      result["flat"] = %true
  of shapeDiagonal:
    result["kind"] = %"diagonal"
    result["x0"] = %shape.x0
    result["y0"] = %shape.y0
    result["x1"] = %shape.x1
    result["y1"] = %shape.y1
    result["t"] = %shape.thickness
  of shapePolygon:
    result["kind"] = %"polygon"
    var pts = newJArray()
    for p in shape.points:
      pts.add %*[p.x, p.y]
    result["points"] = pts
  if shape.window:
    result["window"] = %true

proc shapeFromSpecNode(node: JsonNode): ArenaShape =
  ## One obstacle parsed back from replay-spec JSON.
  let window = node{"window"}.getBool(false)
  case node["kind"].getStr()
  of "disc":
    ArenaShape(kind: shapeDisc, window: window,
      cx: node["cx"].getInt(), cy: node["cy"].getInt(),
      radius: node["r"].getInt())
  of "bar":
    ArenaShape(kind: shapeBar, window: window,
      cx2: node["cx2"].getInt(), cy2: node["cy2"].getInt(),
      halfLong: node["hl"].getInt(), halfPerp: node["hp"].getInt(),
      axisX: node["ux"].getInt(), axisY: node["uy"].getInt())
  of "hex":
    ArenaShape(kind: shapeHex, window: window,
      hexCx2: node["cx2"].getInt(), hexCy2: node["cy2"].getInt(),
      hexR2: node["r2"].getInt(), flatTop: node{"flat"}.getBool(false))
  of "rect", "diamond":
    ## GV37 and earlier. Both are exactly expressible as bars, so a pre-hex
    ## spec still loads — but it will fail `validateMap` on its rectangular
    ## aspect, which is the honest answer: its PLAYFIELD was a different shape.
    if node["kind"].getStr() == "rect":
      rectShape(MapRect(
        x: node["x"].getInt(), y: node["y"].getInt(),
        w: node["w"].getInt(), h: node["h"].getInt()), window)
    else:
      diamondShape(node["cx"].getInt(), node["cy"].getInt(),
        node["r"].getInt(), window)
  of "diagonal":
    ArenaShape(kind: shapeDiagonal, window: window,
      x0: node["x0"].getInt(), y0: node["y0"].getInt(),
      x1: node["x1"].getInt(), y1: node["y1"].getInt(),
      thickness: node["t"].getInt())
  of "polygon":
    var pts: seq[MapPoint]
    for pt in node["points"]:
      pts.add MapPoint(x: pt[0].getInt(), y: pt[1].getInt())
    ArenaShape(kind: shapePolygon, window: window, points: pts)
  else:
    raise newException(
      CtfError, "Unknown map spec shape: " & node["kind"].getStr())

proc pointsNode(points: seq[MapPoint]): JsonNode =
  result = newJArray()
  for p in points:
    result.add %*[p.x, p.y]

proc pointsFromNode(node: JsonNode): seq[MapPoint] =
  for item in node:
    result.add MapPoint(x: item[0].getInt(), y: item[1].getInt())

proc rectsNode(rects: seq[MapRect]): JsonNode =
  result = newJArray()
  for r in rects:
    result.add %*[r.x, r.y, r.w, r.h]

proc rectsFromNode(node: JsonNode): seq[MapRect] =
  if node.isNil or node.kind != JArray:
    return
  for item in node:
    result.add MapRect(
      x: item[0].getInt(), y: item[1].getInt(),
      w: item[2].getInt(), h: item[3].getInt()
    )

proc mapSpecJson*(gameMap: CtfMap): string =
  ## The FULL expanded geometry of one map as JSON. Replays pin this, so
  ## playback rebuilds the exact map even if the generator changes later.
  var shapes = newJArray()
  for shape in gameMap.leftObstacles:
    shapes.add shape.shapeSpecNode()
  var trenchShapes = newJArray()
  for trench in gameMap.trenches:
    trenchShapes.add trench.shapeSpecNode()
  $(%*{
    "name": gameMap.name,
    "genSeed": gameMap.genSeed,
    "width": gameMap.width,
    "height": gameMap.height,
    "flagRing": gameMap.flagRing,
    "captureClear": gameMap.captureClear,
    "spawnClearW": gameMap.spawnClearW,
    "spawnClearH": gameMap.spawnClearH,
    "gunRange": gameMap.gunRange,
    "symmetry": (
      case gameMap.symmetry
      of symMirrorHex: "mirrorHex"
      of symRot180: "rot180"
      of symRot120: "rot120"
      of symRot60: "rot60"
      of symKlein4: "klein4"),
    "layout": (
      case gameMap.layout
      of layoutHex2: "hex2"
      of layoutHex3: "hex3"
      of layoutHex4: "hex4"
      of layoutHex6: "hex6"),
    "endzone": (
      case gameMap.endzone
      of ezDisc: "disc"),
    "endzoneRadius": gameMap.endzoneRadius,
    "homeDepth": gameMap.homeDepthOf(),
    "medKitSpawns": pointsNode(gameMap.medKitSpawns),
    "medKitCandidates": pointsNode(gameMap.medKitCandidates),
    # Trenches are FULL-map (both halves), already symmetrized — playback
    # re-reads them verbatim, no re-mirroring. Serialized as shapes (the
    # generator emits rect pits; authored maps may use any shape).
    "trenches": trenchShapes,
    "leftObstacles": shapes,
  })

proc mapFromSpecJson*(text: string): CtfMap =
  ## Rebuilds one map from its expanded replay spec. Rooms are derived from
  ## the clearances the same way the generator derives them.
  var node: JsonNode
  try:
    node = fromJson(text)
  except jsony.JsonError as e:
    raise newException(CtfError, "Could not parse map spec JSON: " & e.msg)
  result.name = node["name"].getStr()
  result.path = GenMapName
  result.genSeed = node{"genSeed"}.getInt(0)
  result.width = node["width"].getInt()
  result.height = node["height"].getInt()
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = node["flagRing"].getInt()
  result.captureClear = node["captureClear"].getInt()
  result.spawnClearW = node["spawnClearW"].getInt()
  result.spawnClearH = node["spawnClearH"].getInt()
  result.gunRange = node["gunRange"].getInt()
  ## Missing keys default for pre-4-team pinned specs; an unknown NON-EMPTY
  ## value is a typo or a spec from a future version — replays pin specs
  ## precisely so playback is exact, so silently reinterpreting one would
  ## defeat the point. Raise instead.
  let symmetryText = node{"symmetry"}.getStr("mirrorHex")
  result.symmetry =
    case symmetryText
    of "mirrorHex", "mirror": symMirrorHex
    of "rot180": symRot180
    of "rot120": symRot120
    of "rot60": symRot60
    of "klein4": symKlein4
    else:
      raise newException(
        CtfError, "Unknown map spec symmetry: " & symmetryText)
  let layoutText = node{"layout"}.getStr("hex2")
  result.layout =
    case layoutText
    of "hex2", "sides": layoutHex2
    of "hex3": layoutHex3
    of "hex4": layoutHex4
    of "hex6": layoutHex6
    else:
      raise newException(CtfError, "Unknown map spec layout: " & layoutText)
  let endzoneText = node{"endzone"}.getStr("disc")
  result.endzone =
    case endzoneText
    of "disc": ezDisc
    else:
      raise newException(CtfError, "Unknown map spec endzone: " & endzoneText)
  result.endzoneRadius = node{"endzoneRadius"}.getInt(0)
  result.homeDepth = node{"homeDepth"}.getInt(ClassicHomeDepth)
  result.medKitSpawns = pointsFromNode(node["medKitSpawns"])
  result.medKitCandidates = pointsFromNode(node["medKitCandidates"])
  ## Optional: specs pinned before trenches existed carry none and replay
  ## without them, exactly as recorded. Back-compat: GV<=36 pinned trenches as
  ## [x, y, w, h] arrays; GV37+ pins them as shape objects (any kind). Detect
  ## per element so old replays and pool specs still load verbatim.
  let trenchNode = node{"trenches"}
  if not trenchNode.isNil and trenchNode.kind == JArray:
    for item in trenchNode:
      if item.kind == JArray:
        result.trenches.add rectShape(MapRect(
          x: item[0].getInt(), y: item[1].getInt(),
          w: item[2].getInt(), h: item[3].getInt()))  # GV<=36 [x,y,w,h]
      else:
        result.trenches.add item.shapeFromSpecNode()
  for item in node["leftObstacles"]:
    result.leftObstacles.add item.shapeFromSpecNode()
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc resolveCtfMapMetadata*(config: GameConfig): CtfMap =
  ## The effective map for one config: an explicit mapSpec wins (replay
  ## exactness), then the named maps, then the generator / curated pool.
  ## The resolved map's team count must match the config's `teams` knob —
  ## a 4-team game needs a generated corner/plus map (or a pinned spec).
  result =
    if config.mapSpec.len > 0:
      mapFromSpecJson(config.mapSpec)
    else:
      let
        name = if config.mapPath.len == 0: DefaultMapPath else: config.mapPath
        genSeed = if config.mapSeed != -1: config.mapSeed else: config.seed
      case name
      of ArenaName: arenaCtfMap()
      of ArenaLargeName: arenaLargeCtfMap()
      of GenMapName: generateCtfMap(genSeed, config.mapGen, config.teams)
      of PoolMapName:
        if config.teams != 2:
          raise newException(
            CtfError, "The curated pool is 2-team; use mapPath gen for " &
              $config.teams & " teams.")
        let index =
          if config.mapPoolIndex >= 0: config.mapPoolIndex else: genSeed
        poolCtfMap(index, config.mapGen)
      else:
        raise newException(CtfError, "Unknown map: " & name)
  if result.teamCount() != config.teams:
    raise newException(
      CtfError, "Config asks for " & $config.teams & " teams but map " &
        result.name & " seats " & $result.teamCount() & ".")

## The SELECTED map's layout, installed once per process by loadCtfMap and
## initialized to the default arena below so tooling that never selects a
## map observes a complete default state, never an empty one.
var
  ArenaMapG = arenaCtfMap()
    ## The selected map backing pure-map wrappers used by the installed arena
    ## renderer. Editor/tool rendering never reads this process global.
  ArenaFlagRing = 70
  ArenaCaptureClear = 210
  ArenaLayoutG = layoutHex2
  ArenaSymmetryG = symMirrorHex
  ArenaTeamCount = 2
  ArenaAnchors: array[Team, MapPoint]
  ArenaPocketHalf: array[Team, tuple[w, h: int]]
  ArenaBoardG* = hexBoard(HexStandardWidth, HexStandardHeight)
    ## THE installed hexagon. Every wall predicate reads its boundary from
    ## here; nothing re-derives one.
  ArenaEndzoneRadius = 0
  ArenaEndzoneDisc = false
  ArenaObstacles*: seq[ArenaShape]
  AnimatedDiamonds*: seq[tuple[cx, cy, radius: int]]
  ArenaSpinMirrored* = true
    ## True when this map's symmetry is a REFLECTION, so mirror-image diamonds
    ## must spin in opposite directions. False on rotationally symmetric maps
    ## (rot180 / rot90), where every diamond turns together — see
    ## diamondSpinFrame.
  ArenaTrenches*: seq[ArenaShape]

proc selectCtfMap(gameMap: CtfMap) =
  ## Installs one map as THE map for this process: dimensions, fog grid,
  ## map-relative ranges, layout clearances, and the mirrored obstacle set.
  ## Runs before any sim, mask, or render work; the render bakes in
  ## global.nim assume the arena never changes afterward.
  ArenaMapG = gameMap
  MapWidth = gameMap.width
  MapHeight = gameMap.height
  FovGridW = (MapWidth + FovCellSize - 1) div FovCellSize
  FovGridH = (MapHeight + FovCellSize - 1) div FovCellSize
  FovCellCount = FovGridW * FovGridH
  GrenadeMaxRange = MapWidth div 5
  ShoutRange = MapWidth div 5
  ArenaFlagRing = gameMap.flagRing
  ArenaCaptureClear = gameMap.captureClear
  ArenaLayoutG = gameMap.layout
  ArenaSymmetryG = gameMap.symmetry
  ArenaTeamCount = gameMap.teamCount()
  for team in gameMap.teams():
    ArenaAnchors[team] = gameMap.teamAnchor(team)
    ArenaPocketHalf[team] = gameMap.spawnPocketHalf(team)
  ArenaBoardG = gameMap.mapBoard()
  ArenaEndzoneRadius = gameMap.endzoneRadius
  ArenaEndzoneDisc = gameMap.endzone == ezDisc
  ArenaObstacles = buildArenaObstacles(gameMap)
  AnimatedDiamonds = buildAnimatedDiamonds(gameMap, ArenaObstacles)
  ArenaSpinMirrored = gameMap.symmetry == symMirrorHex
  ArenaTrenches = gameMap.trenches

proc installDefaultArena*() =
  ## Installs the hand-tuned default arena into the process-wide map globals.
  ## Stage 6 of docs/plans/2026-08-01-sim-split.md replaced the old
  ## import-time `selectCtfMap(arenaCtfMap())` side effect with this explicit
  ## call: constructing any sim (initSimServer -> loadCtfMap) installs its
  ## config's map anyway, so this matters only for code that touches the
  ## installed-map globals BEFORE building a sim (test scaffolding, tools
  ## that query geometry standalone).
  selectCtfMap(arenaCtfMap())

proc loadCtfMapMetadata*(path = ""): CtfMap =
  ## Returns one map's metadata WITHOUT installing it as the process map.
  ## Accepts "arena", "arena-large", "gen[:seed]", and "pool[:index]" (the
  ## suffix-less generated forms use seed/index 0); tooling convenience —
  ## servers resolve through the GameConfig overload instead.
  let name = if path.len == 0: DefaultMapPath else: path
  case name
  of ArenaName: arenaCtfMap()
  of ArenaLargeName: arenaLargeCtfMap()
  else:
    let parts = name.split(':')
    var suffix = 0
    if parts.len == 2:
      try:
        suffix = parseInt(parts[1])
      except ValueError:
        raise newException(CtfError, "Unknown map: " & name)
    if parts.len <= 2 and parts[0] == GenMapName:
      generateCtfMap(suffix)
    elif parts.len <= 2 and parts[0] == PoolMapName:
      poolCtfMap(suffix)
    else:
      raise newException(CtfError, "Unknown map: " & name)

proc loadCtfMapMetadata*(config: GameConfig): CtfMap =
  ## GameConfig-driven metadata: honors mapSpec, mapSeed, pool picks, and
  ## the generator overrides.
  resolveCtfMapMetadata(config)

proc loadCtfMap*(path = ""): CtfMap =
  ## Returns the named map ("arena" is the default; "arena-large" is the
  ## 30%-larger variant; "gen:<seed>"/"pool:<index>" the generated forms)
  ## and installs it as this process's arena.
  result = loadCtfMapMetadata(path)
  selectCtfMap(result)

proc loadCtfMap*(config: GameConfig): CtfMap =
  ## Resolves the config's effective map and installs it as this process's
  ## arena.
  result = resolveCtfMapMetadata(config)
  selectCtfMap(result)

proc trenchIndexAt*(x, y: int): int =
  ## Returns the index of the trench containing map pixel (x, y), or -1 when
  ## the point is in the open field.
  for i, trench in ArenaTrenches:
    if inShape(x, y, trench):
      return i
  -1

proc playerTrench*(sim: SimServer, playerIndex: int): int =
  ## Returns the index of the trench the player's center is standing in,
  ## or -1 in the open field. Occupancy is instantaneous: the slowdowns and
  ## the fly-over shot misses apply exactly while the center is inside.
  trenchIndexAt(
    sim.players[playerIndex].x + CollisionW div 2,
    sim.players[playerIndex].y + CollisionH div 2
  )

proc isAnimatedDiamondPixel*(x, y: int): bool =
  ## Returns true when (x, y) lies inside one of the rotating center diamonds
  ## at rest (frame 0). This is the BAKE-TIME predicate: it tells the art and
  ## the collision bake which pixels to leave empty because the live shape is
  ## stamped per frame instead. For "is this stone right now", ask the wall
  ## mask (or animatedDiamondCovers with the tick's frame).
  for spot in AnimatedDiamonds:
    if abs(x - spot.cx) + abs(y - spot.cy) <= spot.radius:
      return true
  false

proc inShapeF*(x, y: float, shape: ArenaShape): bool =
  ## Float-coordinate inShape: the render-scale rasterizer evaluates the same
  ## geometry at sub-pixel positions for crisp high-resolution wall edges.
  ## Collision and FOV keep using the integer predicate; the two may disagree
  ## by less than one map pixel along shape boundaries, which is invisible.
  case shape.kind
  of shapeDisc:
    let
      dx = x - float(shape.cx)
      dy = y - float(shape.cy)
    dx * dx + dy * dy <= float(shape.radius * shape.radius)
  of shapeBar:
    let
      dx2 = 2.0 * x - float(shape.cx2)
      dy2 = 2.0 * y - float(shape.cy2)
      ux = float(shape.axisX)
      uy = float(shape.axisY)
    abs(dx2 * ux + dy2 * uy) <= float(shape.halfLong) and
      abs(dy2 * ux - dx2 * uy) <= float(shape.halfPerp)
  of shapeHex:
    let
      dx2 = 2.0 * x - float(shape.hexCx2)
      dy2 = 2.0 * y - float(shape.hexCy2)
      (a, b) = if shape.flatTop: (dx2, dy2) else: (dy2, dx2)
      r2 = float(shape.hexR2)
      num = float(Sqrt3Num)
      den = float(Sqrt3Den)
    abs(a * num + b * den) <= r2 * num and
      abs(a * num - b * den) <= r2 * num and
      2.0 * abs(b) * den <= r2 * num
  of shapePolygon:
    ## Float even-odd for the render rasterizer. Render need not be bit-exact
    ## with the integer predicate (they may disagree by <1px on the boundary,
    ## as the doc for this proc notes); the integer `inShape` is what collision,
    ## FOV, and symmetry use.
    if shape.points.len < 3:
      false
    else:
      var
        inside = false
        j = shape.points.len - 1
      for i in 0 ..< shape.points.len:
        let
          xi = float(shape.points[i].x)
          yi = float(shape.points[i].y)
          xj = float(shape.points[j].x)
          yj = float(shape.points[j].y)
        if (yi > y) != (yj > y):
          if x < xi + (xj - xi) * (y - yi) / (yj - yi):
            inside = not inside
        j = i
      inside
  of shapeDiagonal:
    let
      vx = float(shape.x1 - shape.x0)
      vy = float(shape.y1 - shape.y0)
      wx = x - float(shape.x0)
      wy = y - float(shape.y0)
      len2 = vx * vx + vy * vy
      t = clamp(wx * vx + wy * vy, 0.0, len2)
      dx = wx * len2 - t * vx
      dy = wy * len2 - t * vy
    dx * dx + dy * dy <=
      float(shape.thickness * shape.thickness) * len2 * len2 / 4.0

proc isArenaBorderWall*(x, y: int): bool {.inline.} =
  ## THE boundary rule, installed-map form. Identical by construction to
  ## `mapBorderWallAt` — both call the ONE predicate in `hex.nim` — so the
  ## four parallel wall tests can no longer drift apart the way four
  ## hand-written rectangle comparisons could.
  ArenaBoardG.hexEdgeDist(x, y) < float(ArenaBorder)

proc isProtectedFloor*(x, y, cx, cy: int): bool =
  ## Regions that MUST stay walkable: the flag ring and every team's endzone
  ## disc. Walls are never carved here.
  ##
  ## This must stay pixel-for-pixel identical to `mapProtectedFloorAt`, which
  ## the generator and validators run on uninstalled candidates.
  for team in activeTeams(ArenaTeamCount):
    if endzoneFloorAt(x, y, ArenaAnchors[team].x, ArenaAnchors[team].y,
        ArenaEndzoneRadius, ArenaEndzoneDisc):
      return true
  let
    rdx = x - cx
    rdy = y - cy
  rdx * rdx + rdy * rdy <= ArenaFlagRing * ArenaFlagRing

proc isArenaWall*(x, y, cx, cy: int): bool =
  ## Returns true when (x, y) is a wall pixel on the installed arena — which
  ## includes every pixel of the bounding box OUTSIDE the hexagon.
  if isArenaBorderWall(x, y):
    return true
  if isProtectedFloor(x, y, cx, cy):
    return false
  for shape in ArenaObstacles:
    if inShape(x, y, shape):
      return true
  false

proc isArenaWindowPixel*(x, y, cx, cy: int): bool =
  ## Returns true when (x, y) is a GLASS pixel: a wall pixel that belongs to a
  ## window shape. Glass stays in the collision/shot wall mask but is excluded
  ## from the fog-of-war occlusion build, so vision passes through it.
  if not isArenaWall(x, y, cx, cy):
    return false
  for shape in ArenaObstacles:
    if shape.window and inShape(x, y, shape):
      return true
  false

proc mapProtectedFloorAtF*(
  gameMap: CtfMap, x, y: float, cx, cy: int
): bool =
  ## Float-coordinate mapProtectedFloorAt for a map that is NOT installed as
  ## the process map. Render tools use this form so concurrent arbitrary-spec
  ## renders never read or mutate the installed arena globals.
  let grown = float(gameMap.endzoneRadius + EndzoneWallMargin)
  for team in gameMap.teams():
    let
      anchor = gameMap.teamAnchor(team)
      adx = abs(x - float(anchor.x))
      ady = abs(y - float(anchor.y))
    if adx > grown or ady > grown:
      continue
    if gameMap.endzone != ezDisc or adx * adx + ady * ady <= grown * grown:
      return true
  let
    rdx = x - float(cx)
    rdy = y - float(cy)
  rdx * rdx + rdy * rdy <= float(gameMap.flagRing * gameMap.flagRing)

proc mapObstacleWallAtF*(
  gameMap: CtfMap,
  obstacles: openArray[ArenaShape],
  x, y: float,
  cx, cy: int,
): bool =
  ## Float-coordinate interior-obstacle test for an uninstalled map. The
  ## border RING is excluded because renderers draw it as separate slabs — but
  ## the VOID outside the hexagon is not a ring, it is the shape of the board,
  ## so it is wall here exactly as it is in the integer predicates.
  if gameMap.mapBoard().hexEdgeDistF(x, y) <= 0.0:
    return true
  if mapProtectedFloorAtF(gameMap, x, y, cx, cy):
    return false
  for shape in obstacles:
    if inShapeF(x, y, shape):
      return true
  false

proc obstacleWallAtF*(x, y: float, cx, cy: int): bool =
  ## Float-coordinate interior-obstacle test (the border ring excluded);
  ## the high-resolution renderer draws the border as separate slabs.
  mapObstacleWallAtF(ArenaMapG, ArenaObstacles, x, y, cx, cy)

proc mapShapeWallAtF*(
  gameMap: CtfMap,
  x, y: float,
  shape: ArenaShape,
  cx, cy: int,
): bool =
  ## Float-coordinate test for one uninstalled-map shape with the canonical
  ## protected-floor carve — and the hull — applied.
  gameMap.mapBoard().hexEdgeDistF(x, y) > 0.0 and
    inShapeF(x, y, shape) and
    not mapProtectedFloorAtF(gameMap, x, y, cx, cy)

proc shapeWallAtF*(x, y: float, shape: ArenaShape, cx, cy: int): bool =
  ## Float-coordinate test for one shape with the protected-floor carve
  ## applied, matching what the integer wall mask keeps of that shape.
  mapShapeWallAtF(ArenaMapG, x, y, shape, cx, cy)

proc diamondSpinFrame*(
  cx, tick: int, mirrored = ArenaSpinMirrored, width = MapWidth
): int {.inline.} =
  ## The spin frame of the diamond centered at map-x `cx` on one tick. The
  ## frame derives only from the tick, so the renderer, the collision masks,
  ## and every replay viewer read the SAME angle. Single source of truth.
  ##
  ## Direction has to follow the map's symmetry or the live footprint stops
  ## being symmetric even though the resting one is. A REFLECTION maps a
  ## rotation by +theta to one by -theta, so mirror-image diamonds must spin
  ## in OPPOSITE directions — the classic arena's two halves. A ROTATION
  ## commutes with rotation, so rot180 and rot90 image diamonds must spin the
  ## SAME way; giving them opposite directions (which the side-of-the-map rule
  ## does, since both symmetries move a diamond across the axis) makes the two
  ## halves of a rot180 map differ. On rotationally symmetric maps every
  ## diamond therefore turns together.
  ##
  ## `mirrored` / `width` default to the installed map, which is what every
  ## production caller wants; passing them explicitly lets the rule be checked
  ## against a map that is not the process map.
  let dir = if mirrored and 2 * cx >= width - 1: -1 else: 1
  diamondFrameIndex((tick div DiamondSpinTicksPerFrame) * dir)

proc animatedDiamondCovers*(
  spot: tuple[cx, cy, radius: int], frame, x, y: int
): bool {.inline.} =
  ## True when map pixel (x, y) is stone in one spinning diamond at `frame`.
  rotatedDiamondCovers(
    spot.radius, frame, 2 * (x - spot.cx), 2 * (y - spot.cy), 2)
