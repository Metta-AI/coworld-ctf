# Direct primary-lattice record lookup without new arrays

Design review only; no production, test or commit change. Inputs: the
current `SearchStore` and its callers in `src/shell/body_planner.nim`
(`:44-56`, `:226-260`, constructor `:262-281`, `initAstarSearch` `:573`,
`beginSearchAtStep`/`startFallback` `:588-601`, `advanceAstar` `:618-637`,
`advanceReconstruct` `:679`, `jobFingerprint` `:826-837`).

## 1. Facts about the existing store

- Three parallel arrays `hashKeys`, `hashRecords` (int) and
  `hashGeneration` (uint64) of `hashCapacity = nextPowerOfTwo(max(8,
  2 * capacity))`, with `capacity = max(gridCells, primaryLatticeW *
  primaryLatticeH)` (`:266-271`). So `hashCapacity >= 2 * primary lattice
  size > every primary key`. On the practice map: 344,487 keys,
  1,048,576 slots; on the scale-2.9 map: 428,288 keys, 1,048,576 slots.
- `hashSlot` is `(key * 0x9E3779B97F4A7C15) and (hashCapacity - 1)`,
  then linear probing while the slot holds a different live key
  (`:231-236`). Multiplication by an odd constant is a bijection on
  integers modulo `2^k`, and `hashCapacity` is `2^k`, so any key set of
  size at most `hashCapacity` maps injectively **provided the keys
  themselves are distinct residues modulo `2^k`**, which holds when all
  keys are below `hashCapacity`. Primary keys are, so the primary search
  never probes. Empirically: 0 collisions on both the practice and
  scale-2.9 4 px lattices; 327,766 and 4,451,867 collisions on the
  practice 2 px and 1 px lattices, whose keys exceed `hashCapacity`.
  The root's framing is right: the gain available is locality and
  arithmetic, not collision avoidance.
- Live entries are distinguished only by `hashGeneration[slot] ==
  store.generation`; `begin` increments the generation and zeroes
  `count` (`:227-229`). `begin` is called exactly once per A\* search, in
  `initAstarSearch` (`:575`), which runs after the connectors of every
  step including each fallback step (`:769-787`). Therefore **a search
  never mixes lattices**: all keys hashed under one generation belong to
  one `job.step`.
- Record ids are allocation order (`store.count`), independent of slot
  (`:251-259`); `keys[]`, `closed[]`, `gScore[]`, `cameFrom[]` and the
  fingerprint (`:826-837`) are indexed by record, never by slot. The
  capacity error is on `count`, not on slots (`:248-250`).
- Callers: `ensureRecord` from `initAstarSearch` (source) and
  `advanceAstar` (each legal neighbour); `findRecord` from
  `advanceReconstruct`. Nothing else reads the slot arrays.

## 2. Smallest credible shape

Reuse the three arrays unchanged; change only how a slot is chosen for a
primary-lattice search.

```nim
SearchStore = object
  ...               # existing fields, unchanged widths
  direct: bool      # this generation's keys index slots by identity

proc begin(store: var SearchStore, direct: bool) =
  inc store.generation
  store.count = 0
  store.direct = direct

proc hashSlot(store: SearchStore, key: int): int =
  let mask = store.hashKeys.len - 1
  result = if store.direct: key
           else: int((uint64(key) * 11400714819323198485'u64) and uint64(mask))
  while store.hashGeneration[result] == store.generation and
      store.hashKeys[result] != key:
    result = (result + 1) and mask
```

`initAstarSearch` passes `direct = job.step == PlanStepPx`. Everything
else (`findRecord`, `ensureRecord`, record allocation, capacity error,
fingerprints, fallback hashing) is untouched. The probe loop stays
because it is provably a no-op in direct mode (no two live primary keys
share a slot) and keeps the two modes' code identical past slot choice.

Why this over the alternatives the brief names:

- **A conditional branch in `hashSlot` with a stored mode** is one
  field, one parameter on the one `begin` call site, one branch. The
  mode cannot go stale: it is written at the only place a generation
  starts, and the generation is the only thing that makes an entry
  live.
- **Passing `direct` through `findRecord`/`ensureRecord`** changes two
  private signatures and three call sites for the same effect, and
  invites a mismatch where one caller passes the wrong mode for the
  current generation. Rejected.
- **Deriving the mode from lattice size** (`latticeW * latticeH <=
  hashKeys.len`) would also switch 2 px searches to direct on small
  maps, changing fallback hashing; the brief says preserve it, so the
  mode is `step == PlanStepPx` and the size condition becomes an
  assertion (invariant I1), not the switch.

