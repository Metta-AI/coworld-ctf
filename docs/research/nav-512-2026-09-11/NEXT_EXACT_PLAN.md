# Next exact mechanism after H3: comparison and one conditional pick

Prepare-only. No implementation, no native use, no commit. Inputs: the
current planner loops in the peer tree (`body_planner.nim`
`advanceMintSearch` at `:473-515`, `advanceAstar` at `:603-655`,
`ensureRecord`/`hashSlot` at `:231-260`, `body_cache.nim` accessors at
`:156-200`), `H4_DRAFT.md`, `NEXT_REVIEW.md`, `INLINE_REVIEW.md`, P1
attribution, the H1 and H1+H2 native results, `H3/NATIVE_CHECKS.md`, and
the frozen `qualification/PROTOCOL.md`.

## 0. What the next candidate has to fix

H1+H2 at 512 versus original 256 (native, three pairs): total 1.009, p50
1.057, p95 0.900, max 1.027, worst misses 149 vs 104. The three misses
have different owners:

- **p50** is the quiet-tick frame. On quiet ticks the planning stage is
  the minter spending the leftover pool, so p50 is the minter's number.
- **max and the miss count** are the synchronized-replan bursts, where A\*
  spends the whole pool in one tick on top of the ladder burst.
- **total** is the sum, currently dominated by the minter's +2.0 s at 512
  (P0) minus what H1 and H2 recovered.

H3 removes leaf frames on both arms. Its result decides which owner is
still short; the pick below is conditional on that.

## 1. The three mechanisms, against the actual loops

### A. H4: smaller minter heap payload (`H4_DRAFT.md`)

Minter nodes always carry `priority == cost` (`:485-486`, `:470-471`);
the comparator's `cost` branch is reached only on a priority tie, where
it ties too. A mint-specific node without `cost` is 32 bytes instead of
40 on amd64 (`priority` f64, `tie1`, `tie2`, `item` as native ints).

- Affected cost: bytes moved per sift level in the minter heap only, 20 %
  fewer; one comparator branch that already almost never executes. The
  heap is one of three roughly equal terms in a mint pop (heap, cell
  walkability, route-raster access), so the ceiling is a few percent of a
  mint pop.
- Memory/layout: the server-wide minter heap shrinks by ~0.7 MB; per-seat
  memory unchanged. Layout of the A\* heap unchanged.
- Code shape: `FixedHeap` becomes generic over the payload, instantiated
  twice, so the H1 sift code is not duplicated. That is the largest diff
  of the three and touches the H1 oracle.
- Proof and oracle: ordering is identical because the dropped key is
  always equal to the kept one; needs a minter-specific original-heap
  differential (the H1 oracle extended with a normalization
  `cost = priority`), `mintFingerprint` normalized the same way so digests
  stay comparable, chunk-independence and cross-build parity.

### B. Primary-lattice direct record lookup (`NEXT_REVIEW.md` section 3)

`ensureRecord` probes three separate 8-byte arrays of 1,048,576 slots
(24 MiB per seat) at a multiplicative hash of the lattice index for each
of up to eight neighbours per A\* pop (`:245-260`, `:637`). A direct map
indexed by the primary 4 px lattice index (344,487 entries) replaces the
probe for step 4; the hash remains for the 2 px and 1 px fallback steps.

- Affected cost: A\* only. P1 self time in `hashSlot`/`ensureRecord` is
  1.4 % of samples, but the miss stalls land in `advanceAstar` self time
  and cannot be separated by sampling; the local estimate in
  `PEER_PLAN.md` 2.1 put the hash at the largest single A\* term. This
  is the mechanism for max and misses, not for p50.
- Memory/layout: +3.9 MiB per seat with a 64-bit generation stamp and an
  `int32` record index (+125 MiB at 32 seats), inside the 4x allowance;
  no existing array changes size. Record numbering is preserved because
  `ensureRecord` is still called in the same order, so `keys`, `closed`,
  `gScore`, `cameFrom`, the capacity error and all fingerprints are
  unchanged.
- Proof and oracle: a copy of `SearchStore` as oracle, randomized
  ensure/find/begin comparison including generation resets and the
  fallback-step path, plus cross-build parity and same-budget streams.

### C. Exact per-pop hoisting in the minter loop

