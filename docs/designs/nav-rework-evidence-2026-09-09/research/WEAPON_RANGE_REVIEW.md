# Weapon-range review: where the weapon stage's range-dependent work goes

Written 2026-09-09 by Claude (peer) at Codex's request after G0. Source and generated-C
review only; no source edits, no benchmarks, no timing claims from source. Numbers quoted are
Codex's G0 m5a rows (`G0_REPORT.md`) and my local G1 map-0 row (`G1-local-peer/`), both
whole-stage percentiles from different rows; nothing here adds or subtracts percentiles.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. What the weapon stage does per seat per tick (`body.nim:1412-1440`)
`combatCandidates` (878-889) walks every seat slot; for each track that is fresh this tick
it computes `trackShootable` and `combatBaseScore`. `selectCombatTarget` (1028-1075) scores
the candidates (preference tuple, ward threat, shootability weight) and sorts. If a target is
chosen, the actuation path (1212-1232) runs `fireGateAligned` and, for non-spray weapons, a
second `rayClear` to the chosen target. So per tick a seat performs one `trackShootable`
per fresh enemy track plus at most one extra `rayClear`.

## 2. Where the range enters
`trackShootable` (835-851) evaluates, in this order: `distancePx(self, track) <=
liveWeaponRangePx` (a libm `hypot`), then `map.rayClear(self, track)`, then
`protectedTrackBlocksShot`. `rayClear` (`body_map.nim:155-176`) samples the segment at
`steps = max(|dx|, |dy|)` pixels and for each step computes two `pyRound(a + d * step /
steps)` and one `isWall`. The distance gate is the only thing that bounds the work: every
fresh track inside the live range pays a pixel walk of up to the range length, and a track
just outside it pays nothing. That is why the weapon stage is small at 331 px, small on the
giant map where seats start 3,000 px from the cluster (G1 local: 0.09 to 0.18 ms), and large
on corpus map 15 at 1,300 px where the cluster is inside range (G0 m5a: 11.96 ms p95). With 8
fresh tracks in range and a 1,300 px walk each, a seat samples on the order of 10k pixels per
tick; 32 seats make that a few hundred thousand samples per tick, before the actuation ray.
The `inLiveWeaponRange` used by `trackThreatensPoint` (914-919) is the integer
`distanceSquared` compare and costs nothing; `preferenceScores` (724-747) uses one `sqrt`
per candidate for the ally term.

## 3. What one sampled pixel costs (generated C, Mac release build of the harness)
`rayClear` in `body_map`'s translation unit: per step, two calls to `pyRound__`, emitted as a
non-inline `N_NIMCALL` in the same unit, each of which calls libm `floor` and does a float
subtract and compare; two float divisions (`dx * step / steps` on doubles, one per axis);
one call to `isWall__` (same unit, non-inline), which calls `inBounds__`, performs an
overflow-checked `y * mapWidth + x` and a bounds-checked read of the pixel `wall` table. The
loop body carries 13 checked-arithmetic, bounds or error-flag sites. `distancePx` is one
libm `hypot`. So a sampled pixel is: two float divisions, two libm `floor` calls (at the
production flags, `COMPILER_REVIEW.md` section 2), three to four same-unit calls that GCC may
or may not inline at `-O3`, and a handful of checks, to read one byte.

## 4. Exact remedies (no change to which pixels are sampled or which rays pass)

### W1 (recommended): integer sampling that reproduces `pyRound` exactly
The sampled coordinate is `pyRound(a + dx * step / steps)`, nearest with ties to even. With
`|dx|, steps <= 3,300` the exact rational `dx * step / steps` has a fractional distance from
any half-integer of either zero (an exact tie) or at least `1 / (2 * steps) >= 1 / 6,600`,
and the double computation is correctly rounded, so its error (about 2^-42 at these
magnitudes) can never move the value across or onto a half-integer that the exact rational
is not on. Therefore `pyRound(a + dx * step / steps)` equals the exact integer expression:
`q = dx * step`, `lower = floorDiv(q, steps)`, `rem = q - lower * steps` (with `steps > 0`),
value `a + lower + 1` if `2 * rem > steps`, `a + lower` if `2 * rem < steps`, and on a tie
`a + lower + (lower and 1)` mirroring `pyRound`'s even rule on `lower + a` (note the parity
must be taken on the full integer `a + lower`, exactly as `pyRound` takes it on `floor(value)`;
`divideRoundTiesEven` in `body_hazard.nim:133` is the same rule for positive denominators
and can be reused or mirrored for negative numerators). This removes both float divisions and
both libm `floor` calls per pixel with no memory and no behaviour change; a test can prove it
by comparing the two samplers over every `(dx, dy, step)` up to the map diagonal, which is a
few hundred million cheap iterations in release, or exhaustively over a grid of segments on
every pool map.