Memory: zero new bytes. Generation width, record ids, unit accounting,
suspension fingerprints, capacity behaviour: unchanged.

## 3. Invariants to assert and preserve

- **I1 (direct fits):** when `direct`, `job.latticeW * job.latticeH <=
  store.hashKeys.len`. True by the constructor (`hashCapacity >= 2 *
  capacity >= 2 * primaryLattice`); assert it in `begin` so a future
  change to `PlanStepPx` or the capacity formula fails loudly.
- **I2 (one lattice per generation):** every `ensureRecord`/`findRecord`
  between two `begin` calls uses keys of the same `job.step`. True today
  because `begin` is only called from `initAstarSearch`, which every
  step transition passes through; `advanceReconstruct`'s `findRecord`
  runs in the same generation as the search that produced `cameFrom`.
- **I3 (no probing in direct mode):** with I1 and distinct keys, the
  while loop never advances. Can be checked in tests by counting probe
  steps; production keeps the loop.
- **I4 (record order):** `ensureRecord` allocates in call order in both
  modes, so record ids, `keys[]` and every fingerprint are identical to
  the multiplicative store for the same call sequence.
- **I5 (fallback unchanged):** `job.step in {2, 1}` searches hash and
  probe exactly as before; their slot choice is byte-identical code.

## 4. Counterexamples and oracle tests needed

- **Store differential** (`tests/body_search_reference.nim`: a copy of
  today's hash-only `SearchStore` procs; `tests/test_shell_body_search_exact.nim`
  via `include`): randomized sequences of `begin(direct)`, `ensureRecord`,
  `findRecord` with keys from a primary lattice in direct generations and
  from 2 px/1 px lattices (keys above `hashCapacity`, forcing collisions
  and probes) in multiplicative generations, alternating modes across
  resets; compare every returned record id, `count`, `keys[]`, and the
  tick at which the capacity error raises. Include a generation that
  fills to capacity in direct mode and one that does so in
  multiplicative mode.
- **Injectivity check on real geometries:** for the golden map, the
  scale-2.9 map and small synthetic maps (including one whose
  `hashCapacity` is the minimum 8), assert I1 and that no two primary
  keys share a slot in either mode.
- **Mode transition in a plan:** a plan that starts at step 4 and falls
  back to 2 and then 1 must produce the same `jobFingerprint` at every
  suspension and the same path as the oracle. Because `startFallback`
  needs a failed connector or an exhausted heap, the test should drive
  `beginSearchAtStep(job, 2)` and `(job, 1)` directly through the
  `include`d private API after a step-4 search, and also use the
  existing pocketed-start case if one can be constructed (a start whose
  4 px connector scan exhausts `maxRing`).
- **Chunk independence and cross-build:** the existing
  "charged suspension is chunk-independent" and golden round-robin
  tests, plus `H1/crossbuild_fingerprints.nim` on the golden map, must be
  unchanged; native same-budget semantic streams as in every card.
- **Negative control:** deliberately set `direct = true` for a 2 px
  search in the test build and confirm the differential test fails on
  the first colliding key, proving the tests can see a wrong mode.

## 5. Expected benefit, stated as an estimate

Per A\* pop, up to eight `ensureRecord` calls each touch three arrays at
a pseudo-random slot; under identity indexing the eight neighbours of a
lattice node fall on three consecutive row segments, and rows revisited
by the frontier stay warm. The arithmetic saving (one 64-bit multiply and
the probe compare per call) is minor; the locality saving is the point.
P1 attributes 1.17 % of baseline-512 samples to `hashSlot` and 0.27 % to
`ensureRecord` self time, with any stall not hoisted by the compiler
also landing there, so the measurable ceiling on this scenario is small
and A\*-only (bursts: max and miss count). It does not touch the minter
and cannot move p50. Whether it is worth a card depends on the H3 miss
shape, as `NEXT_EXACT_PLAN.md` section 2 states; this document only
fixes the shape so the card is short if it is chosen.

PHASE 11 READY

## Root clarification (proposal remains unselected)

The proposed mode flag adds no array allocation, but it can enlarge SearchStore
through field size/alignment; "zero new bytes" above should read "zero new
array bytes". Measure sizeof if this proposal is implemented. Constructor
invariants belong in focused tests unless a real trust boundary requires a
runtime guard. No direct-lookup implementation was selected after H3 passed.
