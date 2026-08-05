# Continuous fields and noise for map generation

**Research survey — dimension: CONTINUOUS FIELDS AND NOISE**
Written 2026-08-05 against the tree at `maxwell/mapgen-research-noise`.
Nothing here is shipped; this is a survey plus a build recommendation.

---

## 0. The one-paragraph answer

Perlin noise will not fix the map generator, and the reason is structural rather
than a matter of tuning. Every noise function in this survey is a **stationary,
isotropic random field** — statistically the same everywhere, with no preferred
direction. The metric we are furthest from, `interiorFrac` (arena 0.342, pool
median 0.118, weight 3.0 — the heaviest band in `map_metrics.DefaultBands`),
asks for the exact opposite: **locally enclosed pockets connected by open
lanes**, which is a non-stationary, structured, architectural property. A
stationary field cannot produce it without also destroying the sightline budget,
and §12 gives the geometric reason (a convex obstacle subtends less than 180°
from any exterior point, so it can never block 6 of 8 directions on its own; you
need *concavity*, and smoothing a noise field is precisely the operator that
*removes* concavity).

What noise **is** worth, honestly, in descending order of value:

1. **A level set of a smooth field is a disjoint union of closed curves, and the
   faces they cut the plane into form a TREE.** That is a hard theorem (§6.4).
   Thicken the curves into walls, punch exactly one door per curve, and the
   floor is connected **by construction** — no flood-fill repair, no
   generate-and-test. And a thickened closed curve is a *ring*, whose interior is
   8-of-8 blocked, which is exactly the `interiorFrac` structure we lack. This is
   the single highest-value finding in my dimension and it is where noise
   belongs.
2. **Poisson-disk sampling's minimum-separation property is a hard invariant**
   (§5.3), and with radius `R` and separation `r > 2R + MinCorridorWidth` it
   upgrades to a one-line proof of *floor connectivity and no sealed pockets*
   (§5.4). Our current `genScatter` has **no** such guarantee and can produce
   overlapping clusters (§5.5) — swapping its jittered grid for Bridson is a
   cheap, local, strictly-better change.
3. **You can solve for the threshold analytically instead of rolling dice**
   (§11). Cauchy's mean-chord formula plus Rice's level-crossing formula give
   closed forms for both cover fraction *and* mean free sightline as functions of
   the noise frequency and the threshold. Two equations, two unknowns. That
   turns thresholded noise from "generate and test" into "dial and get" for two
   of our banded metrics — a real (B)→ nearly-(A) upgrade for those two metrics
   specifically.
4. Everything else — fBm, ridged multifractal, domain warping, Worley, Gabor — is
   **(C) cosmetic** or at best **(B) distribution shift**. Domain warping is the
   best-looking trick in graphics and it guarantees nothing whatsoever about
   play. Say so out loud.

The correct pipeline position for noise is therefore: **noise decides *where* and
*what shape*; combinatorics decides *whether it is playable*.** Noise upstream of
a structural stage that carries the guarantees, never as the structural stage
itself.

---

## 1. The rubric

Every technique below is classified into exactly one of:

| Class | Meaning |
|---|---|
| **(A) HARD GUARANTEE** | The algorithm *cannot* emit a map violating the stated property. The property is an invariant of the construction, not an outcome. |
| **(B) DISTRIBUTION SHIFT** | Makes good output more likely. Still needs a filter. A tighter distribution is genuinely valuable — it raises best-of-K yield — but it is not a guarantee. |
| **(C) COSMETIC** | Changes how the map *looks*. Guarantees nothing about play, and in a top-down competitive game where the wall mask is the only thing the sim reads, often changes nothing measurable at all. |

Two honesty rules I am holding myself to:

- **A guarantee must name its property.** "Poisson-disk is (A)" is meaningless.
  "Poisson-disk is (A) *for minimum inter-obstacle separation*" is a claim you can
  check. Every (A) below names its property and, where the proof is short, gives it.
- **A guarantee that is conditional on a parameter range is still (A), but the
  condition must be stated as an assertion in code.** e.g. `assert r > 2*R +
  MinCorridorWidth`. A guarantee you can silently tune your way out of is a (B)
  wearing a costume.

