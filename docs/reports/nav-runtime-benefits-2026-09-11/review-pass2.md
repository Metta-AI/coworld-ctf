The new wall pattern closes the pass-1 coverage gap. I found no remaining correctness bugs, only nits.

I didn't compile or run the Nim tests. The coverage numbers below come from a Python model of the reference oracle's ray walk, not from the Nim code itself.

## Does the pattern now cover traversal and corners?

Yes. `cellCenter((i,j))` is `(8i+4, 8j+4)` (`src/shell/body_map.nim:224`), and every pattern pixel sits inside the border. So every grid cell with `(i + 2j) mod 5 == 0` is now blocked for sight. That is about 20% of cells on every test map: 13 on 8×8, 18 on 9×10, 39 on 16×12 and 32 on 12×13. Pass 1 found none, or one column.

For each origin cell, I checked whether a broken version would change a cell that has a nonzero kernel weight. Adding a zero weight leaves the float bits unchanged, so only those cells can make the exact comparison fail. "Corner check removed" means the diagonal step ignores a blocked side cell. "Ties as x-steps" means the diagonal branch is replaced by an x-step.

| Range | Origins where the corner-check removal shows | Origins where ties-as-x-steps shows |
|---|---|---|
| 64 px (all 4 maps) | 31/64, 47/90, 118/192, 94/156 | 18/64, 32/90, 92/192, 70/156 |
| 190 / 331 / 1300 | 48–100% of origins | 0 except 23/192 at 190 on 128×96 |
| 1050 | 0/64, 8/90, 51/192 | 0 |
| 1 / 15 | 0 | 0 |

Each case makes about 48 source origins (6 non-empty rebuilds × 8 sources), and the rollover test adds about 1,160 more at range 64. With detection rates like these, a missed corner or traversal bug is effectively impossible. Some other points:
- **Both side cells blocked never happens.** For a diagonal step the two side cells' values of `(i+2j) mod 5` differ by 1, so both can't be 0. That doesn't matter here: if the check used `and` instead of `or`, it would never trigger, which is the same as removing it, and that is caught.
- **The incremental decision is exact algebra.** It starts at `ny - nx` and changes by `+2ny`, `-2nx` or `+2ny-2nx`. Traversal changes are now tested at range 64 on every map.
- **`rayClear` holds up as pass 1 said.** `buildClearance` is an exact two-pass Chebyshev distance: walls and off-map count as 0, and the 255 cap only shortens jumps. So skipping `clearance` samples is safe, and the integer rounding matches `pyRound`.

## Remaining issues (nits only)

1. **`rebuildDanger` takes a map that it now only partly uses** (`body_nav.nim:463`). Walls come from the map captured at construction, but `cellOf` and the close-range loop still use the argument. This is documented, and every caller passes `system.map`. A guard is optional.
2. **The smallest ranges don't test traversal.** At 1 and 15 px the ray radius is at most 2 cells, and those rays never hit a tie. So those cases only check the kernel and the close-range floor. Range 1050 on 64×64 also has no corner cases. Other cases cover all of this.
3. **Benchmark output grows.** `raw_ns` now adds every sample to every row of `tools/bench_body_port.nim`, which makes the JSON larger.
4. **The `rayClear` doc comment** no longer says that endpoints outside the map count as blocked. The behaviour is unchanged, and the report now states it.

VERDICT: JUST NITS
