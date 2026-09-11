# H1 implementation: hole-based sifting in the shared FixedHeap

Peer tree `nav-512-peer`, base `6b6b340860afc72057431f4232f6c91562f6615d`.
Scope per `VERDICT_P1.md`: H1 only. No budget, module, flag, benchmark or
native-host change. The viewer bundle is deliberately not rebuilt here (root
rebuilds the accepted combined source once); until then this tree's
sim-sources stamp is stale by design.

## Mechanism

`src/shell/body_planner.nim`, `FixedHeap` only (`H1/H1.patch`, 373 lines
including tests; production diff is 26 lines). `siftUp` and `siftDown` now
hold the displaced node and move one parent or child per level into the
hole, then store the held node and its position once. `swapNodes` is
removed. Unchanged: `HeapNode` layout, `nodeLess`, binary arity, the
left-child preference on comparator-equal siblings, `pushOrDecrease`,
`pop`, `begin`, `setPosition`, allocation sizes, generation width (64-bit),
capacity errors. Adapted from the held-node pattern in Nim 2.2.6
`lib/pure/collections/heapqueue.nim` `siftup`/`siftdown`, as the proposal
asked; `HeapQueue` itself is not used.

Per level the former code did one three-field swap of two 40-byte nodes
plus two `positions` and two `positionGeneration` writes; the new code does
one node copy plus one `positions` and one `positionGeneration` write, and
one final node and position store per sift that moved. A sift that does
not move performs no stores at all. Both route A* and the field minter use
this heap, so both arms are affected.

## Exactness argument

The final array after a swap chain and after a hole chain are the same
permutation: the swap version moves the held node one step per level and
the hole version defers that store to the end; every neighbour lands in
the same slot in both. Position stamps are written for exactly the nodes
that moved, with the same final values. `pop` still copies the last node to
the root before sifting, so its stores are unchanged apart from the sift.

## Tests added

- `tests/body_heap_reference.nim`: literal copy of the pre-H1 heap
  (swap-based) under `Oracle*` names. Test support, never imported by
  `src/`. Immutable by policy.
- `tests/test_shell_body_heap_exact.nim` (shard 2): `include`s the planner
  to reach the private heap and compares against the oracle after every
  operation on the full active node array, every item's position and
  generation stamp, and the heap generation. Cases: randomized interleaved
  push / strict decrease-key / ignored non-decrease / pop / generation
  reset (16 seeds, capacities 16 and 257, up to 20k operations each, keys
  drawn from only 16 distinct values so duplicates are constant) followed
  by a fill-to-capacity-then-drain phase; empty, fill to capacity, capacity
  error, drain and refill; stale-generation item inserted fresh; distinct
  items with completely equal keys; a popped root descending past two
  comparator-equal children; comparator order under duplicate keys.
- Detection power was proved by a temporary tie-order mutation in
  `siftDown` (`nodeLess(right, left)` -> `not nodeLess(left, right)`): the
  randomized test and the equal-children test both fail, the clean heap
  passes. Note for future tests: unittest `check` inside a helper proc only
  sets the exit code, so the randomized helper returns a description that
  the test body checks.

## Validation record (local arm64, Nim 2.2.6, `-d:release`)

All logs are in `H1/`.

| Suite | Result |
|---|---|
| test_shell_body_heap_exact | 6/6 OK |
| test_shell_body_nav (chunk-independent fingerprints, golden round robin, prewarm laws) | 21/21 OK |
| test_shell_body_seat | 26/26 OK |
| test_shell_body_danger_exact | 2/2 OK |
| test_shell_body_ray | 3/3 OK |
| test_shell_body_map | 15/15 OK |
| `nim check` runtime-stub shape (`env -u WASMTIME_C_API`) | passes |
| `nim check` runtime-linked shape | **not run**: no Wasmtime C API on this machine; root's native build covers it |

Cross-build check (`H1/crossbuild_fingerprints.nim`, outputs
`H1/crossbuild-base-6b6b3408.txt` and `H1/crossbuild-h1.txt`): a 32-seat
BR golden-map drain with an eight-source danger field, all three cost
profiles, avoid points on every fourth seat and route-field mints; every
seat's `jobFingerprint` and `mintFingerprint` folded after each of 1,119
ticks, plus all final paths (29,546 points). Pre-H1 and H1 binaries print
identical digests.

Build note: this shell inherited a stale Nix devshell whose Apple SDK store
path no longer exists; Nim commands were run with those `NIX_*`/`SDKROOT`
variables unset so clang uses the system CommandLineTools SDK. No project
guard was bypassed; coworld-ctf is not a Nix project.

## Limits

- No timing was measured. The mechanism reduces stores per level; whether
  that is visible against the cache-miss terms in PEER_PLAN.md section 2.1
  is exactly what the root's same-budget native diagnostic must decide.
- Exactness is proved at the heap operation level and checked at the
  planner level on one map; the root's unmodified-planner route and
  work-count comparison at the same budget remains the acceptance check.
- Hashes: `H1/sha256.txt` records the patch and the modified planner
  source.

PHASE 2 READY
