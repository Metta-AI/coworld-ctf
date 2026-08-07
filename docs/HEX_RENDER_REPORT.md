# Hex rendering pass: what shipped, what was refuted, what is left

Scope was the six rendering items on the hex-arena epic's rendering task. Three
were already landed on `maxwell/hex-integration` before this pass started; one
was measured and REFUTED; two shipped here, plus one piece of item 1 that the
distance-transform work had explicitly deferred.

Nothing in this pass is in `gameHash` (`map_art.nim:4`), so no recorded replay
is affected. Both viewer pages are `staticRead`-baked into `bin/ctf-server`, so
the client changes need a server rebuild to appear.

---

## 1. EDT lighting rewrite — ALREADY LANDED, plus the deferred half

The Felzenszwalb distance transform, the continuous `dot(n, light)` shade and
the `SeamAxis` parameterization landed in `9b9ea1d`, merged into
`maxwell/hex-integration`. It also cut the giant-board bake from 3990ms to
787ms.

What it deliberately left, in its own words — "a hex build moves the two
materials onto two hex axes without touching the shading code" — was never
done. Both seam families were still the square-lattice pair, level sets of
`x + y` and `x - y` at ±45°. Shipped here (`9128d03`):

| | before | after |
|---|---|---|
| roof seams | normal 45° | normal **90°** — parallel to the hull's flat top/bottom |
| glass sheen | normal −45° | normal **30°** — parallel to the upper-right edge |

60° apart, exactly the bound the existing compile-time assert anticipated.
0.68% of the standard board's pixels change, all roof or glass.

**The trap worth remembering:** `seamPhase` mods `nx·x + ny·y` by the period,
so stripe SPACING is `period / |n|`. The old pair had length √2. Normalising
the new pair to unit length — the obvious thing to write — silently widens
every roof seam by √2. Both new vectors keep length √2 so only the angle moves.

## 2. Void material — ALREADY RESOLVED, DIFFERENTLY

The task asked for a "deep shadow" void material. `hex-integration` had already
considered and rejected that: `ArenaVoidNote` (`map_art.nim:34-64`) records that
a dedicated void material worked but read as a FAKE BACKDROP — a lit stage the
hexagon sat on, which then needed a dark panel behind it to look intentional.
The answer it shipped is alpha 0: the corners emit nothing and the hull
silhouettes against whatever is behind the board.

That makes the compositor a contract, and the contract is honoured:
`broadcast_core.js` now `clearRect`s where it used to fill `#000`.

**Verified empirically**, since this is exactly where the house rule
(`replay_broadcast.html:53`, never pure `#000`) could have been broken: sampled
the served board's void corners and the stage letterbox — all four read
`(18, 13, 9)` = `#120d09`, the warm near-black, and there is no pure-black pixel
anywhere in the corner region. The void is indistinguishable from the letterbox,
which is the intent.

Left as-is. Re-litigating a deliberate, documented design decision was not the
job.

## 3. One shared boundary predicate — REFUTED, guard shipped instead

The divergence is REAL. `loadMapLayers` derives its mask from
`rasterizeRestWallMask`, which stamps the border via `mapBorderWallAt`
(`hexEdgeDist < ArenaBorder`). `renderArenaRgbaPair` stamps a RECTANGLE. On a
hexagon those disagree, because a hexagon meets its bounding box along only two
of its six edges:

```
border ring at scale 2:                    132,760 px
art mask disagrees with the collision rule:  88,604 px  (66.7% of the ring)

  NE diagonal   97.7%      N (flat top)    0.0%
  NW diagonal   97.3%      S (flat bottom) 9.9%
  SW diagonal   97.5%
  SE diagonal   98.0%
```

**It cannot reach the image.** `ArenaBorderColor` is opaque (alpha 255) and
`overTint` at alpha 255 returns the tint verbatim, so every ring pixel paints
solid `(44,34,25)` whatever the mask put under it; outside the hull the paint
loop short-circuits to transparent before consulting the mask at all.

Measured, not argued — implementing the "correct" fix (one hull classification
shared between the mask stamp and the paint loop) changed the finished image by:

| map | changed px | max channel delta |
|---|---|---|
| arena | 0 | – |
| arena-large | 0 | – |
| gen:1007 | 0 | – |
| pool:0 | 6 | 4/255 |
| pool:1 | 3 | 4/255 |
| pool:2 | 3 | 4/255 |

and cost **+23%** on `renderArenaRgbaPair` (interleaved A/B, 3 rounds:
282ms → 347ms, standard hull, scale 2). That bake is on the certifier's boot
clock and the EDT work had just bought it down from 3990ms to 787ms on a giant
board. Six pixels is not worth 23% of that.

Reverted, and `tools/hex_border_art_probe.nim` ships in its place. It reports
the divergence and then asserts the two properties that make it unreachable:
`ArenaBorderColor.a == 255`, and — end to end, from the real bake — that zero
ring pixels in the finished image are anything but the solid tint. Make the
tint translucent and it fails, which is the moment the stamp must move to
`hexEdgeDistF`.

## 4. Hex-periodic floor texture — SHIPPED (`3d850c9`)

Joints moved from a 2×2 grid of 128px square panels to a honeycomb whose cells
are pointy-left-right, the hull's own orientation. Surface untouched.

