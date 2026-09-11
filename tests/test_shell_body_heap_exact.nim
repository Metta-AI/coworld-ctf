## H1 differential test: the production FixedHeap must match the swap-based
## oracle after every operation, in the full active node array, every
## position and every position generation. `include` reaches the private
## heap without exporting test-only symbols from the planner.
import std/[random, unittest]
import body_heap_reference
include ../src/shell/body_planner

proc toOracle(node: HeapNode): OracleHeapNode =
  OracleHeapNode(priority: node.priority, cost: node.cost,
    tie1: node.tie1, tie2: node.tie2, item: node.item)

proc sameLayout(actual: FixedHeap, oracle: OracleFixedHeap): bool =
  ## Active nodes, every item's position and generation stamp, and the
  ## heap generation itself. Slots at or beyond len are not part of the
  ## contract and are not compared.
  if actual.len != oracle.len or actual.generation != oracle.generation:
    return false
  for index in 0 ..< actual.len:
    if actual.nodes[index].toOracle != oracle.nodes[index]:
      return false
  for item in 0 ..< actual.positions.len:
    if actual.positionGeneration[item] != oracle.positionGeneration[item]:
      return false
    if actual.positionGeneration[item] == actual.generation and
        actual.positions[item] != oracle.positions[item]:
      return false
  true

proc makeHeaps(capacity: int): (FixedHeap, OracleFixedHeap) =
  var actual: FixedHeap
  actual.nodes = newSeq[HeapNode](capacity)
  actual.positions = newSeq[int](capacity)
  actual.positionGeneration = newSeq[uint64](capacity)
  (actual, newOracleFixedHeap(capacity))

proc randomNode(rng: var Rand, capacity: int): HeapNode =
  ## Sixteen distinct keys in total, so duplicate keys, full tie-breaking
  ## chains and the child choice between comparator-equal siblings all
  ## occur constantly.
  HeapNode(priority: rng.rand(0 .. 1).float * 0.5,
    cost: rng.rand(0 .. 1).float,
    tie1: rng.rand(0 .. 1), tie2: rng.rand(0 .. 1),
    item: rng.rand(0 ..< capacity))

proc runRandomized(seed, capacity, operations: int): string =
  ## Returns an empty string on success, otherwise the first divergence.
  ## unittest's `check` inside a helper proc only sets the process exit
  ## code, so the caller must `check` the returned description itself.
  var rng = initRand(seed)
  var (actual, oracle) = makeHeaps(capacity)
  actual.begin()
  oracle.begin()
  var pops = 0
  var decreases = 0
  var ignored = 0
  template diverged(what: string) =
    return "seed " & $seed & " op " & $step & ": " & what
  for step in 0 ..< operations:
    let roll = rng.rand(99)
    if roll < 3:
      # Generation reset: every stamped position becomes stale at once.
      actual.begin()
      oracle.begin()
    elif roll < 45 and actual.len > 0:
      if actual.pop().toOracle != oracle.pop():
        diverged("popped node differs")
      inc pops
    else:
      var node = rng.randomNode(capacity)
      if actual.positionGeneration[node.item] == actual.generation:
        # Present item: half the time force a strict decrease so the
        # decrease-key sift path runs, otherwise let the key be ignored or
        # decreased at random.
        let current = actual.nodes[actual.positions[node.item]]
        if rng.rand(1) == 0:
          node.priority = current.priority - 0.25
        if nodeLess(node, current): inc decreases else: inc ignored
      actual.pushOrDecrease(node)
      oracle.pushOrDecrease(node.toOracle)
    if not sameLayout(actual, oracle):
      diverged("layout differs after interleaved operation")
  # Fill-then-drain phase: deep sift-downs through a heap full of duplicate
  # keys, which the interleaved stream above rarely grows large enough for.
  actual.begin()
  oracle.begin()
  for item in 0 ..< capacity:
    let step = operations + item
    var node = rng.randomNode(capacity)
    node.item = item
    actual.pushOrDecrease(node)
    oracle.pushOrDecrease(node.toOracle)
    if not sameLayout(actual, oracle):
      diverged("layout differs during fill")
  while actual.len > 0:
    let step = operations + capacity + pops
    if actual.pop().toOracle != oracle.pop():
      diverged("popped node differs during drain")
    if not sameLayout(actual, oracle):
      diverged("layout differs during drain")
    inc pops
  if pops == 0 or decreases == 0 or ignored == 0:
    return "seed " & $seed & ": stream did not exercise pop, decrease and ignore"
  ""

