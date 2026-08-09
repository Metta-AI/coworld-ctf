## arch_dbg — one seed, one attempt, where the cover actually went.
import std/[os, strformat, strutils]
import ../src/ctf/[sim, arena, map_metrics]

when isMainModule:
  let
    seed = parseInt(paramStr(1))
    teams = if paramCount() >= 2: parseInt(paramStr(2)) else: 2
  for attempt in 0 ..< 3:
    let m = generateMapAttempt(seed, MapGenOverrides(
      windows: -1, pits: -1, pitDensity: -1), teams, attempt)
    var byKind: array[5, int]
    var areaByKind: array[5, int]
    for s in m.leftObstacles:
      let k = ord(s.kind)
      inc byKind[k]
      let a =
        case s.kind
        of shapeRect: s.rect.w * s.rect.h
        of shapeDisc: (314 * s.radius * s.radius) div 100
        of shapeDiamond: 2 * s.radius * s.radius
        of shapeDiagonal: s.thickness * (abs(s.x1 - s.x0) + abs(s.y1 - s.y0))
        of shapePolygon:
          var acc = 0
          for i in 0 ..< s.points.len:
            let a = s.points[i]
            let b = s.points[(i + 1) mod s.points.len]
            acc += a.x * b.y - b.x * a.y
          abs(acc) div 2
      areaByKind[k] += a
    let ev = evaluateMap(m, "raw")
    echo &"seed {seed} a{attempt} arch={mapArchetypeFor(seed, teams)} " &
      &"{m.width}x{m.height} ez={m.endzone} sym={m.symmetry} " &
      &"cover={ev.coverPermille}pm int={ev.interiorFrac:.3f} " &
      &"why='{validateGeneratedMap(m)}'"
    for k, name in ["rect", "disc", "diamond", "diagonal", "polygon"]:
      if byKind[k] > 0:
        echo &"    {name:<9} n={byKind[k]:<4} area={areaByKind[k]} " &
          &"({areaByKind[k] * 1000 div (m.width * m.height)}pm of board)"