**The tile is no longer square, and that is the point.** `tileSample`/
`tileSampleF` are square-torus wraps, so the image must hold a whole number of
lattice periods on both axes. A hex lattice's fundamental rectangle has aspect
√3 : 1 — irrational — so no square image can hold an integer number of REGULAR
hexes. Forcing 256×256 costs 15% anisotropy. 256×296 costs 0.13%:

```
COL_DX = 64  ->  x period 128,  256 / 128 = 2 exactly
ROW_DY = 74  ->  y period  74,  296 /  74 = 4 exactly
```

Neither renderer needed a line changed — both already wrap per-axis and size
their tile block from `floorTex.width/height`.

The honeycomb is the Voronoi diagram of the centre lattice: distance to the
nearest joint is half the gap between the nearest and second-nearest centre. No
polygon clipping, periodic for free.

Two contracts are now asserted in the bake rather than eyeballed:

- **Ember envelope** (`emberThroughCracks`, `map_art.nim:664`). Joint seams must
  stay ≥ `EndzoneFaceLevel` 66 or the endzone glow bleeds along the whole
  lattice; some crack bottom must reach ≤ `EndzoneCrackLevel` 34 or it shows no
  glow. Measured: seams bottom out at 72, min lum 32, 99.1% above 66 — against
  the old tile's 33 / 99.07%.
- **Seamlessness**, against the DISTRIBUTION of interior transitions rather than
  their mean: crossing the wrap must not be the largest step in the image
  (4.96 vs an interior max of 6.27).

Two notes for whoever touches this next:

- The first draft of the ember check demanded 0.05% of pixels below 34 and
  **would have failed the tile it was written to protect** — the real figure for
  the old tile is 0.011%. Cracks are hairlines; the full-glow floor is
  hundredths of a percent by design. It is now calibrated against measurement.
- The old tile would FAIL the seam check and did not need to pass it: it put its
  joints ON the wrap, so its seam WAS the biggest transition in the tile
  (y-wrap 21.8 vs an interior max of 18.4), hidden by reading as a panel edge.
  The new lattice's wrap lands mid-face, so it is held to the honest standard.
- A naive port of the joint profile read far too loud. A hex lattice has three
  edge directions to a square grid's two, and smaller cells, so the same bevel
  width is much more seam per unit area. The profile is deliberately tighter.

## 5. Minimap — VOID state SHIPPED (`0e5b717`), rest already landed

Already landed on `hex-integration`: the single `min()` scale with centering
offsets, the CSS `aspect-ratio` driven from the streamed `m.w/m.h`
(`syncFpvMapShape`), and the vertical midline replaced by `fieldBoundaryPath` —
which already draws a hexagon. Verified live: the inset reports `1119 / 969`,
ratio 1.1549, and its POV bubble is a circle.

What was missing is the 4th palette state. `fpMapWallsJson` asks `isWall`, and
outside the hull `isWall` is TRUE — the corners are permanent wall in both
collision layers, exactly as `mapBorderWallAt` says. So the corners reported as
STONE and the inset baked a full rectangle of terrain with the playfield punched
out of it: a rectangular arena with four solid corner blocks, in the one place a
viewer reads the field's extent.

Added state `3 = VOID`, emitted where `insideHex` is false, painted as nothing.
The floor wash is already clipped to `fieldBoundaryPath`, so a floor cell shows
the wash and a void cell shows neither — the silhouette becomes the hull.

Rectangular boards never emit 3, so they are byte-identical on the wire. A
viewer that knows only three states indexes `pal[st] || pal[0]` and degrades to
floor rather than mis-indexing.

**Verified** by building a second server with state 3 painted as stone —
byte-for-byte the old behaviour — and screenshotting the same inset on both with
the raycast behind it blanked. Before: 37.7% of the inset is solid slate,
filling all four corners. After: 0%.

The test that asserted `st in 0 .. 2` now decodes the RLE to a grid and checks
state 3 is EXACTLY the outside-hull cells — zero mismatches, not merely "some
void was seen" — and pins the void count between an eighth and a half of the
grid so it cannot pass vacuously.

## 6. BOARD_ASPECT — ALREADY LANDED

`syncBoardAspect` is present and wired (`e19bc90`, ported onto
`hex-integration`). Verified live rather than by reading: the board canvas
measures 858×743 = **1.1547**, which is 1119/969 to four decimals. The stage is
sized to the real board, not to 1235×659.

---

## Finding: "skip all-void bands in `addMapBands`" is a no-op

The task flagged ~25% wasted void per band against `WasmViewerBudgetBytes`.
`addMapBands` emits **full-width horizontal** crops. Every horizontal band of a
hexagon intersects the hull — the hull spans the full height and the full width
— so **no band is ever all-void** and there is nothing to skip. The 25% is
spread evenly across every band instead of concentrated in droppable ones.
Recovering it needs 2-D tiling, which is a different and much larger change to
the sprite protocol's placement model. Not attempted.

## Deliberately not done

- **Rewriting `renderArenaRgbaPair`'s border stamp** (item 3) — measured as
  0-6 pixels for +23% bake. Guard shipped instead. Reopen if
  `ArenaBorderColor` ever becomes translucent; the probe fails loudly then.
- **A void MATERIAL** (item 2) — superseded by a documented decision on this
  branch. The alpha-0 answer is verified working against the house rule.
- **2-D map banding** — see above.

## Tools added

- `tools/hex_border_art_probe.nim` — measures the art/collision border
  divergence and guards the two properties that make it harmless.
- `scripts/art/build_floor.py` — now asserts both the ember envelope and
  seamlessness on every bake.