### W2: read the wall byte directly inside the loop
`rayClear` lives in `body_map`, so it can index `map.wall[y * mapWidth + x]` itself after
one bounds compare, with `mapWidth` hoisted; that replaces `isWall`, `inBounds`, the checked
multiply and the bounds-checked read with one compare and one load. Exact by construction.
Combine with W1; the range proof for the index is the explicit bounds compare.

### W3: distance gate without `hypot`
`distancePx(self, track) <= range.float` can become `distanceSquared(self, track) <=
range * range` in int64, which `inLiveWeaponRange` already does. Exactness: for integer
`dx, dy <= 3,300`, `dx * dx + dy * dy < 2^24` is exact in double; if `d^2 <= R^2` the true
distance is at least `1 / (2R)` below or exactly at `R`, and glibc `hypot` is within one ulp
(about 2^-42 at these magnitudes), so the float compare and the integer compare agree on
every integer input. Removes one libm call per fresh track per seat per tick. Small but free.

### W4 (needs a proof before it counts as exact): evaluate `rayClear` only when it can matter
`selectCombatTarget` folds shootability into the score as a fixed weight for every candidate
and sorts, so every candidate's `shootable` participates in the ordering; skipping the ray
for a candidate is exact only if that candidate cannot reach the top under either value,
which is a bound argument over the score terms, not a local change. Listed so it is not
assumed; not recommended in this unit.

### W5 (shared state, real-play symmetric, listed for the record)
`rayClear(a, b) == rayClear(b, a)` for in-bounds endpoints by the W1 argument (the sampled
point sets coincide), so two seats that see each other at true positions compute the same
ray twice per tick. A per-tick memo keyed on the unordered position pair would be exact but
adds shared state and a hash; it wins in real play when duos see each other, not only in the
synthetic workload. Lower priority than W1 to W3 because they remove the cost rather than
halve it.

## 5. Preregistration proposal for W1 + W2 + W3 (Codex owns)
Parent: S1 checkpoint. Candidate: W1 + W2 + W3 in `body_map.nim` and `body.nim`.
Exactness gate first: (a) a test comparing the integer sampler with the float `pyRound`
sampler over an exhaustive grid of `(dx, dy)` up to the largest map diagonal and every
`step`, plus the symmetric property; (b) `rayClear` results identical to the parent on every
pair of lattice points within 1,300 px on three pool maps and one giant map (sampled, seeded);
(c) full corpus quality unchanged (routes do not use `rayClear`, so this is a regression
guard only); (d) `--tick` rows: `pops_per_tick` identical and, more to the point, the
per-tick weapon masks identical, which the existing replay fixtures and `test_shell_body_seat`
already pin; (e) the nine fixtures unchanged in bytes if no mask changes, which is the
expected outcome. Timing: G0's protocol, `--tick-gun-range 1300` on corpus map 15 (the row
where the weapon stage is loaded), three interleaved parent/candidate processes on m5a then
c6a, reporting `weapon_p95_ns` per row and repeat against the A/A spread; and the same on
one configured map with a start inside range of its far cluster, which needs `selectPairs`
or a chosen start to put seats within 1,300 px, otherwise the stage is idle as in my map-0
run. Prediction: `weapon_p95_ns` falls in loaded rows by the removed per-pixel work; no other
stage moves. Nothing is predicted in milliseconds.

## 6. Joint ranking of the next work (asked by Codex)
Three open items, all measured now rather than inferred:
1. Shared memory on the 11 giant maps: 30.5 MB shared against the 16 MiB pool cap on map 0
   (`G1-local-peer`), with `mixed_graph` at 28.3 MB the whole story (index and scratch are
   small). This is a ratified gate failing on the configured pool, so it precedes any
   throughput work. Codex said not to relax or reinterpret the cap; the remedies are
   structural: the dense 4 px workspace arrays (`g`, `parent`, `parentBridge`, `goalCost`,
   `state`, `goalStamp`, `reconstruct`, seven 4-byte arrays per lattice point) and the
   per-node queue arrays are sized by the fine node count, and the compact active-node
   workspace (H2 in `PEER_PLAN.md`) is the exact-routes candidate that shrinks them; the
   per-seat `visited` rasters (10.98 MB for 32 seats) are not in the shared sum but are the
   listed follow-up for a shared visited raster. This needs its own prereg; rank first.
2. Weapon floor at the configured range: W1 + W2 + W3 (section 4), exact, no memory, and it
   attacks the largest measured stage in G0's loaded rows. Rank second; it is independent
   of the memory work and can proceed in parallel under separate file ownership.
3. LOS raster R1 (`RASTER_REVIEW.md`): exact, 86 KB on giant maps, attacks the largest stage
   in my map-0 rows (`danger_p95` 10 ms locally) and G0's 8.08 ms danger row. Rank third
   only because it adds 86 KB of shared bytes on maps that already fail the shared cap; it
   should land after or alongside item 1 so the ledger shows both. Its prereg is written.
None of the three touches SJF, expiry, the corpus, or any threshold. Fleet exclusion and the
stale-cost policy remain the distinct decisions recorded in `ACCEPTANCE_MAP.md`.
