import std/[deques, json, strformat]
import ctf/[arena, br_map_pool]
import shell/[body_map, body_route_index]

let entry = loadBrS2PoolRaw()[0]
var gameMap = mapFromSpecJson($entry["spec"])
gameMap.name = entry["name"].getStr()
let map = newBodyMap(gameMap)
let index = newBodyRouteIndex(map)
let point: BodyPoint = (753, 1091)
let cell = map.cellOf(point)
let cellIndex = cell.y * map.gridWidth + cell.x
echo &"point={point} cell={cell} cell_center={cellCenter(cell)} " &
  &"cell_walkable={map.cellWalkable(cell)} graph={index.graphComponentForCell(cellIndex)} " &
  &"pixel_component={map.componentOf(point)}"
for y in cell.y - 4 .. cell.y + 4:
  for x in cell.x - 4 .. cell.x + 4:
    let candidate = (x: x, y: y)
    if x < 0 or y < 0 or x >= map.gridWidth or y >= map.gridHeight:
      continue
    let candidateIndex = y * map.gridWidth + x
    let anchor = cellCenter(candidate)
    let dx = anchor.x - point.x
    let dy = anchor.y - point.y
    if index.graphComponentForCell(candidateIndex) != 0 and
        map.componentOf(anchor) == map.componentOf(point):
      echo &"anchor={candidate} center={anchor} graph={index.graphComponentForCell(candidateIndex)} " &
        &"d2={dx*dx+dy*dy} clear={map.segmentClear(point, anchor)}"

let
  x0 = cellCenter((max(0, cell.x - 4), cell.y)).x
  x1 = cellCenter((min(map.gridWidth - 1, cell.x + 4), cell.y)).x
  y0 = cellCenter((cell.x, max(0, cell.y - 4))).y
  y1 = cellCenter((cell.x, min(map.gridHeight - 1, cell.y + 4))).y
  fineW = (x1 - x0) div 4 + 1
  fineH = (y1 - y0) div 4 + 1
template local(p: BodyPoint): int = ((p.y-y0) div 4)*fineW+(p.x-x0) div 4
var
  isGoal = newSeq[bool](fineW*fineH)
  seen = newSeq[bool](fineW*fineH)
  queue = initDeque[BodyPoint]()
  best: BodyPoint
  bestD = high(int)
  goals = 0
for y in cell.y - 4 .. cell.y + 4:
  for x in cell.x - 4 .. cell.x + 4:
    if x < 0 or y < 0 or x >= map.gridWidth or y >= map.gridHeight: continue
    let c=(x:x,y:y); let anchor=cellCenter(c); let ci=y*map.gridWidth+x
    let dx=anchor.x-point.x; let dy=anchor.y-point.y
    if index.graphComponentForCell(ci) != 0 and dx*dx+dy*dy <= 1024 and
        map.componentOf(anchor)==map.componentOf(point):
      isGoal[local(anchor)] = true; inc goals
for y in countup(y0,y1,4):
  for x in countup(x0,x1,4):
    let p=(x:x,y:y); let dx=x-point.x; let dy=y-point.y; let d=dx*dx+dy*dy
    if d < bestD and d <= 1024 and map.canStand(p) and map.segmentClear(point,p):
      best=p; bestD=d
seen[local(best)] = true; queue.addLast(best)
var visited=0; var found=false; var reached: BodyPoint
while queue.len>0:
  let cur=queue.popFirst(); inc visited
  if isGoal[local(cur)]: found=true; reached=cur; break
  for d in NavNeighbors:
    let nxt=(x:cur.x+d.x*4,y:cur.y+d.y*4)
    if nxt.x<x0 or nxt.x>x1 or nxt.y<y0 or nxt.y>y1 or seen[local(nxt)] or
        not map.canStand(nxt) or not map.segmentClear(cur,nxt): continue
    seen[local(nxt)] = true; queue.addLast(nxt)
echo &"box={x0}..{x1},{y0}..{y1} goals={goals} seed={best} seed_d2={bestD} found={found} reached={reached} visited={visited}"
