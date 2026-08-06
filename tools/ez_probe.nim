## Audits the policy's HOME-TARGET geometry against the map generator.
##
## For a range of generator seeds and a team count (2 or 4) it prints, per
## team: the REAL capture zone the generator produced, the shape token the
## engine states on the wire (`endzone <color> <shape> x0,y0 x1,y1`, see
## global.nim addMapMarkers), and the point the POLICY steers a carrier to —
## `captureAim`/`homeDeepX` replicated verbatim from
## players/baseline/baseline.nim. If that point is OUTSIDE the real zone, a
## steal on that map can never be converted however well it is escorted; if it
## sits ON the threshold, the carrier scores only by luck.
##
##   nim c -d:release tools/ez_probe.nim
##   ./tools/ez_probe 301 340        # 2-team (the original 2026-08-03 audit)
##   ./tools/ez_probe 301 340 4      # 4-team corner/plus boards
import std/[os, strutils, math], ../src/ctf/[sim, labels]

type PolicyZone = object
  have, compact: bool
  cx, cy, x0, y0, x1, y1: float

proc shapeToken(m: CtfMap, z: CaptureZone): string =
  ## global.nim endzoneShapeToken, verbatim.
  if z.disc: LabelEndzoneShapeDisc
  elif z.diag: LabelEndzoneShapeCorner
  elif m.layout == layoutPlus: LabelEndzoneShapeArm
  elif m.endzone == ezSquare: LabelEndzoneShapeSquare
  else: LabelEndzoneShapeColumn

proc policyZone(m: CtfMap, team: Team): PolicyZone =
  ## baseline.nim statedZone(), fed the marker the engine really emits.
  let
    z = m.captureZone(team)
    tok = m.shapeToken(z)
  PolicyZone(
    have: true,
    compact: tok != LabelEndzoneShapeColumn,
    cx: float(z.xLo + z.xHi) * 0.5, cy: float(z.yLo + z.yHi) * 0.5,
    x0: float(z.xLo), y0: float(z.yLo), x1: float(z.xHi), y1: float(z.yHi))

proc homeDeepX(m: CtfMap, team: Team, parity: Team): float =
  ## baseline.nim homeDeepX(). `parity` is the two-valued Team the policy
  ## still carries for a green/yellow seat (slot parity; the colour lock only
  ## overwrites bot.team for "red"/"blue").
  let
    z = m.policyZone(team)
    tuned = (if parity == Red: 150.0 else: float(m.width - 1) - 150.0)
  if z.have and z.compact: return z.cx
  if z.have and (tuned < z.x0 or tuned > z.x1): return z.cx
  tuned

proc captureAim(m: CtfMap, team: Team, parity: Team, laneY: float):
    tuple[x, y: float] =
  ## baseline.nim captureAim().
  let z = m.policyZone(team)
  if z.have and z.compact: return (z.cx, z.cy)
  (m.homeDeepX(team, parity), laneY)

proc zoneMargin(z: CaptureZone, x, y: int): int =
  ## px of slack between a point and the nearest scoring threshold. Negative
  ## = outside.
  if z.diag:
    return z.diagLimit - (abs(x - z.cornerX) + abs(y - z.cornerY))
  if z.disc:
    return z.radius - int(sqrt(float((x - z.anchorX) * (x - z.anchorX) +
                                     (y - z.anchorY) * (y - z.anchorY))))
  min(min(x - z.xLo, z.xHi - x), min(y - z.yLo, z.yHi - y))

when isMainModule:
  let
    lo = if paramCount() >= 1: parseInt(paramStr(1)) else: 301
    hi = if paramCount() >= 2: parseInt(paramStr(2)) else: 308
    teams = if paramCount() >= 3: parseInt(paramStr(3)) else: 2
  var inside, outside, onEdge: int
  for seed in lo .. hi:
    let m = generateMapAttempt(
      seed, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), teams)
    echo "seed ", seed, "  ", m.width, "x", m.height,
      "  layout=", $m.layout, " endzone=", $m.endzone,
      " r=", m.endzoneRadius
    for team in m.teams():
      let
        z = m.captureZone(team)
        tok = m.shapeToken(z)
        a = m.teamAnchor(team)
      # The policy's lane choice is an ARENA constant band; mid-height is the
      # most charitable reading of the column fallback.
      for parity in [Red, Blue]:
        let
          aim = m.captureAim(team, parity, float(m.height) * 0.5)
          ok = z.inCaptureZone(int(aim.x), int(aim.y))
          margin = z.zoneMargin(int(aim.x), int(aim.y))
        if parity == Red:
          if ok:
            if margin <= 2: inc onEdge else: inc inside
          else: inc outside
        echo "  ", align($team, 6), " tok=", align(tok, 6),
          " anchor=", a.x, ",", a.y,
          " zone x[", z.xLo, "..", z.xHi, "] y[", z.yLo, "..", z.yHi, "]",
          (if z.diag: " diag(" & $z.cornerX & "," & $z.cornerY & " L1<=" &
             $z.diagLimit & ")"
           elif z.disc: " disc(r=" & $z.radius & ")" else: ""),
          "  parity=", align($parity, 4),
          " AIM=", int(aim.x), ",", int(aim.y),
          " -> ", (if not ok: "*** OUTSIDE *** (" & $margin & ")"
                   elif margin <= 2: "!! ON THE EDGE (margin " & $margin & ")"
                   else: "inside (margin " & $margin & ")")
  echo "\ninside=", inside, "  on-edge=", onEdge, "  outside=", outside
