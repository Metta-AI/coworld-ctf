## scan_probe — what does the arena validator's sightline scan actually see?
##
## The hard validator rejects a map with an "open horizontal sightline". This
## re-runs that exact scan next to an EXHAUSTIVE one, so the difference between
## what the rule says and what the rule checks is a printed number rather than
## an assumption.

import
  std/[os, strformat, strutils],
  ../src/ctf/[arena, map_pool, sim_types]

proc report(label: string, gameMap: CtfMap) =
  let
    w = gameMap.width
    h = gameMap.height
    ax = gameMap.sightlineLoX
    bx = gameMap.sightlineHiX
    diag = mapDiagnostics(gameMap, {diagnosticWallMasks})
    minWall = diag.minWall
  proc rowClear(y: int): bool =
    for x in ax .. bx:
      if minWall[y * w + x]: return false
    true
  var
    sampled, exhaustive: seq[int]
    y = ArenaBorder + 2
  while y < h - ArenaBorder:
    if rowClear(y): sampled.add y
    y += 4
  for yy in ArenaBorder ..< h - ArenaBorder:
    if rowClear(yy): exhaustive.add yy
  # The longest unbroken open run on ANY row, anywhere, and the longest column.
  var bestRow, bestRowY, bestCol, bestColX = 0
  for yy in 0 ..< h:
    var run = 0
    for x in 0 ..< w:
      if minWall[yy * w + x]: run = 0
      else:
        inc run
        if run > bestRow: (bestRow, bestRowY) = (run, yy)
  for x in 0 ..< w:
    var run = 0
    for yy in 0 ..< h:
      if minWall[yy * w + x]: run = 0
      else:
        inc run
        if run > bestCol: (bestCol, bestColX) = (run, x)
  echo &"{label:<16} {w}x{h}  band x {ax}..{bx} ({bx - ax}px wide)"
  echo &"    validator 4px stride : {sampled.len} open row(s)  " &
    (if sampled.len > 0: "-> REJECT" else: "-> pass")
  echo &"    exhaustive 1px       : {exhaustive.len} open row(s)  " &
    (if exhaustive.len > 0: "-> would REJECT" else: "-> pass")
  if exhaustive.len > sampled.len:
    echo &"    !! {exhaustive.len - sampled.len} open row(s) THE SCAN NEVER " &
      &"LOOKS AT: y = " & (block:
        var missed: seq[string]
        for yy in exhaustive:
          if yy notin sampled: missed.add $yy
        missed[0 ..< min(14, missed.len)].join(",") &
          (if missed.len > 14: ",..." else: ""))
  echo &"    longest open ROW     : {bestRow}px at y={bestRowY} " &
    &"""(gun range {GunRange}px: {(if bestRow > GunRange: "EXCEEDED" else: "ok")})"""
  echo &"    longest open COLUMN  : {bestCol}px at x={bestColX} " &
    "(the scan never looks at columns at all)"
  # The diagonals, WITH their endpoints — a long run that hugs the border
  # gutter is a rasterization fact, not a firing lane, and the only way to tell
  # them apart is to print where the thing actually is.
  proc scanDiag(sx, sy, dy: int): tuple[px, x0, y0, x1, y1: int] =
    var
      x = sx
      y = sy
      run = 0
      rx, ry = 0
    while x >= 0 and x < w and y >= 0 and y < h:
      if minWall[y * w + x]:
        run = 0
        rx = x + 1; ry = y + dy
      else:
        if run == 0: (rx, ry) = (x, y)
        inc run
        let px = int(float(run) * 1.41421356)
        if px > result.px: result = (px, rx, ry, x, y)
      x += 1
      y += dy
  var best: tuple[px, x0, y0, x1, y1: int]
  for y0 in 0 ..< h:
    for d in [1, -1]:
      let r = scanDiag(0, y0, d)
      if r.px > best.px: best = r
  for x0 in 1 ..< w:
    let a = scanDiag(x0, 0, 1)
    if a.px > best.px: best = a
    let b = scanDiag(x0, h - 1, -1)
    if b.px > best.px: best = b
  let
    inset = min(min(best.x0, best.y0), min(w - 1 - best.x1, h - 1 - best.y1))
    edgeHug = min(min(best.y0, h - 1 - best.y0), min(best.y1, h - 1 - best.y1))
  echo &"    longest open DIAGONAL: {best.px}px from ({best.x0},{best.y0}) to " &
    &"({best.x1},{best.y1})  " &
    &"""(gun range: {(if best.px > GunRange: "EXCEEDED" else: "ok")})"""
  echo &"      -> closest either endpoint comes to a board edge: {edgeHug}px " &
    &"""(border ring is {ArenaBorder}px; {(if edgeHug < ArenaBorder + PlayerHalf: "BORDER GUTTER" else: "inside the playfield")}), corner inset {inset}px"""

when isMainModule:
  let overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
  report("CTL arena", loadCtfMapMetadata("arena"))
  report("CTL arena-large", loadCtfMapMetadata("arena-large"))
  for a in commandLineParams():
    let seed = a.parseInt
    report(&"gen:{seed}", generateCtfMap(seed, overrides, 2))
