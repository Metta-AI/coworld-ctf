# H2 implementation: clearance certificate for segmentClear

Peer tree `nav-512-peer`. Working tree on top of the H1 checkpoint
`e730021a`; H2 is **not committed** (verdict: no further commits until the
viewer rule is met). Scope per `VERDICT_P2.md`: H2 only, separable from
H1. No budget, flag, other-module, native-host, push or publication change.

## Mechanism

`src/shell/body_planner.nim`, `segmentClear` only. Entry as refined by
`H2_REVIEW.md` (see `H2_REVISION.md`): clearance is read once, the
original invalid-start refusal comes first, then the certificate:

```nim
let startClearance = map.clearanceAt(start)
if startClearance <= PlayerHalf:
  return false
let dx = goal.x - start.x
let dy = goal.y - start.y
if startClearance > PlayerHalf + max(abs(dx), abs(dy)):
  return true
```

`clearanceAt` returns 0 out of bounds and `PlayerHalf` is positive, so the
first test is exactly the former `canStand(start)`. The existing scan runs
unchanged otherwise. Production diff: 10 insertions, 1 deletion
(`H2/H2_production.patch`, 25 lines); with tests 201 lines (`H2/H2.patch`). The
production patch applies cleanly to baseline `6b6b3408` without H1
(`patch --dry-run` recorded below), so the root can test H2 alone.

## Proof of exactness

Let `c` be the clearance raster and `d` the true chessboard (Chebyshev)
distance from a pixel to the nearest non-walkable pixel or map edge, with
non-walkable pixels at 0.

1. **`c` is the exact chessboard distance transform, capped.**
   `buildClearance` (`src/shell/body_map.nim:265-286`) is the standard
   two-pass chamfer with unit weights: forward pass over (x-1,y), (x,y-1),
   (x-1,y-1), (x+1,y-1); backward pass over (x+1,y), (x,y+1), (x+1,y+1),
   (x-1,y+1); each pass takes `min(neighbours) + 1`, out-of-map neighbours
   read as 0 (`:267-269`), non-walkable pixels stay 0 (`:273, :281`), and
   the forward pass caps at 255 (`:274`). Those two masks together cover
   all eight neighbours, which is exactly the chessboard DT; hence
   `c = min(255, d)`.
2. **1-Lipschitz.** For any pixels p, q with Chebyshev distance k,
   `d(q) >= d(p) - k` (a wall within distance `d(q)` of q is within
   `d(q) + k` of p). Therefore `c(q) = min(255, d(q)) >= min(255, d(p) - k)
   >= c(p) - k`, because `c(p) - k <= d(p) - k` and `c(p) - k < 255`.
   Saturation can only lower `c(p)`, so it can only make the certificate
   fail, never pass wrongly.
3. **Every tested pixel is within `span` of start.** The scan visits the
   supercover pixels of the segment and, on an exact diagonal step, the two
   side pixels `(x+stepX, y)` and `(x, y+stepY)` (`body_planner.nim`
   original `:313-316`). All of them lie inside the axis-aligned box from
   start to goal, whose Chebyshev radius from start is
   `span = max(|dx|, |dy|)`.
4. **Certificate implies scan result true.** If `c(start) > PlayerHalf +
   span`, then for every tested pixel q, `c(q) >= c(start) - span >
   PlayerHalf`, so `canStand(q)` holds provided q is in bounds. It is:
   edge-adjacent pixels have `d <= 1`, and a pixel at Chebyshev distance m
   from the map edge has `d <= m + 1`, so `c(start) >= span + 8` puts the
   edge farther than `span` from start. `canStand(start)` also holds.
   Hence the original scan returns true on exactly these inputs.
5. **Invalid starts.** `clearanceAt` returns 0 out of bounds
   (`body_map.nim:213-215`), so an out-of-map or unstandable start is
   refused by the first test before any coordinate arithmetic, exactly as
   the former `canStand(start)` did. Out-of-map goals cannot certify by
   point 4.
6. **Integer semantics.** `span` is a non-negative int from `abs`; the
   comparison is on ints; no overflow is possible for map-sized
   coordinates. No unit is charged or skipped: `segmentClear` is a pure
   predicate consulted inside one A* expansion or one connector candidate,
   and its value is unchanged.

## Tests added

- `tests/body_segment_reference.nim`: literal copy of the pre-H2
  `segmentClear`. Test support only; immutable.
- `tests/test_shell_body_segment_exact.nim` (shard 2) compares production
  against the reference on: every segment with |dx|,|dy| <= 5 from every
  pixel including one pixel outside the map on each side, both directions,
  on a bordered obstacle map with blocks, a one-pixel slit and a diagonal
  wall (877,844 segments); a fixed grid of invalid, edge and interior
  endpoints in both directions; 4,000 random segments up to 400 px on a
  640 px floor where interior clearance saturates at 255 (asserted); 120,000
  random segments up to 40 px on six generated obstacle maps with
  endpoints up to two pixels outside the map; and every 4 px lattice
  neighbour edge on a 200x120 obstacle map.
- Red/green record: with the certificate written as `>=` instead of `>`,
  four of the five tests fail (the bound is tight at the boundary); with
  `>`, all pass. Before the certificate existed the tests passed against
  the unchanged scan, confirming the reference equals the original. All
  five pass again after the `H2_REVIEW.md` entry refinement.

## Validation record (local arm64, Nim 2.2.6, `-d:release`)

Logs in `H2/`.

| Suite | Result |
|---|---|
| test_shell_body_segment_exact | 5/5 OK |
| test_shell_body_heap_exact | 6/6 OK |
| test_shell_body_nav | 21/21 OK |
| test_shell_body_seat | 26/26 OK |
| test_shell_body_danger_exact | 2/2 OK |
| test_shell_body_ray | 3/3 OK |
| test_shell_body_map | 15/15 OK |
| `nim check` runtime-stub shape | passes |
| `nim check` runtime-linked shape | not run (no Wasmtime C API locally); root's native build covers it |

Cross-build check (`H1/crossbuild_fingerprints.nim`, H1+H2 output in
`H2/crossbuild-h1-h2.txt`): identical to baseline `6b6b3408` and to H1
(`ticks=1119 suspension_digest=5936823674378073636
path_digest=3301525546362550601 points=29546`), so every plan and mint
fingerprint at every tick and every final path match.

Patch applicability to baseline without H1:

```
$ git show 6b6b3408:src/shell/body_planner.nim > base/src/shell/body_planner.nim
$ cd base && patch -p1 --dry-run < H2/H2_production.patch
patching file 'src/shell/body_planner.nim'
```

Hashes in `H2/sha256.txt`.

## Expected reach (diagnostic, not timing)

`H2/certificate_hit_rate.nim` on the BR golden map: of 2,252,232 lattice
edges from 281,529 standable 4 px lattice nodes, 2,172,408 (96.5 %) are
certified by `clearance(start) > 10` without a scan. Each certified edge
saves the scan's up to eight further `canStand` calls but not the
`canStand(nextPoint)` and bounds test that precede `segmentClear` in
`advanceAstar`. H2 affects A* and connectors only; the minter never calls
`segmentClear`.

## Limits

- No timing measured, by scope. Whether 96.5 % fewer scans is visible
  against the hash and heap terms in PEER_PLAN.md section 2.1 is for the
  root's native screen.
- The exactness proof depends on `buildClearance` remaining the exact
  chessboard transform; any future change to that raster must re-run
  `test_shell_body_segment_exact`.
- Runtime-linked compile shape unverified locally.

PHASE 3 READY