Per mint pop today (`:473-515`, after H3's inlining): three `gridWidth`
reads through the `minter.map` ref, one `routeDistanceAt` and up to eight
more, up to eight `setRouteDistance`, and up to sixteen `cellWalkable`
calls. Each raster access is `cache.routeSlots[slot].distances[cell]`: a
bounds check on `slot`, a `seq` header load, a bounds check on `cell`, a
data load; `setRouteDistance` repeats it for `hops`.

- Change: at the top of the pop, take the route slot once (`ptr
  RouteFieldSlot` from a new hot-loop accessor in `body_cache`, or a
  `template` that binds it) and read `gridWidth`/`gridHeight` into
  locals; relax neighbours through the bound slot. Reads, writes, their
  order and values are identical, so units, rasters, heap contents and
  fingerprints are unchanged by construction.
- Affected cost: the minter's non-heap term. P1 (pre-H3) put
  `routeDistanceAt` 1.49 %, `setRouteDistance` 0.29 %, `gridWidth` 0.68 %
  and `cellWalkable` 1.49 % under `advanceMintSearch`, with 1.95 % self;
  H3 has already removed their frames, so the remaining target is the
  repeated bounds checks and pointer chases, roughly a third of a mint
  pop's instructions by the local assembly. Expected whole-game effect at
  512: low single-digit percent of the mint stage; this is the p50 lever.
- Memory/layout: none. Keeps bounds checks (one per pop on the slot, one
  per cell access). No unit, cadence or cap change.
- Proof and oracle: a `tests/body_mint_reference.nim` copy of today's
  `advanceMintSearch` plus accessors, compared after every pop on route
  raster (`distances`, `hops`), heap contents and positions (reusing the
  H1 oracle's layout comparison through `include`), across random goals
  on the golden and obstacle maps and across suspension chunkings; the
  existing `referenceRouteRaster` test; cross-build parity; same-budget
  semantic streams natively.

## 2. The pick, conditional on H3

If H3 passes its stage screen but misses the 512 target:

- **If p50 is still above 1.00** (quiet ticks, minter): take **C** as
  the next card. It is the only remaining exact mechanism that reaches the
  minter without a layout change, it has the smallest diff, and its
  exactness is by construction. H4 (A) is ranked behind it because its
  ceiling is smaller (20 % of one of three terms) and it costs a generic
  heap refactor that touches the H1 oracle.
- **If p50 is at or below 1.00 but max or misses still exceed the
  parent** (bursts, A\*): take **B** instead. C does nothing for bursts;
  B is the only exact lever left on the A\* pop's dominant term.

State it plainly: if H3 leaves p50 more than about two percent over, C
alone will not close it, because its ceiling is a few percent of the mint
stage while the mint stage is elastic and scales with the pool by design
(`PEER_PLAN.md` 1.2, 5). The brief forbids repricing or capping mint work,
so that residual is not closable by an exact mechanism and must be
reported as such rather than chased with ever smaller micro-changes.

## 3. Cross-platform gate: what the split probe can and cannot say

`CROSS_ARCH/split_digest.nim` separates the map raster (integers), the
danger field (float32 bits), per-tick per-seat counters (stage, units,
expansions, fallback step, mint stage/units/expansions/slot, path length,
route keys, ready count) and a floats digest sampled every 97th route
cell. It can prove that the raster or the kernel differs, and it can
show that per-tick counter aggregates agree. It **cannot** establish
exact pop ordering within a tick, heap contents, `gScore` values,
`cameFrom` links, or every internal decision: two runs with different
pop order but the same per-tick expansion counts and the same paths are
indistinguishable to it. The original full-state digest gate stays as the
cross-platform statement of record until a per-tick full-state
comparison (or a first-divergence dump) explains the difference; the
protocol's determinism line should not be weakened on the strength of the
split probe.

## 4. Concrete points on the frozen six-cell protocol

Bounded to six cells is fine; the coverage claims are accurate. Concrete
items to fix or record before running:

1. **Pin the guest module bytes.** The frozen configs reference
   `qualification/.build/nav_research_moving.wasm` and
   `play_sdk/.build/edge_ride.wasm`, both gitignored build outputs; the
   config hashes do not cover them. Record the SHA-256 of both `.wasm`
   files as built on the native host in the manifest (local
   `nav_research_moving.wasm` is
   `d51b9cf843125997dd1523ae2db34d18ef2491ec1dca111c4d76d9e963c251e3`;
   the native build may differ byte-wise and should be the one frozen).
2. **View cadence and replan expectation.** `shell_demo_config.json`
   sets `viewIntervalTicks` 6, so the moving play is stepped every six
   ticks and emits on the 12-tick boundaries it sees (0, 12, 24, ...),
   which is fine, but the check "12-tick interval scheduling while alive"
   should be stated as "one new install per 12-tick interval", and
   observed planning revisions will exceed installs: `moving_goal` makes
   the follower replan every `PlanMovingReplanTicks` (12) on its own, and
   stuck detection adds `forcedReplan` revisions when 16 or 32 cogs
   converge on the same quarter point and jostle. More revisions than
   installs is expected, not a fault.
3. **Convergence is part of the stress.** All seats of a moving cell head
   for the same two points, so collision and stuck replans dominate late
   intervals. Record `SHELL_NAV` stale/no-path counts per cell so this is
   visible, and do not read them as route-quality evidence.
4. **Correctness runs count.** Six cells x (candidate 256 + original 256)
   = 12 extra games at 1,200 frames each, before the 36 timed games. The
   protocol should say they run first and that a same-budget mismatch
   stops the campaign before any timing.
5. **Memory check needs a definition.** "Activation and retained memory on
   the largest test map and a colossal geometry" should name the
   measurement: per-seat allocation bytes from the constructors
   (arithmetic) plus one `newBodyNavSystem` activation RSS reading; and
   note that no candidate so far changes any allocation, so the expected
   result is byte-equal.
6. **Early end on edge cells.** Pool maps 505/5001 have not run 1,200
   frames at `hitPoints` 3 with 16 solo seats yet; the protocol's
   pre-registered replacement rule covers it, but the replacement (which
   health, which cell) should be written down now rather than at failure
   time.

PHASE 10 READY
