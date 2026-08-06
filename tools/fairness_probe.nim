## Measures the protected-floor fairness residue: pixels whose SYMMETRY IMAGE
## disagrees with them under the map's own symmetry. Every pixel, no stride,
## every drawable size class, both team counts.
import std/[strformat, strutils]
import ../src/ctf/[sim, map_rules]

proc asym(m: CtfMap): int =
  let
    w = m.width
    h = m.height
  for y in 0 ..< h:
    for x in 0 ..< w:
      let (ix, iy) =
        case m.symmetry
        of symMirror: (w - 1 - x, y)
        of symRot180: (w - 1 - x, h - 1 - y)
        of symRot90: (w - 1 - y, x)
      if mapProtectedFloorAt(m, x, y) != mapProtectedFloorAt(m, ix, iy):
        inc result

echo "class    teams sym     board        anchors                    asym-px"
for sizeName in DrawableSizeNames:
  for teams in [2, 4]:
    let syms = if teams == 4: @["rot90"] else: @["mirror", "rot180"]
    for s in syms:
      let m = generateMapAttempt(5, MapGenOverrides(
        size: sizeName, symmetry: s, windows: 0, pits: 0, pitDensity: -1),
        teams)
      var anchors: seq[string]
      for t in m.teams():
        let a = m.teamAnchor(t)
        anchors.add &"({a.x},{a.y})"
      let bad = asym(m)
      echo &"{sizeName:<8} {teams:<5} {s:<7} {m.width}x{m.height:<6} " &
        &"{anchors.join(\" \"):<26} {bad}"