---

## 2. The constraint wall

Every recommendation in this document has to survive these. Numbers are read out
of the tree, with file and line.

### 2.1 Geometry is continuous, not tiled

Obstacles are `ArenaShape` (`src/ctf/sim_types.nim:731-762`): `shapeRect`,
`shapeDisc`, `shapeDiamond` (L1 disc), `shapeDiagonal` (45° thick segment), and
`shapePolygon` — **a closed ring of integer vertices**, tested by even-odd
point-in-polygon (`inShape`). The comment on `shapePolygon` is the load-bearing
one for this survey:

> Curves (Beziers, metaballs, superellipses) are flattened to one of these by the
> authoring tools BEFORE they reach the sim, so the runtime never evaluates a
> curve — only integer even-odd point-in-polygon. Integer vertices keep symmetry
> transforms bit-exact.

**This is the whole reason a field-based generator is viable at all.** A
marching-squares contour of a scalar field *is* a closed ring of vertices. Round
the vertices to integers and it is a `shapePolygon`, with no new sim-side
primitive, no float in the wall mask, and symmetry still bit-exact. The output
format of the highest-value technique in this survey is already a first-class
citizen of our data model.

`mapgen_styles.nim` caps a blob at `BlobMaxVerts = 48` vertices
(`src/ctf/mapgen_styles.nim:18`) — a soft cap, but it tells us the expected
vertex budget per shape, which matters for how hard we simplify a contour (§6.5).

### 2.2 Scale: a width-1 corridor is meaningless

| Quantity | Value | Source |
|---|---|---|
| Player solid footprint | 13 px (`PlayerHalf` = 6) | `map_rules.nim:339` |
| Player drawn silhouette | 34 px (`SoldierBodyPx`) | `map_rules.nim:338-340` |
| `MinCorridorWidth` (enforced today) | **26 px** | `arena.nim:1073` |
| `RecommendedCorridorWidthPx` (not shipped) | **68 px** = 2 × 34 | `map_rules.nim:337` |
| `RouteCellPx` (metrics coarse cell) | 26 px, deliberately mirroring the above | `map_metrics.nim:91-95` |
| `GunRange` | **1050 px** | `sim_types.nim:317` |
| `EnclosureReachPx` | 120 px | `map_metrics.nim:77` |
| `LongRunPx` | 600 px | `map_metrics.nim:87` |
| `StandCoverRadiusPx` | 200 px | `map_metrics.nim:89` |

The practical consequence for field methods: **a scalar field's feature scale
must be quantised against 68 px, not against pixels.** A noise field whose
correlation length is 40 px produces wall features and gaps at 40 px, i.e. gaps
that are *legal* under the shipped 26 px rule but that two cogs cannot walk
abreast in. Any noise frequency you pick has to be picked from the corridor
budget backwards, not from "what looks nice at this zoom".

### 2.3 Symmetry is mandatory and is already solved

`generateShapes(style, seed, region, params) -> seq[ArenaShape]` returns a
**left-half / quadrant seed set only** (`mapgen_styles.nim:333-344`). The module
header is explicit:

> It never touches symmetry, protected-floor carve, endzones, or validation:
> those all live in `arena.nim` and are applied downstream.

`hex.nim` carries the cube-coordinate D6 kernel: `orbit(c, group)` and
`orbitUnique` (`hex.nim:423-441`), with `GroupC2` / `GroupC3` / `GroupV4` /
`GroupC6` / `GroupD6` (`hex.nim:371-397`) and the mandate **"Never rotate
pixels"** (`hex.nim:30`), because `sin 60° = √3/2` is irrational and a float
rotation reintroduces exactly the unfairness `validateMap` refuses.

