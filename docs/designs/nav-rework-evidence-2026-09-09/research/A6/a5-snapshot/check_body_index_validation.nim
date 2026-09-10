## A4 diagnostic: compare coarse-edge acceptance with the original validator.
include ../src/shell/body_route_index
import std/json

proc referenceEdges(index: BodyRouteIndex): bool =
  for cellIndex in 0 ..< index.stats.navCells:
    let cell = index.cellPoint(cellIndex)
    for direction, delta in NavNeighbors:
      if (index.legalMoves[cellIndex] and uint8(1 shl direction)) == 0:
        continue
      let next: BodyPoint = (cell.x + delta.x, cell.y + delta.y)
      if not index.map.legalNavMove(cell, next): return false
      let reverse = reverseNeighbor(direction)
      if (index.legalMoves[index.cellIndex(next)] and uint8(1 shl reverse)) == 0:
        return false
  true

proc accepted(index: BodyRouteIndex): bool =
  try:
    index.validateRouteIndex()
    true
  except BodyMapError:
    false

const Side = 96
var walkable = newSeq[bool](Side * Side)
for y in 1 ..< Side - 1:
  for x in 1 ..< Side - 1:
    walkable[y * Side + x] = not (x in 40 .. 48 and y in 24 .. 64)
let map = newBodyMap(walkable, Side, Side, 2, @[(16, 16), (80, 80)])
let index = newBodyRouteIndex(map)
var directedMutations, pairedMutations, rejected, acceptedCount: int
for cellIndex in 0 ..< index.stats.navCells:
  let cell = index.cellPoint(cellIndex)
  for direction, delta in NavNeighbors:
    let original = index.legalMoves[cellIndex]
    index.legalMoves[cellIndex] = original xor uint8(1 shl direction)
    let expected = index.referenceEdges()
    doAssert index.accepted() == expected,
      "directed mutation at " & $cell & " direction " & $direction
    inc directedMutations
    if expected: inc acceptedCount
    else: inc rejected
    index.legalMoves[cellIndex] = original
    let next: BodyPoint = (cell.x + delta.x, cell.y + delta.y)
    if next.x < 0 or next.x >= map.gridWidth or
        next.y < 0 or next.y >= map.gridHeight:
      continue
    let nextIndex = index.cellIndex(next)
    let originalNext = index.legalMoves[nextIndex]
    let reverse = reverseNeighbor(direction)
    index.legalMoves[cellIndex] = original or uint8(1 shl direction)
    index.legalMoves[nextIndex] = originalNext or uint8(1 shl reverse)
    let expectedPair = index.referenceEdges()
    doAssert index.accepted() == expectedPair,
      "paired mutation at " & $cell & " direction " & $direction
    inc pairedMutations
    if expectedPair: inc acceptedCount
    else: inc rejected
    index.legalMoves[cellIndex] = original
    index.legalMoves[nextIndex] = originalNext
index.validateRouteIndex()
echo %*{"directed_mutations": directedMutations,
  "paired_mutations": pairedMutations, "accepted": acceptedCount,
  "rejected": rejected, "all_match_reference": true}
