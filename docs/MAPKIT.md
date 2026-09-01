# Map authoring CLIs — Season 2 BR and deprecated classic maps

Season 2 battle royale uses `tools/brmapkit.nim`, which authors full-board,
asymmetric BR draws and validates spawn, mass, ring, zone, item, and wire-size
doctrine. Build the authoring tool and its engine-spec converter:

```bash
nim c -d:release -o:/tmp/brmapkit tools/brmapkit.nim
nim c -d:release -o:/tmp/br2ctf tools/br_spec_to_ctf.nim
```

The current loop is:

```bash
/tmp/brmapkit generate --seed 7 -o br-draw.json
/tmp/brmapkit render br-draw.json -o br-draw.png
/tmp/brmapkit validate br-draw.json
/tmp/brmapkit metrics br-draw.json --json
/tmp/br2ctf br-draw.json -o map-spec.json
```

`brmapkit`'s draw grammar carries BR-only concepts; `br_spec_to_ctf` performs
the required, self-verifying conversion to the engine's `mapSpec`. Do not feed
the draw JSON directly to the engine or map editor.

## Deprecated classic mapkit

The remainder of this guide documents `tools/mapkit.nim`, the retained
two/four-team classic authoring flow. Its output is useful for deprecated modes,
which boot only with `allowDeprecatedModes: true`; it is not the Season 2 map
generator.

`tools/mapkit.nim` is a CLI for generating and hand-editing CTF maps in the
native `mapSpec` format. It is a peer to the [map editor](designs/map-editor.md)
service: it never reimplements geometry, it drives the same sim procs
(`generateMapAttempt`, `mapSpecJson`/`mapFromSpecJson`, `validateGeneratedMap`,
`mapDiagnostics`, `buildArenaObstacles`) plus the shared `map_render`
rasterizer. **Fairness is entirely the sim's job** — generators emit a
one-half/quadrant seed set, the sim mirrors it, carves protected floor, and the
validators gate the result. Generators never reason about fairness.

Terrain styles live in `src/ctf/mapgen_styles.nim`; each is a pure
`(rng, region, params) -> seq[ArenaShape]` that fills the placement band with
CTF's native shapes (rect / disc / diamond). No sim change, no replay risk.

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
obstacle set with the chosen style's output. Because raw generation passes the
validator ~55–65% of the time, the intended workflow is **generate several
seeds, keep the ones that pass, then hand-edit** — `leftObstacles` in the JSON
is a plain array of shapes, and symmetry keeps every edit fair.

## Styles

| Style | Terrain | Key `--param` knobs |
|---|---|---|
| `bsp` | rooms + corridors (rect walls, doored) | `cell` (room size), `wallThick` |
| `caves` | cellular-automata organic cover (curved **blob polygons**) | `cell`, `fillProb`, `steps`, `birth`, `death`, `blobScale` |
| `maze` | recursive-backtracker lattice (thin walls) | `cell`, `wallThick`, `braid` |
| `scatter` | clumped boulder/pillar field | `period`, `prob`, `clusterMin/Max`, `radMin/Max`, `jitter` |

Override any style param with repeated `--param k=v` (e.g.
`--param cell=280 --param braid=0.3`).

## How fairness is guaranteed

- **Symmetry** — a style fills only the seed half (or the top-left quadrant
  on rot90/quadmirror); the sim expands it into an exactly team-fair whole via
  `buildArenaObstacles`. Quad-mirror boards also get thin column-anchor bars
  (the transpose of the styles' row anchors) because their validator scans
  VERTICAL sightlines too.
- **Carve** — the sim subtracts any shape overlapping a flag ring, spawn
  pocket, or capture lane, so generators never special-case protected floor.
- **Validators** — `validate` runs the real `mapDiagnostics`: cover budget
  (40–170 permille), no unbroken horizontal sightline, corridor connectivity,
  endzone gates. Non-zero exit on failure.

Every style adds a light backbone of **staggered vertical anchors** in a safe
mid-field x band. A horizontal sightline spans the full width, so scattered
cover alone leaves open lanes; the anchors block every row without forming a
continuous wall (which would fail connectivity), and sit clear of the protected
floor so the carve never reopens a lane.

## Export

A finished `mapSpec` drops straight into a game: set the config's inline map
spec, or feed the JSON into the curated pool. See
[ENV_VARIATION.md](ENV_VARIATION.md) for every map/gameplay knob a level can
vary.
