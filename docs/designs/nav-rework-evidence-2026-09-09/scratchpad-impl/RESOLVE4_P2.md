RESOLVE4 P2: pocket connectors search on the PIXEL grid inside the fixed box; fine points may carry any of the 16 phases.

Ruling:
1. Pocket connector search (validator components only, per RESOLVE3): from an uncovered standable pixel, run a deterministic BFS over standable pixels (8-connected, `canStand` on every pixel, NavNeighbors order) confined to the fixed +-32 px box (at most 65x65 = 4,225 pixels; that box IS the cap, never map-derived). The targets are anchored nodes: any walkable coarse cell centre, or any fine point already retained in the index. Take the first target reached (BFS order is the tie-break).
2. Simplify the pixel path by greedy exact string-pulling with `segmentClear` (farthest reachable point first), then retain the resulting few points as fine points using the existing self-decoding 16-phase encoding (every pixel is representable in exactly one phase). The connector's static length is the true Q4 pixel distance.
3. Chain: connectors are added to the index in deterministic row-major order of their seed pixel and become anchors for later seeds; iterate passes until a pass adds nothing. Pixels of a validator component still uncovered after that are a real activation failure (map, component, first pixel), as RESOLVE3 rule 5 says.
4. Portal Pass B keeps the 8 px then 4 px order; if both fail, use the same pixel-grid search inside the choke's +-4-cell box as the third attempt before dropping the choke.
5. Retain, per coarse cell, an index of fine points that live inside it (a compact start/len over a flat fine-point list) so Phase 3 endpoint attach can find fine anchors within its 4-cell ring the same way it finds coarse ones. Report fine_points and their bytes per map as before.
6. Nothing changes for rooms, portal fields, or ordinary segments. Danger/hazard sampling for fine points still uses the containing 8 px cell.

Commit the RESOLVE3 scoping and this connector change as checkpoints, rerun the full qualification (64 published + arena + colossal), and finish Phase 2 with the per-map rows. End with the literal line PHASE 2 DONE.
