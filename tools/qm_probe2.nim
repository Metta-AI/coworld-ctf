import ../src/ctf/sim

when isMainModule:
  let m = mapFromSpecJson(readFile("/tmp/qm_s.json"))
  for i, s in m.leftObstacles:
    case s.kind
    of shapeRect: echo i, " rect ", s.rect
    of shapeDiamond: echo i, " diamond ", s.cx, ",", s.cy, " r", s.radius
    of shapeDisc: echo i, " disc ", s.cx, ",", s.cy, " r", s.radius
    of shapeDiagonal: echo i, " diag ", s.x0, ",", s.y0, "->", s.x1, ",", s.y1
    of shapePolygon: echo i, " poly n=", s.points.len
