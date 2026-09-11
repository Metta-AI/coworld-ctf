## Literal pre-H1 FixedHeap oracle, copied from body_planner.nim at 6b6b3408.
## Swap-based sifting with two position-map writes per level. Keep it
## independent of production so the hole-based sift can be compared
## operation by operation. Test support only; never imported by src/.

type
  OracleHeapNode* = object
    priority*, cost*: float
    tie1*, tie2*: int
    item*: int

  OracleFixedHeap* = object
    nodes*: seq[OracleHeapNode]
    positions*: seq[int]
    positionGeneration*: seq[uint64]
    generation*: uint64
    len*: int

proc newOracleFixedHeap*(capacity: int): OracleFixedHeap =
  result.nodes = newSeq[OracleHeapNode](capacity)
  result.positions = newSeq[int](capacity)
  result.positionGeneration = newSeq[uint64](capacity)

proc oracleNodeLess*(a, b: OracleHeapNode): bool =
  if a.priority != b.priority: a.priority < b.priority
  elif a.cost != b.cost: a.cost < b.cost
  elif a.tie1 != b.tie1: a.tie1 < b.tie1
  else: a.tie2 < b.tie2

proc begin*(heap: var OracleFixedHeap) =
  inc heap.generation
  heap.len = 0

proc setPosition(heap: var OracleFixedHeap, item, position: int) =
  heap.positions[item] = position
  heap.positionGeneration[item] = heap.generation

proc swapNodes(heap: var OracleFixedHeap, a, b: int) =
  swap(heap.nodes[a], heap.nodes[b])
  heap.setPosition(heap.nodes[a].item, a)
  heap.setPosition(heap.nodes[b].item, b)

proc siftUp(heap: var OracleFixedHeap, start: int) =
  var index = start
  while index > 0:
    let parent = (index - 1) div 2
    if not oracleNodeLess(heap.nodes[index], heap.nodes[parent]):
      break
    heap.swapNodes(index, parent)
    index = parent

proc siftDown(heap: var OracleFixedHeap, start: int) =
  var index = start
  while true:
    let left = index * 2 + 1
    if left >= heap.len:
      break
    let right = left + 1
    var child = left
    if right < heap.len and oracleNodeLess(heap.nodes[right], heap.nodes[left]):
      child = right
    if not oracleNodeLess(heap.nodes[child], heap.nodes[index]):
      break
    heap.swapNodes(index, child)
    index = child

proc pushOrDecrease*(heap: var OracleFixedHeap, node: OracleHeapNode) =
  if node.item < 0 or node.item >= heap.positions.len:
    raise newException(ValueError, "oracle heap item is out of range")
  if heap.positionGeneration[node.item] == heap.generation:
    let position = heap.positions[node.item]
    if not oracleNodeLess(node, heap.nodes[position]):
      return
    heap.nodes[position] = node
    heap.siftUp(position)
    return
  if heap.len >= heap.nodes.len:
    raise newException(ValueError, "oracle heap capacity exhausted")
  let position = heap.len
  inc heap.len
  heap.nodes[position] = node
  heap.setPosition(node.item, position)
  heap.siftUp(position)

proc pop*(heap: var OracleFixedHeap): OracleHeapNode =
  if heap.len == 0:
    raise newException(IndexDefect, "pop from empty oracle heap")
  result = heap.nodes[0]
  heap.positionGeneration[result.item] = 0
  dec heap.len
  if heap.len > 0:
    heap.nodes[0] = heap.nodes[heap.len]
    heap.setPosition(heap.nodes[0].item, 0)
    heap.siftDown(0)