suite "fixed heap exactness":
  test "randomized push, decrease-key, ignored key, pop and reset match the oracle":
    for seed in 1 .. 12:
      check runRandomized(seed, capacity = 16, operations = 4000) == ""
    for seed in 13 .. 16:
      check runRandomized(seed, capacity = 257, operations = 20000) == ""

  test "empty, fill to capacity, drain, and refill keep identical layouts":
    var (actual, oracle) = makeHeaps(64)
    for round in 0 ..< 3:
      actual.begin()
      oracle.begin()
      check actual.len == 0
      for item in 0 ..< 64:
        # Descending priorities push every insert to the root.
        let node = HeapNode(priority: (64 - item).float, cost: 1.0,
          tie1: item mod 3, tie2: 0, item: item)
        actual.pushOrDecrease(node)
        oracle.pushOrDecrease(node.toOracle)
        check sameLayout(actual, oracle)
      # This checks the item range. With equally sized arrays and distinct
      # active items, the separate capacity guard is unreachable by construction.
      expect BodyMapError:
        actual.pushOrDecrease(HeapNode(item: 64))
      var previous = actual.pop()
      discard oracle.pop()
      while actual.len > 0:
        let current = actual.pop()
        discard oracle.pop()
        check not nodeLess(current, previous)
        check sameLayout(actual, oracle)
        previous = current
      check actual.len == 0 and oracle.len == 0

  test "an item from a previous generation is inserted fresh, not decreased":
    var (actual, oracle) = makeHeaps(8)
    actual.begin()
    oracle.begin()
    let node = HeapNode(priority: 1.0, cost: 1.0, item: 3)
    actual.pushOrDecrease(node)
    oracle.pushOrDecrease(node.toOracle)
    actual.begin()
    oracle.begin()
    let worse = HeapNode(priority: 9.0, cost: 9.0, item: 3)
    actual.pushOrDecrease(worse)
    oracle.pushOrDecrease(worse.toOracle)
    check actual.len == 1
    check actual.nodes[0].priority == 9.0
    check sameLayout(actual, oracle)

  test "completely equal keys on distinct items keep the oracle's layout":
    var (actual, oracle) = makeHeaps(48)
    actual.begin()
    oracle.begin()
    for item in 0 ..< 48:
      let node = HeapNode(priority: 1.0, cost: 1.0, tie1: 0, tie2: 0, item: item)
      actual.pushOrDecrease(node)
      oracle.pushOrDecrease(node.toOracle)
      check sameLayout(actual, oracle)
    while actual.len > 0:
      check actual.pop().toOracle == oracle.pop()
      check sameLayout(actual, oracle)

  test "a popped root descends past two comparator-equal children like the oracle":
    var (actual, oracle) = makeHeaps(8)
    actual.begin()
    oracle.begin()
    for node in [HeapNode(priority: 1.0, item: 0), HeapNode(priority: 2.0, item: 1),
                 HeapNode(priority: 2.0, item: 2), HeapNode(priority: 3.0, item: 3)]:
      actual.pushOrDecrease(node)
      oracle.pushOrDecrease(node.toOracle)
    check actual.pop().item == 0
    check oracle.pop().item == 0
    # The oracle chooses the left child on equal keys: [1, 3, 2].
    check actual.nodes[0].item == 1
    check actual.nodes[1].item == 3
    check actual.nodes[2].item == 2
    check sameLayout(actual, oracle)

  test "duplicate keys pop in item-insertion-independent comparator order":
    var (actual, oracle) = makeHeaps(32)
    actual.begin()
    oracle.begin()
    for item in countdown(31, 0):
      let node = HeapNode(priority: 2.0, cost: 2.0, tie1: item div 4,
        tie2: item mod 4, item: item)
      actual.pushOrDecrease(node)
      oracle.pushOrDecrease(node.toOracle)
    var previous = actual.pop()
    discard oracle.pop()
    check previous.tie1 == 0 and previous.tie2 == 0
    while actual.len > 0:
      let current = actual.pop()
      check current.toOracle == oracle.pop()
      check nodeLess(previous, current)
      check sameLayout(actual, oracle)
      previous = current