**Therefore: do not build symmetric noise.** This is a real finding and it saves
work. The literature trick for making a random field invariant under a finite
group `G` is either (a) evaluate at a canonical orbit representative, which is
exactly invariant but introduces a gradient crease at the fundamental-domain
boundary, or (b) average the field over the orbit (a Reynolds operator), which is
invariant *and* smooth but attenuates contrast and reshapes the spectrum by a
factor depending on |G| (§10). **Our pipeline makes both unnecessary**: evaluate
the field only on the fundamental domain, emit shapes, and let the existing orbit
lift produce the other |G|−1 copies. Symmetry stays (A) by construction, for free,
with a *sharper* field than either symmetrisation trick would give you.

The one thing you do have to handle is the **seam**: a shape that straddles the
fundamental-domain boundary gets folded into a chevron (mirror) or a rosette
(rotation). §10.3 covers the two ways to deal with it.

### 2.4 A straight open row is a weapon, and the validator says so

`validateGeneratedMap` (`arena.nim:2219-2237`) walks `y` from `ArenaBorder + 2` in
**steps of 4**, and for each row scans `x` from `sightlineLoX` to `sightlineHiX`
against `minWall` (the pessimistic, always-there wall mask). If no wall blocks
the row, the map is rejected:

```
result.reason = "open horizontal sightline at y=" & $y
```

Three things follow, and they matter a lot for noise:

1. **The validator is axis-aligned and horizontal-only.** It checks rows, not
   columns and not diagonals. Any noise artefact that produces long *horizontal*
   open runs hits the tripwire directly; the same artefact rotated 90° passes the
   hard validator and is only caught softly by `longRunFrac` (cap 0.15,
   `map_metrics.nim:1301`).
2. **Perlin's grid bias is axis-aligned.** Classic Perlin has known directional
   artefacts along the lattice axes and the 45° diagonals (§4.2). If you sample a
   Perlin field on a lattice aligned to the map axes, you are correlating the
   noise's worst artefact with the validator's only hard geometric rejection.
   This is the single most concrete "noise is dangerous here" claim in the
   survey. Mitigation is cheap and mandatory: **rotate the noise domain by an
   angle unrelated to the axes before sampling** (§4.5, "domain rotation"), or
   use OpenSimplex2, or both.
3. **We already pay a crutch for this.** `verticalAnchors`
   (`mapgen_styles.nim:120-153`) exists purely because "random layouts almost
   never satisfy the mirror condition on their own", and `arena.nim:1921-1990`
   runs a whole `sightlineRepair` pass that plugs uncovered rows with diamonds,
   budget `cols(40)`. A noise generator will need the same crutch. **The fact
   that every existing style needs an explicit anti-sightline structure bolted on
   is itself evidence that no purely stochastic placement rule solves it.**

### 2.5 The fitness we score against

From `map_metrics.DefaultBands` (`map_metrics.nim:1278-1362`) — the ones a field
method actually moves:

| Band | lo | hi | weight | arena (control) | pool median |
|---|---|---|---|---|---|
| `interiorFrac` | 0.25 | 0.65 | **3.0** | **0.342** | **0.118** |
| `exposedFrac` | — | 0.20 | 1.0 | 0.038 | 0.22 |
| `longRunFrac` | — | 0.15 | 1.5 | 0.110 | 0.17 |
| `routeCapacityFrac` | 0.12 | 0.50 | 2.0 | 0.316 | 0.4–0.6 |
| `collisionCoverRatio` | 0.70 | 2.40 | 1.5 | 1.456 | 0.83 |
| `midCrossCount` | 3 | 12 | 1.5 | 5 | 2–12 |
| `detourMax` | 1.10 | 1.90 | 1.0 | 1.295 | 1.14 |
| `visDegreeCv` | 0.30 | 1.20 | 1.0 | 0.524 | 0.28 |

The band note on `interiorFrac` names it directly: *"the scatter-vs-buildings
discriminator"*. `visDegreeCv` says the same thing from the other end —
*"a uniform board has no good and bad ground"* — and **uniformity is the defining
property of a stationary random field.** Two of our bands are literally
penalising statistical homogeneity. That is worth sitting with before writing a
line of noise code.

`interiorFrac` itself is defined at `map_metrics.nim:138` and
`map_metrics.nim:77-84`: **open floor with ≥ 6 of 8 directions blocked within
120 px.** The definition is doing the work; §12 unpacks it.

---
