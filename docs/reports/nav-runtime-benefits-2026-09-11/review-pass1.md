I found no correctness bugs. The `rayClear` rewrite, the shared danger geometry, the incremental `castRay` decision and the uint8 visit stamps all produce exactly what `origin/main` did. I checked this by reading the code and tracing the logic; I did not compile or run the tests, since that writes build artifacts and you asked for read-only.

## Why the changes are exact

**`rayClear`** (`src/shell/body_map.nim:141-211`)
- **Wall test:** `buildClearance` (`body_map.nim:265`) gives wall pixels 0 and walkable pixels at least 1. So `clearance == 0` means exactly the same as the old `isWall` for in-bounds points. Every sample is in bounds, because it lies between two in-bounds endpoints.
- **Skipping ahead is safe:** the clearance map is an exact Chebyshev distance, with the map edge counted as wall and values capped at 255. A clearance of `c` means every pixel within `c-1` is clear. Each sample moves at most one pixel per axis, so samples `s+1 … s+c-1` must be clear. The next check at `s+c` is correct, and returning true when `c > steps - sample` is correct. The cap at 255 only makes jumps shorter.
- **Rounding matches the old float version:**
  - On the long axis, `dx*k/steps` is exactly `±k`, so it is always an integer.
  - On the short axis, `lower + r/steps` with `r` in `[0, steps)` matches `pyRound`, including ties to even: a tie (`2r == steps`) is exactly representable in float.
  - Float error, around 2⁻³², is far smaller than the `1/(2·steps)` gap to a tie, so the old code never mis-rounded at these map sizes.
  - The one-step update needs only one correction because `|delta| ≤ steps`. The multi-step path uses `floorDiv` on int64.
  - The loop can't overshoot, because a jump happens only when `sample + c ≤ steps`.

**Incremental `castRay` decision** (`body_nav.nim:360-384`): the starting value `ny - nx` and the updates (+2ny, −2nx, and +2ny−2nx on the diagonal) follow directly from the old formula `(1+2ix)·ny − (1+2iy)·nx`. When the side cells are blocked, the loop breaks before the update, so the value is never used afterwards.

**Shared geometry** (`body_nav.nim:176-206`): the kernel and perimeter are built the same way as before. `sightBlocked` stores `isWall(cellCenter)` for every grid cell. Every grid cell centre is in bounds, because `newBodyMap` requires width and height of at least 8. The map is immutable, and nothing writes to the geometry. `rebuildDanger` is always called with the map the system was built on (`system.map`, `scenario.map`, or the same map in tests).

**uint8 stamps** (`body_nav.nim:317-323`): the generation starts at 0 and is incremented before any use. When it wraps, all stamps are reset to 0 and the generation restarts at 1, so 1–255 are unique within each cycle. The per-cell float additions happen in the same order as before, so the danger values are bit-identical.

**Test oracle:** `tests/body_danger_reference.nim` matches `origin/main` line for line: constants, `pyRound`, `attenuation`, geometry, uint32 stamps, `castRay` and the rebuild. No code still uses the removed per-seat fields or the old `sightCellBlocked(map, …)`. The two new `test_*` files are imported by `shard_2`, so `test_shard_wiring` passes. The helper file isn't named `test_*`, so it doesn't need wiring.

## Findings (none block merging)

1. **The danger test maps barely have walls.** In `tests/test_shell_body_danger_exact.nim:10-12`, the walls fall on cell centres in only a few places.
   - The 64×64 and 73×85 maps have **no** blocked sight cells at all.
   - The 128×96 and 96×104 maps have one blocked column (cell x=9, rows 0/3/6/11).
   - On an open map, the combined ray coverage doesn't depend on which cells each ray passes through. So these tests only weakly check the incremental decision, the `sightBlocked` table, and the diagonal branch where a side cell is blocked (`body_nav.nim:367-369`).
   - The recurrence is simple algebra, so the risk is low. Still, a wall pattern placed on cell centres (for example, blocking `(8k+4, 8j+4)` for a scattered set) would make the float-exact comparison a real test of traversal.

2. **`rebuildDanger` takes a `map` argument that no longer controls wall checks** (`body_nav.nim:389`, `463`). Walls now come from the map captured at construction, while `cellOf` and the grid size still use the argument. Before, walls came from the argument too. Every current caller passes the same map, so nothing breaks today. A `doAssert map == system.map`-style check, or a comment, would guard future callers.

3. **Doc nit:** the new `rayClear` doc comment (`body_map.nim:165-166`) drops the old note that endpoints outside the map count as blocked. The behaviour is unchanged.

4. **CI check to confirm (not a correctness issue):** `tools/sim_sources_stamp.sh` hashes every tracked `src/*.nim`, and git's `*` matches `src/shell/…`. `tools/qa_module_eval.cjs:329` fails if the committed replay viewer's stamp doesn't match HEAD. So this diff may turn the `wasm-replay-viewer` job red unless the bundle is rebuilt. Recent src/shell-only commits (e.g. `e2219b7f`) didn't rebuild it in the same commit, so check how that job actually behaves before opening a PR.

## Do the tests exercise the invariants?

- **`rayClear`:** yes, well.
  - The exhaustive 8×8 test with one wall pixel covers jumps of 1–8 and the multi-step path.
  - The 10k random long rays in both directions hit many exact ties, including on negative slopes. The steep-ray branch appears in only about 1% of them, but the other two tests cover it directly.
  - The 640² test checks the 255 cap, that the distance is Chebyshev (`(500,220)→100`), and borders and corners.
- **Stamp rollover:** yes. `MaxDangerSources = 8`, so 145 non-empty ticks × 8 ≈ 1,160 generations, about 4 wraps. Source positions vary and overlap on a 12×13 grid, so skipping the reset on wrap would leave stale stamps and break the bit-exact comparison.
- **Shared geometry:** the test that seat 1 stays at zero is only a light check against shared writable state, but the geometry has nothing writable.
- **Traversal and `sightBlocked`:** only weakly, because of finding 1.

The bench change adds a `port.danger_rebuild_8src_live1300` row with a distinct name, and looks fine.

Author response: strengthened blocked-cell patterns as requested. The immutable-map
argument contract and outside-endpoint behavior are recorded in the integration
report. Viewer rebuilt and module/stamp QA passed. No runtime guard added for
the existing same-map caller invariant. Reviewer did not run tests; test
execution evidence is separate.
