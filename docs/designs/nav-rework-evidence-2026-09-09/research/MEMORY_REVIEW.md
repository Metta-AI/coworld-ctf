# Review: shared pool retained-memory gap and the Dial bucket proposal

Written 2026-09-09 by Claude (peer) in response to `MEMORY_FINDING.md`. Source-backed, no src
edits. Line numbers are at 20234cc7 plus Codex's harness-only edits.

## 1. What counts as "shared retained nav data"
Caveat added 2026-09-09: `sharedDangerGeometry` was in fact copied per seat before M1 and the `total` figures were understated; the pool shared bound was conservative. See `MEMORY_SHARING_REVIEW.md`.


Ratified text (Asana comment thread, `../asana-task-1218165906459726-comments.md`):
- line 168 (task description, Codex's rewrite after James's review): "retained shared nav data
  <= 16 MiB (pool) / <= 32 MiB (colossal); transient build peak reported separately".
- line 44 (design review): "retained graph <= 16 MiB, and transient build peak <= 32 MiB".
- line 118: the query-local memo is "counted in the retained shared total"; "nothing is
  memoised per seat".
James's 2026-09-09 ruling (handoff section 5): "shared retained nav data <= 16 MiB on pool
maps (colossal cap raised, number set from measurement)". The colossal cap became
`BodyNavigationRetainedCap = 256 MiB` (`src/shell/body_nav.nim:29`); the pool 16 MiB was not
raised anywhere I can find.

Implementation (`retainedNavigationBytes`, `body_nav.nim:155-201`) sums:
- shared: `systemOwner`, `routeIndex` (room/portal index), `safetyScratch`, `mixedGraph`
  (graph arrays plus the one route workspace plus its Dial queue plus reconstruct), `trace`,
  `sharedDangerGeometry` (kernel and perimeter of seat 0, shared by all), plus the
  allocator overhead attributed to those;
- per seat: `seatOwners`, `seatCaches`, `dangerRasters`, `dangerWorkspaces`,
  `packedWeights`, plus their allocator overhead.

Verdict on the definition: the route index, the safety scratch and the workspace are shared,
retained, navigation data by the plain reading of every ratified sentence, and line 118 shows
the authors deliberately counted query-local shared state in that total. There is no ratified
basis for excluding `route_index` or `safety_scratch`. Codex's shared sum (17,510,959 bytes =
16.70 MiB) uses the right categories. The `allocator` figure Codex quotes (1,968) is the whole
overhead including per-seat sequences, so the true shared sum is at most that; the gap stands
either way. The harness (`tools/bench_body_nav_rework.nim:264`) gates only `total <= 256 MiB`,
so Phase 10 acceptance currently does not check the pool 16 MiB contract at all. That is the
qualification gap, confirmed.

## 2. The Dial queue: invariants that decide whether fewer buckets changes routes

`src/shell/body_route_query.nim`:
- `queuePush` (472-491): if the node is already queued it is removed first; bucket is
  `f mod bucketCount`; a bucket untouched in this search generation is lazily reset; the node
  is appended at the chain tail; `queuedF[node] = f` stores the absolute f; `currentF =
  min(currentF, f)`.
- `queuePop` (493-505): starting at `currentF`, look only at bucket `currentF mod
  bucketCount`; walk that chain from head and return the first node whose stored `queuedF`
  equals `currentF` exactly; otherwise increment `currentF` and repeat.
- `queueRemove` (455-470): unlink from the chain, `bucket[node] = -1`.
- `beginQueue` (507-514): new generation, `currentF = high(int32)`.

Consequences:
1. Exactness does not depend on bucket count. A node is only ever popped when its absolute f
   equals `currentF`, so a chain that holds several distinct f values (which happens whenever
   the live f span exceeds `bucketCount`) still pops in exact ascending f. The modulo never
   approximates f.
2. Tie order does not depend on bucket count. Among nodes with equal f, the chain order is the
   push order (append at tail; a decrease-key re-push removes and re-appends), and a node with
   a different f sitting between them is skipped without changing their relative order. So the
   pop sequence, hence parents, hence routes, is identical for any legal bucket count.
3. Therefore the route hash must be unchanged at 131,072. If it is not, the change is wrong
   somewhere else, not a tie effect.
4. What does change is chain-scan cost. Step cost is 64 units per 4 px orthogonal step and 91
   per diagonal, times a factor of (65,536 + profileWeight x Q8 danger) / 65,536
   (`mixedStepCost`, `packedFactor`, 347-364). A far route of a few thousand px has f in the
   tens of thousands with zero danger and into the millions under danger, so the live f span
   already exceeds 262,144 on some searches today: chains with mixed f values are not new at
   131,072, only more frequent. The extra cost is one `queuedF` compare per skipped node.
   Whether that is measurable is an x86 question (section 4).
5. `bucketCount <= 1` is rejected by the constructor (520), so 2 is the smallest legal value
   and the natural value for a "small bucket" equivalence test.

## 3. Arithmetic of the proposal

Bucket arrays sized by `bucketCount`: `head`, `tail`, `touchedGeneration`, each int32
(531-534). 262,144 x 3 x 4 = 3,145,728 bytes; at 131,072 it is 1,572,864, saving 1,572,864.
17,510,959 - 1,572,864 = 15,938,095 bytes = 15.20 MiB, under 16 MiB (16,777,216) by 839,121
bytes. The four per-node queue arrays (`next`, `previous`, `bucket`, `queuedF`) are unaffected.
Codex's saving figure is right. The margin is 5 percent; it holds on the largest pool map
Codex measured, and every pool map should be listed in the qualification row, not only the
largest.

## 4. What must be verified before adopting (agree with Codex's list, with specifics)

- Full corpus quality at 131,072 with the route hash equal to
  5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500 and zero missing/illegal.
  Per section 2 this is a strict expectation, not a hope.
- A focused test: same request, workspaces at `bucketCount = 2` and default, assert identical
  pop counts, identical route spans and identical fingerprint. Today
  `tests/test_shell_body_nav_rework.nim:99` builds only the default workspace; there is no
  small-bucket test. This test pins invariant 2 for the future.
- Timing on the registered x86 host, interleaved parent (262,144) versus candidate (131,072),
  three fresh processes each, breakdown on, per `PEER_PLAN.md` 1.4. Watch `route_search_ns_per_pop`
  and the far-goal rows; a chain-scan cost would show there first.
- Memory ledger on every pool map plus colossal from the activation row, with the shared
  categories listed explicitly next to the 16 MiB line; the harness should gate the pool
  shared sum at 16 MiB rather than only the 256 MiB total, otherwise the gap reopens silently.
- Both compile shapes and the focused suites.

## 5. Alternatives (for the record, not recommended over the proposal)

- Keep 262,144 buckets and drop `touchedGeneration` by tracking touched buckets in a small
  list cleared at `beginQueue`: saves 1 MiB, no chain change, but it is a queue redesign and
  belongs to the optimisation programme, not to closing Phase 10.
- Shrink `head`/`tail` to int32 already; nothing smaller is safe with node counts above 65,535.

## 6. Verdict

The gap is real and the definition is not in doubt. Halving the default bucket count is a
legitimate qualification fix: by construction it cannot change routes or tie order, it saves
exactly the bytes claimed, and the residual risk (chain-scan time on far searches) is
measurable with the existing harness. Adopt only after the five checks in section 4, and make
the harness gate the pool shared sum so this cannot recur.
