## Measurement-only exact squared Euclidean distance transform used by P0.
## Production code must not import this module; P1 promotes a reviewed version.

import std/[math, options]

type
  PixelPoint* = tuple[x, y: int]

  EdtTable* = object
    width*, height*: int
    component*: uint16
    distances*: seq[uint32]
    sites*: seq[bool]

const
  EdtInfinity = uint32.high div 4

proc transform1d(source: openArray[uint32], output: var openArray[uint32]) =
  let n = source.len
  if n == 0:
    return
  var sites = newSeq[int](n)
  var boundaries = newSeq[float64](n + 1)
  var k = 0
  sites[0] = 0
  boundaries[0] = -Inf
  boundaries[1] = Inf
  for q in 1 ..< n:
    var split: float64
    while true:
      let p = sites[k]
      split = (source[q].float64 + float64(q * q) -
        source[p].float64 - float64(p * p)) / float64(2 * (q - p))
      if split > boundaries[k] or k == 0:
        break
      dec k
    inc k
    sites[k] = q
    boundaries[k] = split
    boundaries[k + 1] = Inf
  k = 0
  for q in 0 ..< n:
    while boundaries[k + 1] < q.float64:
      inc k
    let delta = q - sites[k]
    let value = uint64(delta * delta) + uint64(source[sites[k]])
    output[q] = uint32(min(value, uint64(EdtInfinity)))

proc buildEdt*(components: openArray[uint16], width, height: int,
               component: uint16): EdtTable =
  if width <= 0 or height <= 0 or components.len != width * height:
    raise newException(ValueError, "EDT dimensions do not match component raster")
  if component == 0:
    raise newException(ValueError, "EDT component 0 is not standable")
  result = EdtTable(width: width, height: height, component: component,
    distances: newSeq[uint32](components.len), sites: newSeq[bool](components.len))
  var rowInput = newSeq[uint32](width)
  var rowOutput = newSeq[uint32](width)
  var intermediate = newSeq[uint32](components.len)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let index = y * width + x
      result.sites[index] = components[index] == component
      rowInput[x] = if result.sites[index]: 0'u32 else: EdtInfinity
    transform1d(rowInput, rowOutput)
    for x in 0 ..< width:
      intermediate[y * width + x] = rowOutput[x]
  var columnInput = newSeq[uint32](height)
  var columnOutput = newSeq[uint32](height)
  for x in 0 ..< width:
    for y in 0 ..< height:
      columnInput[y] = intermediate[y * width + x]
    transform1d(columnInput, columnOutput)
    for y in 0 ..< height:
      result.distances[y * width + x] = columnOutput[y]

proc resolveNearest*(table: EdtTable, point: PixelPoint,
                     maxRadiusPx: int): Option[PixelPoint] =
  ## EDT supplies the minimum distance. A bounded row-major scan resolves the
  ## required equal-distance tie without stencil's expanding-ring search.
  if maxRadiusPx < 0 or point.x < 0 or point.x >= table.width or
      point.y < 0 or point.y >= table.height:
    return none(PixelPoint)
  let distance = table.distances[point.y * table.width + point.x]
  if distance > uint32(maxRadiusPx * maxRadiusPx):
    return none(PixelPoint)
  let radius = int(ceil(sqrt(distance.float64)))
  for y in max(0, point.y - radius) .. min(table.height - 1, point.y + radius):
    for x in max(0, point.x - radius) .. min(table.width - 1, point.x + radius):
      let dx = x - point.x
      let dy = y - point.y
      if table.sites[y * table.width + x] and
          uint32(dx * dx + dy * dy) == distance:
        return some((x, y))
  none(PixelPoint)

proc ringNearest*(components: openArray[uint16], width, height: int,
                  component: uint16, point: PixelPoint,
                  maxRadiusPx: int): Option[PixelPoint] =
  ## Direct oracle matching stencil's squared-distance, then row-major rule.
  if component == 0 or maxRadiusPx < 0:
    return none(PixelPoint)
  var best = none(PixelPoint)
  var bestDistance = int64.high
  var bestIndex = int.high
  let radiusSquared = int64(maxRadiusPx) * int64(maxRadiusPx)
  for ring in 0 .. maxRadiusPx:
    if best.isSome and int64(ring) * int64(ring) > bestDistance:
      break
    for y in max(0, point.y - ring) .. min(height - 1, point.y + ring):
      for x in max(0, point.x - ring) .. min(width - 1, point.x + ring):
        if max(abs(x - point.x), abs(y - point.y)) != ring:
          continue
        let
          dx = int64(x - point.x)
          dy = int64(y - point.y)
          candidateDistance = dx * dx + dy * dy
          candidateIndex = y * width + x
        if candidateDistance > radiusSquared or
            candidateDistance > bestDistance or
            components[candidateIndex] != component:
          continue
        if candidateDistance < bestDistance or candidateIndex < bestIndex:
          best = some((x, y))
          bestDistance = candidateDistance
          bestIndex = candidateIndex
  best

proc parityCheck*(components: openArray[uint16], width, height: int,
                  component: uint16, queries: openArray[PixelPoint],
                  maxRadiusPx: int): tuple[checked, failures: int] =
  let table = buildEdt(components, width, height, component)
  for query in queries:
    inc result.checked
    if table.resolveNearest(query, maxRadiusPx) !=
        ringNearest(components, width, height, component, query, maxRadiusPx):
      inc result.failures

