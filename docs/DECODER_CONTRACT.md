# The decoder release contract

`tools/dump_map_mask.nim` is not internal tooling. `.github/workflows/build-decoder.yml`
publishes it as a release binary `decoder-gv<N>-<sha>`, and
`cogames/ctf/team/bin/fetch-decoder.sh` in **daveey/cogamer** pins a build. Its
consumers therefore parse output from a binary they chose, on their own
schedule, against a schema they read once.

That is the whole hazard. When a key disappears from `--geom`, nothing on
either side fails: the field reads as absent, which in every consumer language
is some flavour of null rather than an error. It is the same shape as this
repo's label contract, and it now has a test —
`tests/test_decoder_contract.nim`.

## Format versions

`--geom` carries `formatVersion` (`DecoderFormatVersion` in the tool). It
versions the **export schema** and nothing else. `gameVersion` cannot serve the
purpose: it moves for unrelated reasons, and — the case that motivated this —
it did **not** move when the board became a hexagon and the C4-era capture-zone
keys were deleted.

| version | board | what changed |
|---|---|---|
| 1 | rectangle | `boardShape` absent (read it as "rect"). Capture zones could carry `diag` / `cornerX` / `cornerY` / `diagLimit` for the corner layouts. |
| 2 | hexagon | Those four zone keys are **gone** — no hex zone can produce the shape they described. Added: `boardShape`, `hullOrientation`, `hullVertices`, `circumradius`, `apothem`. Every capture zone is a disc. |

Bump on any key removed, renamed, or given a new meaning. Adding a key is
additive and does not need one.

## What a version-1 consumer gets wrong at version 2

**`--raw` still has the same length, and that is the trap.** It is still
`width * height` bytes, row-major, one per pixel, classes unchanged
(`0` floor, `1` stone, `2` glass). A consumer's shape check therefore still
passes. What moved is what a large minority of those bytes **mean**: the array
is the full bounding BOX, the playfield is the hexagon inscribed in it, and the
six corners outside the hull are permanent stone.

Measured on the default `arena` (1119x969, 1,084,311 bytes): floor is **62.3%**
of the box. Any statistic taken over the whole array — an open fraction above
all — has a different denominator than it did at version 1, silently.

**The hull is FLAT-TOP.** Vertices at the left and right side midpoints, flat
edges along `y = 0` and `y = height - 1`. The `boardShape` note in the tool
said "pointy top" for a while, against a hull that has always been the other
one; a consumer that believed it would reconstruct a hexagon rotated 30
degrees, getting every off-board test wrong in a way that still looks like a
plausible map. `hullVertices` is now published outright so nobody has to derive
the hull from an adjective, and the test asserts those six points really do sit
on the boundary predicate the sim collides against.

**Zone membership is a disc.** Read `disc` / `anchorX` / `anchorY` / `radius`.
The `xLo`/`xHi`/`yLo`/`yHi` box is retained (the strip and diff-box machinery
scans it) but it is the disc's bounding box, not the zone.

## Releasing

Not done automatically — publishing is public and hard to unpublish, and
consumers need telling separately either way.

1. Cut the release: run `build-decoder.yml` via `workflow_dispatch` with
   `source_ref` set to the merged ref. It tags `decoder-gv<GameVersion>-<sha>`.
2. Notify **daveey/cogamer** to move the pin in
   `cogames/ctf/team/bin/fetch-decoder.sh`, quoting the table above — the
   `--raw` denominator change is the one that will not announce itself.
