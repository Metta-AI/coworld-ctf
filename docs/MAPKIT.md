# mapkit — LLM-authored, interesting-but-fair CTF maps

`tools/mapkit.nim` is a CLI for generating and hand-editing CTF maps in the
native `mapSpec` format. It is a peer to the [map editor](designs/map-editor.md)
service: it never reimplements geometry, it drives the same sim procs
(`generateMapAttempt`, `mapSpecJson`/`mapFromSpecJson`, `validateGeneratedMap`,
`mapDiagnostics`, `buildArenaObstacles`) plus the shared `map_render`
rasterizer. **Fairness is entirely the sim's job** — generators emit a one-half
seed set, the sim mirrors it, carves protected floor, and the validators gate
the result. Generators never reason about fairness.

Terrain styles live in `src/ctf/mapgen_styles.nim`; each is a pure
`(rng, region, params) -> seq[ArenaShape]` that fills the placement band with
CTF's native shapes (rect / disc / hex / blob polygon). No sim change, no replay
risk. The non-round boulder is a **hexagon, not a diamond**: a diamond drawn
near the center column is silently claimed by `isSpinningDiamond`, so the old
shape handed hand-authored maps rotating stone they never asked for.

## The board is a hexagon

- The playfield is a **flat-top hexagon inscribed in the map's bounding box** —
  1119×969 px on the standard class, of which 779,019 of 1,084,311 pixels
  (71.8%) are field. The box's **six corners are permanent void**; anything a
  style places there is carved away by the border predicate.
- The **seed region is a half-plane**: the left half of the bounding box, at
  full box height. `generate`'s placement band is a rectangle inset from it, so
  its outer corners land in the void and a style's effective cover density
  inside the playfield runs **below** its nominal setting.
- **Two teams only.** `generateMapAttempt` refuses every other team count, and
  `--symmetry` takes only `mirrorHex` (mirror across the vertical center line)
  or `rot180`. `rot90` is gone — C4 is not a subgroup of D6. Every endzone is a
  **disc**, so `--endzone` takes `disc` and nothing else.

## Build

```bash
nim c -d:release -o:/tmp/mapkit tools/mapkit.nim
```

## The loop

```bash
mapkit generate --style caves --seed 7 -o m.json   # generate a candidate
mapkit render   m.json -o m.png                     # then LOOK at the PNG
mapkit validate m.json                              # fair + connected? (exit code)
mapkit metrics  m.json                              # cover / sightlines / reachability
$EDITOR m.json                                      # nudge leftObstacles by hand
# ...repeat until it looks good AND validates.
```

`generate` picks a seed that draws size/endzone/clearances, then replaces the
obstacle set with the chosen style's output. It calls `generateMapAttempt`
directly — ONE unvalidated draw, with none of the best-of-8 candidate ranking a
server build applies — and the terrain that draw produced is thrown away. So the
pass rate you see is a property of the **style and its params**, not of the
generator: the stock generator's own terrain passes 97.5–100% of the time per
size class (the committed baseline, `tests/fixtures/map-validation-baseline.tsv`,
is 199 of 200 seeds), which is why the validators are a crash guard rather than a
quality filter there. A style has to earn that on its own, so the workflow is
**generate several seeds, keep the ones that pass, then hand-edit** —
`leftObstacles` in the JSON is a plain array of shapes, and symmetry keeps every
edit fair.

## Styles

| Style | Terrain | Key `--param` knobs |
|---|---|---|
| `bsp` | rooms + corridors (rect walls, doored) | `cell` (room size), `wallThick` |
| `caves` | cellular-automata organic cover (curved **blob polygons**) | `cell`, `fillProb`, `steps`, `birth`, `death`, `blobScale` |
| `maze` | recursive-backtracker lattice (thin walls) | `cell`, `wallThick`, `braid` |
| `scatter` | clumped boulder/pillar field (discs and hexagons, 50/50) | `period`, `prob`, `clusterMin/Max`, `radMin/Max`, `jitter` |

Override any style param with repeated `--param k=v` (e.g.
`--param cell=280 --param braid=0.3`).

## How fairness is guaranteed

- **Symmetry** — a style fills only the seed half; the sim expands it into an
  exactly team-fair whole via `buildArenaObstacles`, applying the map's own
  group (`mirrorHex` or `rot180`) and deduplicating shapes that sit on the axis.
- **Carve** — the sim subtracts any shape overlapping a flag ring or an endzone
  disc, so generators never special-case protected floor. On a hex board that is
  the whole list: there is no straight home border for a protected column, and
  the wilderness behind each base is ordinary buildable field.
- **Validators** — `validate` runs the real `mapDiagnostics`: the cover budget,
  no unbroken sightline on any of the hexagon's chord families, corridor
  connectivity, endzone gates. Non-zero exit on failure.

The **cover budget is per-hull, not a fixed pair of numbers.** The floor scales
as `1/L` — 44 permille on the standard class, and 51 / 44 / 33 / 24 / 16 / 8
across small → colossal — because the wall that interrupts a hull's chords is a
one-dimensional curtain whose thickness never scales. The ceiling is scale-free
at **266 permille**, anchored to the fixed 1050px gun range. `metrics` prints the
band this hull was actually judged against; don't reason from the constants.

The sightline rule scans **all six chord families** of the hexagon —
90/30/150° edge-to-edge (maxing out at `2 × apothem`) and 0/60/120°
vertex-to-vertex (`2 × circumradius`, 1118px on the standard class, and the
longest family is the horizontal one straight down the red-base/blue-base axis).
A run only counts as a lane once it exceeds `sightlineMinSpan`, 80% of the
board's short axis, since chords near the two vertices are arbitrarily short.
Only the horizontal family is indexable by a row, so `metrics`' `open lanes
(0 deg rows)` count can read 0 on a map that a slanted lane still rejects —
`first failure` is the authority.

Every style adds a light backbone of **staggered vertical anchors** in a safe
mid-field x band. Scattered cover alone leaves open lanes; the anchors block
every row without forming a continuous wall (which would fail connectivity), and
sit clear of the protected floor so the carve never reopens a lane. They only
close the horizontal family — the five slanted ones are on the style.

## Export

A finished `mapSpec` drops straight into a game: set the config's inline map
spec, or feed the JSON into the curated pool. See
[ENV_VARIATION.md](ENV_VARIATION.md) for every map/gameplay knob a level can
vary.
