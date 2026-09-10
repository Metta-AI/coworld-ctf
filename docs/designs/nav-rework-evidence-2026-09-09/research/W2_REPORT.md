# W2: direct wall lookup with compiler checks retained

The single ray-loop change replaces a repeated public `isWall` call with a direct private wall-table read after endpoint validation. Arithmetic and sequence bounds checks remain enabled. The parent is W1; both arms include identical M1/M2/M3 ownership, accounting and harness changes. CPU 5 on native m5a, Nim 2.2.6, release/useMalloc/noSignalHandler, B=1,024, 1,300 px range. Exact source patches and all raw rows are in W2-m5a.

| Repeat | Arm | Worst whole-body p95 ms | Worst maximum ms | Worst weapon p95 ms |
|---|---|---:|---:|---:|
| 1 | parent | 11.543802 | 12.864276 | 9.623225 |
| 1 | candidate | 10.373651 | 10.424742 | 6.009722 |
| 2 | parent | 11.458970 | 12.803095 | 9.528218 |
| 2 | candidate | 10.367771 | 10.465894 | 5.977772 |
| 3 | parent | 11.471049 | 12.764492 | 9.550265 |
| 3 | candidate | 10.375292 | 10.534817 | 5.983773 |

Every recorded mask and pop array matches in all six rows of all three pairs. The differential ray test passes. Full frozen quality passes 3072 cases, zero missing/illegal, 37637596 pops; route hash `5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500`. Full activation run exits zero with M3 context accounting.

Worst whole-body p95 falls from 11.543802 to 10.375292 ms and maximum from 12.864276 to 10.534817 ms. The loaded weapon stage improves; danger-dominated rows remain near 10 ms. Stage maxima belong to different rows and are not additive. This is a useful local optimization, not a tick-gate pass or a doubling claim. Retain for combined qualification; viewer and final shipping checks remain outstanding.
