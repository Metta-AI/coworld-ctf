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

## 3. The master table

Everything surveyed, classified. "Property" is what the (A) actually guarantees —
an (A) with no named property is not an (A).

| # | Technique | Class | Property guaranteed (A only) | Cost | What it buys us |
|---|---|---|---|---|---|
| 4.1 | **Perlin (classic, 1985)** | **(C)** | — | O(2^n) corners/sample, ~40 ns | A smooth field. Axis-aligned artefacts *actively hostile* to our horizontal sightline validator (§2.4) |
| 4.3 | **Improved Perlin (2002)** | **(C)** | — | same | C² continuity (matters for derivatives/normals — we render none of those) |
| 4.4 | **Simplex noise** | **(C)** | — | O(n²), ~2× faster in 2D | Fewer directional artefacts than Perlin; analytic gradient |
| 4.5 | **OpenSimplex2 / domain rotation** | **(C)→(B)** | — | ~same as simplex | Removes the residual straight-edge lattice artefacts. **(B) for `longRunFrac`** specifically, because it decorrelates the field from the map axes |
| 4.6 | **fBm (octaves/lacunarity/persistence)** | **(C)** | — | ×N octaves | Multi-scale texture. §11.3: each octave *shortens* mean free sightline for no structural gain |
| 4.7 | **Ridged multifractal / billow / turbulence** | **(C)** | — | ×N | Sharp crests / puffy lumps. `1-abs(n)` creates *creases*, which read as ridgelines — the only fBm variant that makes anything resembling a wall network |
| 4.8 | **Domain warping** | **(C)** | — | ×2–3 field evals | The best-looking trick in the survey. Guarantees **nothing**. Makes contours sinuous and non-repetitive, which is worth real money aesthetically and zero competitively |
| 5.1 | **Worley / cellular (F1)** | **(C)** | — | O(9) cells/sample 2D | Blobby cover. Same convexity trap as scatter (§12.1) |
| 5.2 | **Worley F2−F1** | **(B)** | — | same | Voronoi *cracks* — a connected thin-wall network, i.e. the one cellular variant that is topologically room-like |
| 5.3 | **Poisson-disk (Bridson)** | **(A)** | **min separation ≥ r between all samples** | O(N) | Guaranteed inter-obstacle gaps ⇒ guaranteed corridor width |
| 5.4 | **Poisson-disk with r > 2R** | **(A)** | **+ floor connectivity, no sealed pockets** | O(N) | One-line proof, replaces a flood-fill repair |
| 5.6 | **Maximal Poisson-disk (Ebeida)** | **(A)** | **+ covering: every point of the board is within `r` of a sample (an r-net)** | E[O(N log N)] time, O(N) mem | Bounds *dead floor* from above — the max-void guarantee. Also gives Delaunay min-angle > 30° for free |
| 5.7 | **Jittered/stratified grid** | **(A)** | **exactly one sample per cell; min sep ≥ period − 2·jitter** | O(N) | Free version of the above, weaker. **Our `genScatter` violates its own** (§5.5) |
| 5.8 | **Lloyd relaxation / CVT** | **(B)** | — | O(iters·N log N) | Evens out cell sizes. Converges to a *local* optimum only — no uniformity bound |
| 5.9 | **R2 / golden-ratio low-discrepancy** | **(B)** | (bounded discrepancy is proven; min-separation is *conjectural* for R2) | O(1)/sample, stateless | Deterministic, seekable, no memory. See the honesty note in §5.9 |
| 6.2 | **Threshold / excursion set** | **(C)** | — | O(pixels) | Walls from a field. §12.2: provably blob-regime at our cover cap |
| 6.2 | **…at an empirical quantile** | **(A)** | **exact pre-carve cover fraction** | +O(N log N) sort | Turns the cover validator into a non-event (§11.5) |
| 6.3 | **Hysteresis / double threshold** | **(B)** | — | +1 flood fill | Kills speckle, thickens features. Removes sub-corridor pinches *statistically* |
| 6.4 | **Marching squares → `shapePolygon`** | **(A)** | **output is closed, simple, non-self-intersecting loops** (given consistent saddle resolution) | O(pixels) | Directly emits our native polygon primitive |
| 6.4 | **Contour nesting tree + one door per contour** | **(A)** | **floor connectivity, by construction** | O(contours) | **The headline finding.** Rooms *and* connectivity from the same object |
| 6.5 | **RDP / Visvalingam simplification** | **(B)** | — | O(n log n) | Gets a 4000-vertex contour under the 48-vertex budget. **Does not preserve simplicity** — needs a guard |
| 7.1 | **Curl noise** | **(C)** | divergence-free is (A), but of a property we do not care about | ×2 field evals | In 2D its streamlines *are* the level sets of the potential (§7.1) — same object as §6.4, no new information |
| 7.2 | **Tensor fields / hyperstreamlines** | **(B)** | — | high | Genuine lane layout with designer control. The one technique here that thinks in terms of *routes* |
| 8.1 | **Gabor / sparse convolution noise** | **(B)** | — | ~10–50× Perlin | **Exact, per-point control of orientation and bandwidth.** The principled fix for "no long horizontal runs" |
| 8.2 | **Phasor noise** | **(C)** | — | high | High-contrast oriented stripes; a stripe field is a *corridor* field |
| 9.1 | **Hydraulic / thermal erosion sim** | **(C)** | — | very high | Beautiful heightfields. We render no height |
| 9.2 | **D8 flow routing + priority-flood** | **(A)** | **every cell has a downhill path to an outlet ⇒ the flow graph is a spanning forest** | O(N log N) | A *guaranteed-connected* channel network, for ~1% of the cost of the erosion sim |
| 10.1 | **Fundamental-domain evaluation** | **(A)** | **exact symmetry under the orbit group** | free | Already how our pipeline works. **Do not build symmetric noise** |
| 10.2 | **Orbit-averaged (Reynolds) noise** | **(A)** | exact symmetry, smooth across the seam | ×\|G\| evals | Only needed if you must evaluate the field on the *whole* board |

Read the table as: **there are exactly six (A)s in my whole dimension** — §5.3/5.4,
§5.6, §5.7, §6.2-quantile, §6.4, §9.2, §10 — and **five of the six are not
noise at all.** They are point processes, level-set topology, flow routing and
group theory. The noise is the paint; the guarantees come from the combinatorics
underneath it. That is the honest shape of this dimension.

---

## 4. The gradient-noise family

### 4.1 Perlin noise (1985)

Ken Perlin, *An Image Synthesizer*, SIGGRAPH '85, Computer Graphics 19(3):287–296
(https://dl.acm.org/doi/10.1145/325165.325247). Reference implementation and the
author's own page: https://cs.nyu.edu/~perlin/noise/.

The construction: place a pseudo-random unit **gradient vector** at every integer
lattice point; for a sample point `p`, take the dot product of each surrounding
corner's gradient with the offset from that corner to `p`, and interpolate the
`2^n` results with a smooth fade. Because the value at a lattice point is the dot
product of a gradient with the zero vector, **Perlin noise is exactly 0 at every
lattice point** — a structural fact, not an artefact of a particular
implementation, and the root of most of its visual problems.

Cost: `2^n` corner evaluations per sample — 4 in 2D, 8 in 3D, 16 in 4D.

### 4.2 The artefacts, and why they are dangerous *here* specifically

Three known, structural artefacts:

1. **Value-zero lattice.** Every lattice point is a zero crossing. At threshold
   `u = 0` the level set is forced through a regular grid of points, so the
   contour inherits grid structure directly.
2. **Axis and 45° bias.** The interpolation is separable — done along `x`, then
   `y` — and the gradient set is finite and symmetric about the axes. The result
   is that features preferentially align with the lattice axes and the diagonals;
   the power spectrum of Perlin noise is not isotropic, and this is well
   documented in the noise-survey literature (Lagae et al., *A Survey of
   Procedural Noise Functions*, Computer Graphics Forum 29(8):2579–2600, 2010 —
   the canonical reference for spectral comparison of noise bases).
3. **Directional derivative discontinuity in the original fade.** The 1985 fade
   `3t² − 2t³` has a non-zero second derivative at `t = 0, 1`, so the field is C¹
   but not C² and the *derivative* shows the lattice plainly.

**Why this matters for us and not for a terrain renderer.** Our only hard
geometric rejection is `"open horizontal sightline at y=…"`
(`arena.nim:2219-2237`), and it is **axis-aligned and horizontal-only**. Perlin's
worst artefact is *also* axis-aligned. Sampling a Perlin field on a lattice
parallel to the map axes deliberately correlates the noise's failure mode with
the validator's tripwire — and, worse, with `longRunFrac` (cap 0.15, arena 0.110,
pool median 0.17 — the pool is *already over* this cap).

Mitigation is cheap and should be treated as mandatory, not optional:

```
# sample the field in a rotated frame, angle unrelated to the map axes
const NoiseTheta = 0.5843   # ~33.5 deg; any angle with irrational tangent works
let (c, s) = (cos(NoiseTheta), sin(NoiseTheta))
f(x*c - y*s, x*s + y*c)
```

This is the same idea as OpenSimplex2's recommended "domain rotation" for 2D
slices of 3D noise (§4.5). It costs two multiplies and removes the specific
correlation that would hurt us.

### 4.3 Improved Perlin (2002)

Ken Perlin, *Improving Noise*, SIGGRAPH 2002, ACM TOG 21(3):681–682
(https://dl.acm.org/doi/10.1145/566570.566636). Two changes:

- **Fade curve** `6t⁵ − 15t⁴ + 10t³`, whose first *and* second derivatives vanish
  at `t = 0` and `t = 1`, making the field C². This removes the visible
  second-derivative grid.
- **Gradient set** restricted to the **12 vectors from the centre of a cube to
  its edge midpoints** (`(±1,±1,0)`, `(±1,0,±1)`, `(0,±1,±1)`), which (a) removes
  the bias of a naively-normalised random gradient set, and (b) makes the dot
  product additions and subtractions only — no multiplies. The 12 directions are
  more uniformly distributed on the sphere than the 8 cube-corner directions, and
  cheaper than true random unit vectors.

**Verdict for us: (C).** C² continuity buys shading quality. We rasterise a
binary mask; we do not shade the field. Take improved Perlin because it is
strictly better and free, but do not expect it to change a metric.

### 4.4 Simplex noise

Perlin, *Noise Hardware* (SIGGRAPH 2001 course notes) and the SIGGRAPH 2002
material; the clearest exposition is Stefan Gustavson, *Simplex noise demystified*
(2005), https://weber.itn.liu.se/~stegu/simplexnoise/simplexnoise.pdf.

Simplex noise replaces the hypercube lattice with a **simplex** lattice (the
densest regular simplex tiling of the space — triangles in 2D, tetrahedra in 3D).
Key facts:

- **Cost drops from O(2ⁿ) to O(n²).** A simplex in `n` dimensions has `n+1`
  corners, not `2ⁿ`. In 2D that is 3 corners instead of 4; in 4D, 5 instead of 16.
- **Skew transform.** The square grid is skewed into the simplex grid by
  `F = (sqrt(n+1) − 1)/n` and unskewed by `G = (1 − 1/sqrt(n+1))/n`. In 2D,
  `F = (sqrt(3) − 1)/2 ≈ 0.366`, `G = (3 − sqrt(3))/6 ≈ 0.211`.
- **Radially-symmetric summed kernel** rather than separable interpolation: each
  corner contributes `max(0, r² − |d|²)⁴ · (grad·d)`. Because the kernel is
  radial, the directional bias of separable interpolation is gone.
- **Well-defined, cheap analytic derivative** at every point (the separable Perlin
  interpolant's derivative is more awkward).

**The patent.** Perlin held US Patent 6,867,776 B2, "Standard for perlin noise"
(filed November 2001, granted March 2005), covering the *simplex-lattice*
implementation of gradient noise — not classic Perlin noise, which predates it and
was never patented. The patent expired in **January 2022** on the normal 20-year
term. This is why OpenSimplex exists at all, and why the concern is now historical.
*(Dates from memory; worth a 30-second check before quoting them externally.)*

**Verdict: (C).** Faster and less directionally biased than Perlin, which is a
real improvement to the *distribution* of artefacts, but it still guarantees
nothing. Use it; do not credit it.

### 4.5 OpenSimplex / OpenSimplex2, and domain rotation

Kurt Spencer's OpenSimplex (2014) and OpenSimplex2 (https://github.com/KdotJPG/OpenSimplex2)
were written first to sidestep the patent and then, more interestingly, to fix a
residual artefact of 2D simplex noise: the triangular lattice leaves faintly
visible **straight-edge / directional streaks** along the simplex grid directions.
OpenSimplex2 uses a different lattice and gradient set and measurably reduces
them.

The most practically valuable thing in that repository is not the noise function
but a piece of advice: for **2D slices of 3D noise**, apply a **domain rotation**
that puts one axis along the (1,1,1) direction, so that the 2D plane you sample
is not aligned with the lattice at all. The same idea applied to pure 2D — sample
in a rotated frame — is the mitigation in §4.2, and it is the single change that
moves this family from (C) toward (B) *for `longRunFrac` specifically*.

### 4.6 fBm: octaves, lacunarity, persistence

The fractal sum, standard since Mandelbrot and formalised for graphics by
F. Kenton Musgrave (PhD thesis, *Methods for Realistic Landscape Imaging*, Yale
1993; and *Texturing & Modeling: A Procedural Approach*, Ebert/Musgrave/Peachey/
Perlin/Worley, ch. 16 "Procedural Fractal Terrains"):

```
fbm(p) = sum_{i=0}^{N-1}  gain^i * noise(lacunarity^i * p)
```

- **octaves** `N` — how many scales are summed.
- **lacunarity** — frequency multiplier per octave. 2.0 is standard; values that
  are *exactly* 2 make octaves share lattice alignment, so ~2.01–2.19 is common
  folklore to decorrelate them. (Folklore, not established — but harmless.)
- **persistence / gain** — amplitude multiplier per octave. 0.5 with lacunarity 2
  gives amplitude ∝ 1/frequency, i.e. **pink / 1/f noise**, and Hurst exponent
  `H = 1` via `gain = lacunarity^(−H)`.

Musgrave's real contribution beyond the plain sum is the **multifractal**: make
the amplitude of each octave depend on the value accumulated so far, so the local
fractal dimension varies with altitude — smooth valleys, rough peaks. Variants:
*hybrid multifractal*, *hetero terrain*, *ridged multifractal*.

**Verdict: (C), and see §11.3 for the sting** — under our metrics, octaves past
the second or third actively cost us mean free sightline and polygon vertices for
no structural gain.

### 4.7 Ridged, billow, turbulence

All three are pointwise reshapings of the same sum:

| Name | Per-octave transform | Look |
|---|---|---|
| turbulence | `abs(noise)` summed | Puffy, creased, "smoke" |
| billow | `abs(noise)` then remapped to [-1,1] | Bulbous lumps |
| ridged | `1 − abs(noise)`, usually squared | Sharp crests along the zero set |

The one worth noticing is **ridged**. `abs()` creates a **crease along the zero
set of the noise**, and `1 − abs(n)` turns that crease into a *maximum*. So the
high values of a ridged field form a **thin, connected, branching network** — the
zero-level curve of the underlying noise, thickened.

That is structurally the same object as the §6.4 contour ribbon, arrived at by a
different route, and it means **ridged multifractal is the only member of the
gradient-noise family whose high-value set is topologically a wall network rather
than a field of blobs.** If you want a quick, ugly, one-line experiment to see
whether contour-walls help `interiorFrac`, thresholding a ridged field high is a
30-minute version of it.

Ridged also has an important practical downside for us: the crease is where the
gradient is discontinuous, so the extracted contour has high curvature and eats
vertices.

### 4.8 Domain warping

Inigo Quilez, *Domain warping*: https://iquilezles.org/articles/warp/ (see also
*fBM*: https://iquilezles.org/articles/fbm/). The canonical formulation:

```
q = ( fbm(p + c1), fbm(p + c2) )
r = ( fbm(p + 4q + c3), fbm(p + 4q + c4) )
f = fbm(p + 4r)
```

i.e. `f(p) = fbm(p + fbm(p + fbm(p)))`. Warping the *input* domain by another
noise field before evaluating.

This is the highest-value aesthetic trick in procedural graphics and I want to be
careful to praise it accurately. What it does: it destroys the statistical
signature that makes noise look like noise. Plain fBm has the same "cloudiness"
everywhere; a warped field develops **regions with distinct character** — swirls,
elongations, folds, filaments — because the warp locally stretches and compresses
the domain, so the *effective local frequency* varies from place to place. That
local frequency variation is precisely the non-stationarity that plain noise
lacks.

Now the honest part, in three claims:

1. **Domain warping does not create structure, it creates the *appearance* of
   structure.** The excursion-set topology at a given area fraction is largely
   preserved by a warp, because a warp is (locally) a diffeomorphism, and
   diffeomorphisms preserve topology. The Euler-characteristic argument in §12.2
   goes through essentially unchanged. **A warped field thresholded at 15% is
   still a field of blobs — prettier, more elongated, more varied blobs.**
2. **It destroys isotropy locally, which is a genuine (B) for us.** Elongated,
   curved features are directionally biased *locally* but with a direction that
   varies across the map — which is exactly the opposite of the axis-aligned bias
   that hurts us. So warping is a real, if indirect, mitigation for
   `longRunFrac`: a long open run has to follow a straight line, and warped
   contours are almost never straight for 600 px.
3. **It costs 2–3× the field evaluations** and the effect saturates fast.

**Verdict: (C), with an honest (B) footnote for `longRunFrac` and `visDegreeCv`.**
Use it — it is genuinely the difference between "generated" and "designed"-looking
contours, and if we ship a contour-based generator the warp is what will make the
rooms not all look like the same room. Just do not put it on the guarantee side of
the ledger.

---

## 5. Point processes: where the real guarantees are

This is the section that pays. Everything above shapes a *field*; everything here
places *points*, and point placement is where minimum-distance invariants live.

### 5.1–5.2 Worley / cellular noise

Steven Worley, *A Cellular Texture Basis Function*, SIGGRAPH '96, 291–294
(https://dl.acm.org/doi/10.1145/237170.237267).

Scatter feature points by a Poisson process (in practice: a hash-seeded random
count and positions per grid cell, so evaluation only touches the 3×3
neighbourhood in 2D). For a sample point, sort the distances to nearby feature
points and return a function of them:

| Basis | Value | Appearance |
|---|---|---|
| **F1** | distance to nearest feature point | Cones/blobs; thresholding low gives discs around each point |
| **F2** | distance to 2nd nearest | Similar, offset |
| **F2 − F1** | 0 exactly on the Voronoi boundary, rising inward | **Voronoi cell edges — a connected crack network** |

Distance metric matters. Worley's paper names exactly two alternatives to
Euclidean, and it is worth quoting him because the usual "Euclidean / Manhattan /
Chebyshev" recital is **wrong about the third** — Chebyshev and general Minkowski
variants are later folklore added by libnoise/FastNoiseLite/Blender, not Worley:

> Using the Manhattan distance metric forms regions that are rigidly rectangular,
> but still random. These make surfaces like random right angle channels; useful
> for space ship hulls.

**Manhattan is exactly the metric we must not use** (§2.4): "rigidly rectangular"
regions produce axis-aligned wall runs, straight into the horizontal sightline
validator. Note also that our `shapeDiamond` primitive is already an L1 disc, so
we ship the L1 blob and should keep it as *cover*, not as a *cell metric*.

Two more facts from the paper worth having:

- **Cost.** "Simultaneously computing F1 and F2 requires about the same amount of
  time as computing one scale of Perlin's noise." The 3×3(×3) neighbourhood is
  pruned against the current best distance, so "typically, only 1–3 cubes
  actually need to be tested". Cellular noise is *not* expensive.
- **The isotropy claim is empirical, not structural.** Worley clamps the
  per-cell point count to [1, 9] for efficiency and says so plainly: "This cutoff
  in theory breaks some of the isotropy of the distribution of feature points, but
  in practice we see no visual consequence… We lost some isotropy with the
  decision to forbid empty cubes." Since forbidding empty cells is what our
  jittered-grid scatter also does, this is the same latent grid signature we
  already carry. Flag it as (B)-at-best on isotropy, not (A).
- The gradient of `Fn` is free: "simply the unit direction vector from the nth
  closest feature point to x" — no finite differencing. Useful if we ever want to
  offset or thicken a cellular contour.

**F1 is (C)** and lands in the same convexity trap as our existing scatter
(§12.1): thresholded F1 is literally a union of discs.

**F2 − F1 is (B) and interesting.** Its low-value set is the Voronoi edge
network: thin, connected, and it partitions the plane into cells. That is
architecture, not scatter. Two caveats before getting excited:

- Voronoi edges meet at **degree-3 vertices** and the cells are **convex
  polygons**, so a Voronoi-wall map is a map of convex rooms with corridors along
  the edges. Convex rooms are fine for `interiorFrac` (a room is a hole in the
  wall set regardless of its convexity — §12.1's proposition is about *obstacles*,
  not *rooms*).
- The wall network is **fully connected**, so without door-punching the cells are
  sealed. Unlike §6.4 the arrangement graph here is **not** a tree — Voronoi cell
  adjacency in the plane is a planar graph with cycles — so "one door per wall
  segment" massively over-connects, and "one door per cell" does not obviously
  connect. You need an explicit spanning-tree door pass (which is exactly
  `genMaze`'s recursive backtracker, run on the Delaunay dual instead of a
  lattice). That is a real and well-trodden design (the Delaunay triangulation is
  the dual graph and hands you the adjacency for free), but it is a *graph*
  algorithm carrying the guarantee, not the noise.

### 5.3 Poisson-disk sampling, and the guarantee it actually gives

Robert Bridson, *Fast Poisson Disk Sampling in Arbitrary Dimensions*, SIGGRAPH
2007 sketches: https://www.cs.ubc.ca/~rbridson/docs/bridson-siggraph07-poissondisk.pdf

Algorithm, in three lines: keep a background grid with cell size `r/sqrt(n)` (so
each cell holds at most one sample); keep an *active list*; repeatedly pick a
random active sample, throw `k` candidate darts into the annulus `[r, 2r]` around
it, accept the first that is ≥ `r` from every existing sample (checkable in O(1)
via the grid), and deactivate the sample if all `k` fail. `k = 30` is the usual
value. **O(N)** total.

**(A) HARD GUARANTEE — minimum separation.** No two output samples are closer
than `r`. This is not probabilistic and not asymptotic: it is enforced by the
rejection test on every single accepted sample. If the test is correct, the
invariant holds for every seed, every parameter, every run. This is the strongest
unconditional guarantee anywhere in my dimension.

One implementation caveat that turns the invariant back into a bug, and is worth
writing into the code as a comment: **the guarantee is carried by the rejection
test, and the background grid is only an accelerator.** With cell size `r/sqrt(n)`
you must scan every cell within distance `r`, which in 2D is a 5×5 block. A
hard-coded 3×3 scan silently misses conflicts and you lose the invariant without
any symptom you would notice on a screenshot.

**What Bridson does NOT guarantee, stated plainly:**

- **Not maximality.** With finite `k`, a void can survive simply because all `k`
  darts from every neighbouring active sample happened to miss it — and once a
  sample is popped off the active list it is never revisited. The per-void failure
  probability is bounded away from zero for any finite `k` and there are Θ(N)
  chances to fail, so **the expected number of surviving voids grows with N**.
  Bridson gives a *separated* set, not a *maximal* one, and therefore **no upper
  bound on hole size.** The paper itself never claims maximality; the word appears
  only in its description of Dunbar & Humphreys.
- **Not an unbiased Poisson-disk distribution.** Ebeida et al. 2011 name Bridson
  explicitly: *"This class of methods improves efficiency by computing samples on
  the fly [Mitchell 1987; Jones 2006; Dunbar and Humphreys 2006; Bridson 2007].
  However, these methods are biased."* The mechanism: candidates are drawn from
  the annulus around *one randomly chosen active sample*, so the density of the
  next accepted sample is proportional to how many active annuli cover a region,
  not to that region's uncovered area. For cover placement this does not matter;
  for the *distribution* claims people make about Bridson output, it does.
- **It is not even especially good at what it does.** The sharpest critique
  (Kunimune, *Stop using Bridson's algorithm!*, 2025,
  https://kunimune.blog/2025/06/29/stop-using-bridsons-algorithm/) points out that
  the annulus trick is fundamentally dart-throwing with heavily overlapping
  regions, and benchmarks it as performing *"similarly to dart-throwing (slightly
  worse, in fact)"* near the ~0.69 jammed packing density. **Grid-accelerated
  plain dart throwing is linear-time, simpler, and just as good.** If we adopt
  this, adopt the simple version: uniform grid of cell side `r/sqrt(2)` (so each
  cell holds at most one sample), throw darts into randomly chosen still-valid
  cells, retire cells that become fully covered. Same hard guarantee, less code.

### 5.4 The corollary that matters: separation ⇒ connectivity

**(A) HARD GUARANTEE — floor connectivity and absence of sealed pockets.**

*Claim.* Place one convex obstacle of circumradius `R` at each Poisson-disk sample
with separation `r`. If `r > 2R`, the obstacle set is a **disjoint** union of
convex bodies, and the complement of finitely many disjoint convex bodies in a
rectangle is connected. Therefore the floor is connected and there are no sealed
pockets — for every seed, with no flood-fill check.

*Proof.* Two obstacles with circumcentres at distance `d ≥ r > 2R` cannot
intersect, since each is contained in a disc of radius `R` about its centre and
`2R < d`. A finite disjoint family of compact convex sets in the plane does not
separate the plane (each is simply connected and they share no boundary), so the
complement is connected. ∎

*Strengthening to a corridor width.* If `r ≥ 2R + w`, then the narrowest passage
between any two obstacles is at least `w`. Setting `w = RecommendedCorridorWidthPx
= 68` gives:

```
r  >=  2*R + 68
```

as a **compile-time assertable** relationship between the obstacle radius knob and
the separation knob. Every corridor between two pieces of scatter cover is then
≥ 68 px wide, by construction, on every map we ever generate.

This is the cheapest real win in the document, and it is about twenty lines of
code.

### 5.5 Our current `genScatter` has no such guarantee — and can violate it

Concretely (`mapgen_styles.nim:155-175`, defaults at `:48-51`):

```
period = 120, jitter = 40, clusterMin = 1, clusterMax = 2, radMin = 16, radMax = 32
```

Each grid cell rolls `prob = 0.45`, then emits **1–2 discs, each independently
jittered by ±40 px**. So:

- Two discs drawn for the **same cell** are jittered independently and can land
  arbitrarily close — including coincident. There is **no** intra-cell separation
  at all.
- Two discs in **adjacent cells** have centres `120 ± 80` apart, i.e. as close as
  **40 px**. With radii up to 32 each, they overlap whenever the centre distance
  is under 64 px. Overlap is therefore common, not exceptional.

Overlapping discs merge into non-convex composite blobs, which is why the current
scatter is not *quite* as bad on `interiorFrac` as pure disjoint discs would be —
but they merge *uncontrolledly*, and a chain of merged discs is exactly the "long
wall we did not intend" failure mode. There is no bound on the length of such a
chain.

**Recommended replacement, no new concepts required:** keep every downstream
behaviour, replace the placement loop with Bridson at `r = 2*radMax + 68 = 132`
(against the current effective period of 120 — so the *density is essentially
unchanged*), and assert the relation. This is a strictly-tighter distribution
*and* a new hard guarantee, at no cost in map density.

### 5.6 Maximal Poisson-disk sampling, and the r-net theorem

Ebeida, Patney, Mitchell, Davidson, Knupp, Owens, *Efficient Maximal Poisson-Disk
Sampling*, SIGGRAPH 2011 / ACM TOG 30(4)
(https://anjulpatney.com/docs/papers/2011_Ebeida_EMP.pdf); and Ebeida, Mitchell,
Patney, Davidson, Owens, *A Simple Algorithm for Maximal Poisson-Disk Sampling in
High Dimensions*, CGF 31(2), Eurographics 2012
(https://www.sandia.gov/files/samitch/files/eurographics_mps-final-with-appendix.pdf).
These give **provably maximal** and **provably unbiased** sampling, which Bridson
does not. Their three conditions, which are the right vocabulary for this whole
document:

```
bias-free:   P(x_i in Omega) = Area(Omega) / Area(D_{i-1})   for Omega in the uncovered region
empty disk:  ||x_i - x_j|| >= r                              for all i != j
maximal:     for all x in D, exists x_i with ||x - x_i|| < r
```

Their own framing of the state of the art is worth quoting because it is the
cleanest statement of why maximality is rare: *"To our knowledge, all prior
methods relax the unbiased or maximal conditions, or require potentially unbounded
time or space."* Cost: `E[O(n log n)]` time, `O(n)` deterministic memory (2011);
the 2012 follow-up is `O(n)/O(n)` and maximal "up to round-off error".

Maximality matters because of a clean piece of metric geometry:

> **Theorem (r-net / Delone set).** If `S` is a *maximal* `r`-separated subset of
> a metric space `X` — i.e. no point of `X` can be added while keeping all
> pairwise distances ≥ `r` — then `S` is `r`-**covering**: every point of `X` is
> within `r` of some point of `S`.
>
> *Proof.* If some `x ∈ X` were at distance ≥ `r` from every point of `S`, then
> `S ∪ {x}` would still be `r`-separated and strictly larger, contradicting
> maximality. ∎

**Mind the convention** — this is the one place a factor of 2 sneaks in and the
folklore version of the theorem is stated in the other one. Under the
**separation** convention (centres ≥ `r` apart, which is Bridson's and Ebeida's
`r`) maximality gives covering radius **< r**, same constant. Under the
**packing** convention (open discs of radius `r` pairwise disjoint, i.e. centres
≥ `2r`) it gives covering radius **≤ 2r**. Same theorem; say which one you are in.
Everything in this document uses the separation convention. Standard reference:
Vershynin, *High-Dimensional Probability* §4.2, and
https://en.wikipedia.org/wiki/Delone_set.

So maximality is **(A) for a maximum-void bound**: no disc of radius `r` anywhere
in the region is empty of samples. In map terms that is *"no region of the board
larger than `r` is featureless"* — a direct, constructive bound on **dead
floor**, which `MapPlay.deadFloorFrac` and `biggestDeadPx`
(`map_metrics.nim:204-205`) measure and which nothing in our generator currently
controls.

**A free corollary that is worth more than it looks.** An `r`-separated,
`r`-covering point set has the property that every Delaunay circumcircle has
radius `R < r` (else its centre would be uncovered) while every Delaunay edge has
length `e ≥ r`. So `R/e < 1`, and since `sin(theta_min) = e/(2R) > 1/2`, **every
triangle in the Delaunay triangulation of a maximal Poisson-disk set has minimum
angle > 30°.** If we ever build a room/lane graph on the Delaunay dual of the
sample set (§5.2, §14), maximality hands us a well-shaped triangulation with no
slivers, for free. Bridson's output has no such property.

**Variable-radius MPS decouples the two knobs.** Mitchell, Rand, Ebeida, Bajaj,
*Variable Radii Poisson-Disk Sampling*
(https://www.sandia.gov/files/samitch/files/VarRadiusPoissonDiskCCCG-bw2.pdf) makes
the **inhibition** radius (min spacing) independent of the **coverage** radius
(max gap). For us that is exactly right: min spacing is set by the corridor
budget (`2R + 68`) and max gap is set by the dead-floor budget, and they have no
reason to be the same number.

Combining §5.4 and §5.6: **a maximal Poisson-disk set with `2R + 68 ≤ r` gives
you, simultaneously and unconditionally, a minimum corridor width of 68 px, a
maximum featureless void of radius `r`, connected floor, and no sealed pockets.**
Four properties, one construction, zero retries. That is the best guarantee
bundle in this survey, and its weakness is §12: it is still a scatter generator,
so it still cannot make rooms. Which is exactly why the recommendation in §14 is
to run it on **compound footprints** rather than on individual obstacles.

### 5.7 Jittered / stratified grids — the free 80%

**(A) HARD GUARANTEE — one sample per cell, and min separation ≥ `period − 2·jitter`
between samples in different cells** (adjacent-cell centres differ by `period`
along an axis; each moves at most `jitter`).

This is nearly free and is what `genScatter` is *trying* to be. It is weaker than
Poisson-disk (samples in diagonal cells can be closer; the bound only binds
axis-adjacent cells if you are careless about it) but it also gives the covering
bound for free — every cell has a sample, so no void exceeds a cell diagonal.

The fix to `genScatter` in §5.5 could equally be "emit exactly one disc per cell
and set `jitter ≤ (period − 2·radMax − 68)/2`", which for `period = 120,
radMax = 32` gives `jitter ≤ −6` — i.e. **the current parameters are infeasible**
and the period must rise to at least `2·32 + 68 = 132` before any jitter is
affordable. That falls out of the arithmetic, and it is a good example of why
writing the guarantee down as an inequality is worth doing even when you then
choose Poisson-disk instead.

### 5.8 Lloyd relaxation / centroidal Voronoi tessellation

Iterate: compute the Voronoi diagram of the sites, move each site to its cell's
centroid, repeat. Converges to a **centroidal Voronoi tessellation**, where each
site *is* its cell's centroid. Amit Patel's *Polygonal Map Generation for Games*
(http://www-cs-students.stanford.edu/~amitp/game-programming/polygon-map-generation/)
uses exactly this, and it is the best-known worked example of Voronoi map
generation in the games literature — worth reading for the *pipeline shape* even
though its terrain model (islands, biomes, rivers) is not ours.

**Classification: (B), and I want to be precise about why it is not (A).** A CVT
is a **critical point** of the quantisation energy `F = sum_i integral_{V_i}
rho(x)|x - z_i|^2 dx` — a *necessary* condition for optimality, not a sufficient
one. Lloyd is the continuous analogue of k-means and inherits its local-optimum
caveat; convergence is proven in 1D and only weaker results are known in higher
dimensions (Du, Emelianenko & Ju, *Convergence of the Lloyd Algorithm for
Computing Centroidal Voronoi Tessellations*, SIAM J. Numer. Anal. 44(1), 2006,
https://math.gmu.edu/~memelian/pubs/pdfs/DEJ_SIAM_lloyd.pdf; foundational survey
Du, Faber & Gunzburger, SIAM Review 41(4):637–676, 1999).

**Lloyd guarantees nothing about cell-size uniformity.** No lower bound on
inter-site distance, no upper bound on cell area, no iteration bound to reach a
given regularity. It monotonically decreases an energy. The crisp asymptotic
statement people are reaching for is **Gersho's conjecture** — that the
*energy-minimising* CVT is asymptotically a tiling by congruent copies of one cell
— which is **proven in 2D (the regular hexagon; Fejes Tóth 1959)** and open in 3D
and above. That is a statement about the global optimum, not about the iterate.
So "Lloyd makes the cells hexagonal" is conjecture-adjacent folklore about
something Lloyd does not compute.

Worse for us: **Lloyd moves points, so it can destroy a min-separation guarantee
you already had.** If you want both, relax and *then* re-run the separation
filter, and credit the filter.

The strongest evidence here is that the canonical practitioner abandoned it.
Amit Patel used two Lloyd iterations in the original polygon-map-generation work
and later wrote: *"In newer projects I use a Poisson Disc algorithm, which
generates a nice distribution of points from the start, without iterating through
multiple steps of Lloyd relaxation."* Constructive sampler beats improvement
heuristic — which is the thesis of this entire document, arrived at independently.

**What the Delaunay dual gives you for free** (all proven, all useful if we build
a room graph on the sample set): it is a connected planar graph, so Euler bounds
it at ≤ `3n − 6` edges and ≤ `2n − 5` triangles — a hard ceiling on the
connectivity budget; it **maximises the minimum angle** over all triangulations of
the point set; it **contains the Euclidean minimum spanning tree** as a subgraph
(and the nearest-neighbour, relative-neighbourhood and Gabriel graphs, nested);
and it is a `t`-spanner with `t < 1.998`, which bounds `detourMax`
(band `[1.10, 1.90]`, `map_metrics.nim:1354`) *structurally* if routes follow
Delaunay edges. Construction is `O(n log n)`. Reference: Fortune, *Voronoi Diagrams
and Delaunay Triangulations*, Handbook of Discrete and Computational Geometry
ch. 27, https://www.csun.edu/~ctoth/Handbook/chap27.pdf.

### 5.9 Low-discrepancy sequences (R2, Sobol, Halton)

Martin Roberts, *The Unreasonable Effectiveness of Quasirandom Sequences*
(http://extremelearning.com.au/unreasonable-effectiveness-of-quasirandom-sequences/)
popularised the **R2 sequence**: the 2D generalisation of the golden-ratio
sequence, `p_n = frac(n * (1/phi2, 1/phi2^2))` where `phi2 ≈ 1.324718` is the
plastic number (real root of `x³ = x + 1`).

Its attractions for us are real: **stateless, O(1) per sample, seekable, and
deterministic** — you can ask for "the 47th cover position" without generating the
first 46, which is a genuinely nice property for a seed-reproducible generator.

**Classification: (B). Do not write "provable minimum separation" for R2.** This
was chased hard and the honest picture is:

- **In 1D, there is a genuine separation theorem.** The three-distance (Steinhaus
  / Sós / Świerczkowski) theorem says `{alpha, 2alpha, …, N alpha} mod 1` cuts the
  circle into gaps of **at most three distinct lengths**; combined with the golden
  ratio being the extremal badly-approximable number (all continued-fraction
  partial quotients 1), the minimum gap is `Theta(1/N)` with an explicit constant.
  Recent formalisation: *One-dimensional quasi-uniform Kronecker sequences*,
  Archiv der Mathematik, 2024,
  https://link.springer.com/article/10.1007/s00013-024-02039-0.
- **In 2D the analogous result is a bound on the number of distances, not on
  their size.** Haynes & Marklof, *A five distance theorem for Kronecker
  sequences* (https://arxiv.org/abs/2009.08444, IMRN 2022): at most **five**
  nearest-neighbour distances arise, for all `alpha` and `N`, and five is sharp.
  That constrains the *structure* of the gap spectrum and says nothing about how
  small the smallest gap is.
- **The reduction is clean and worth stating.** For a Kronecker sequence the
  distance between points `n` and `m` is `||(n-m) alpha||`, so a min-separation
  bound over `N` points is *exactly equivalent* to `alpha` being **badly
  approximable**: `|n alpha - l|_inf > c * n^(-1/d)`. Badly approximable ⟹
  min separation ≥ `c * N^(-1/2)` in 2D — the `1/sqrt(N)` decay people quote.
- **Whether the specific plastic-number vector `(1/rho, 1/rho^2)` is badly
  approximable appears to be OPEN.** The 1D literature is discouraging on
  explicit algebraic constructions (it is a well-known open problem whether any
  algebraic irrational of degree ≥ 3 is badly approximable, with the common
  conjecture being that none are), and the simultaneous `d = 2` question for a
  cubic-field vector is deeper still. **Roberts' minimum-distance figures for R2
  are empirical measurements over finite `N`, not a theorem.**

One important thing that *is* a guarantee and is easy to conflate with the
above: Roberts' **grid-based** blue-noise construction states a minimum neighbour
separation of `0.707/n`. That guarantee comes from the underlying **lattice**,
i.e. it is the stratification argument of §5.7 again — not a property of the plain
R2 sequence. Do not merge the two claims.

**Practical conclusion:** if you want the separation guarantee, use dart-throwing
or Bridson, where it is enforced by a rejection test you can read, and needs no
number theory at all. When in doubt, prefer the guarantee you can see in the code
over the one you have to look up.

### 5.10 The rest of the blue-noise zoo, and their (lack of) guarantees

Two entries are worth a line each because they are commonly recommended and
neither carries the guarantee people assume:

- **Mitchell's best-candidate (1991)** — *Spectrally Optimal Sampling for
  Distribution Ray Tracing*, SIGGRAPH '91, 157–164
  (https://my.eng.utah.edu/~cs6965/papers/p157-mitchell.pdf). Generate `mn`
  candidates for the `(n+1)`-th sample and keep the one whose nearest existing
  neighbour is furthest. Spectrally excellent, `O(n^2)`, and **no separation
  guarantee at all** — the author says so himself: *"This point process is not
  strictly hard-disk, because it is possible (although unlikely) for samples to
  lie very close together."* For us, "unlikely" is the wrong word: we generate
  thousands of maps and "unlikely" means "eventually ships".
- **Void-and-cluster (Ulichney 1993)** — no separation or coverage bound (it is a
  greedy swap heuristic), but it has a structural property nothing else here has:
  **the output is a *ranking*, so thresholding it at any level yields a blue-noise
  point set at that density, and the sets are nested.** That is exactly what our
  density-mode roll wants: one precomputed order, and "sparse / medium / dense"
  becomes a prefix of it, with the sparse map's cover being a subset of the dense
  map's. Author's PDF: https://cv.ulichney.com/papers/1993-void-cluster.pdf.

**A terminology caveat to carry into any discussion of this.** "Blue noise" in
graphics is a family resemblance — low DC energy, no spectral spikes, an isotropic
ring — not the literal signal-processing definition (power density rising 3 dB per
octave). The standard measurement apparatus is **two** numbers, from Ulichney,
*Dithering with Blue Noise*, Proc. IEEE 76(1):56–79, 1988: the **radially averaged
power spectral density** and the **anisotropy** (the variance over each frequency
ring, normalised by the ring mean). The second one is the one that detects
residual lattice regularity, and it is the one nobody plots.

---

## 6. From scalar field to geometry — where the headline finding lives

### 6.1 The two ways to turn a field into walls

Given a scalar field `f` and a level `u`, there are exactly two things you can
build:

| | Object | Topology at our cover budget | Class |
|---|---|---|---|
| **Fill** | the **excursion set** `{f >= u}` | disjoint blobs, no holes (§12.2) | **(C)** |
| **Trace** | the **level curve** `{f = u}`, thickened | closed rings, hole-rich by construction | **(A)** for connectivity (§6.4) |

Nearly every "Perlin cave generator" on the internet does *fill*. **Fill is the
wrong operator for us**, and §12 proves it rather than asserting it. Everything
below is about *trace*.

### 6.2 Thresholding, and the one (A) it can carry

Covered in §11.5, restated here for the section's completeness: threshold by the
**empirical quantile** of the sampled field, not by a fixed value. Sorting the
raster values and taking the order statistic at the target fraction makes the
pre-carve wall fraction *exactly* the target on every seed, with no distributional
assumption. **(A) for cover fraction.** Six lines of code, and it retires
`CoverPermilleMin`/`Max` as a source of rejections.

### 6.3 Hysteresis thresholding (double threshold)

Borrowed from Canny edge detection: use two levels `u_lo < u_hi`; seed the wall
set from `{f >= u_hi}` and then flood-fill outward through `{f >= u_lo}` from
those seeds only. Components that never reach `u_hi` are discarded.

What this buys: **speckle suppression**. A single-threshold field at 15% coverage
produces a long tail of tiny components — sub-corridor fragments that cost shape
count and rasterise into 3-pixel pebbles. Hysteresis removes them without
raising the threshold globally (which would also shrink the features you wanted).

**Classification: (B).** It makes sub-corridor features rarer. It does not bound
them. The bound comes from an explicit morphological step: **open the wall mask
with a disc of radius `MinFeaturePx/2`, and open the floor mask with a disc of
radius `MinCorridorWidth/2`.** Morphological opening `A ∘ B = (A ⊖ B) ⊕ B` has a
genuine property — the result is exactly the union of all translates of `B` that
fit inside `A`, so **every point of the opened set lies in a placed copy of `B`.**
Opening the *floor* with a disc of radius 34 px therefore guarantees that every
remaining floor pixel is in a 68 px-diameter free disc, i.e. **(A) for local
corridor width** — at the cost of possibly disconnecting the floor, which is why
it must be followed by the connectivity step, not replace it.

Note we already do the erode-then-flood pattern: `arena.nim` computes a chamfer
3-4 distance transform, erodes by half the corridor minimum, and flood-fills
(`arena.nim:2245-2250`). So the primitive exists; it is used as a *validator*, and
the proposal here is to also use it as a *constructor*.

### 6.4 Marching squares, and the contour-tree theorem — THE FINDING

**Marching squares** is the 2D case of Lorensen & Cline's marching cubes
(*Marching Cubes: A High Resolution 3D Surface Construction Algorithm*, SIGGRAPH
'87, https://dl.acm.org/doi/10.1145/37401.37422). For each 2×2 cell of the sampled
field, the four corners' sign relative to `u` give a 4-bit index into 16 cases;
each case emits 0, 1, or 2 line segments, with the endpoints placed on the cell
edges by **linear interpolation** of the field values (which recovers sub-cell
accuracy and is what makes the contour smooth rather than staircased).

Two of the 16 cases (`0101` and `1010`) are **ambiguous saddles** — the two
diagonal corners above the level could be joined or separated. The **asymptotic
decider** (Nielson & Hamann, *The Asymptotic Decider: Resolving the Ambiguity in
Marching Cubes*, IEEE Visualization '91) resolves it by evaluating the bilinear
interpolant at its own saddle point:

```
f_saddle = (f00*f11 - f10*f01) / (f00 + f11 - f10 - f01)
```

If `f_saddle` falls on the same side of the isovalue as the two diagonal corners,
those corners are **connected**; otherwise they are **separated**. (The folklore
"average the four corners" shortcut agrees with this only when the cell is square
*and* the denominator is positive — it is not the asymptotic decider and it can
differ.)

> **(A) HARD GUARANTEE — output topology, and it is stronger in 2D than in 3D.**
> Marching squares emits a set of **closed, simple (non-self-intersecting),
> pairwise-disjoint polygonal loops** — and in 2D this holds under **any**
> per-cell resolution of the saddle cases, even a random one.
>
> *Proof.* An edge with a strict sign change contains exactly one interpolated
> crossing; none otherwise. Walking a cell's four edges cyclically, the number of
> sign changes is even (parity of a cyclic ±1 sequence). The lookup table pairs
> the crossings so that each is an endpoint of exactly one segment within that
> cell. Each interior grid edge belongs to exactly two cells, so every crossing
> vertex has degree exactly 2 — a closed 1-manifold, i.e. a disjoint union of
> simple closed polygons. Non-self-intersection: both saddle pairings are
> non-crossing chords inside the cell, segments never leave their cell, and cells
> have disjoint interiors. ∎

**Why 2D is the easy case, and it is worth understanding why.** In 2D the
ambiguity is *entirely internal to a cell*: two adjacent cells share an **edge**,
and both the existence and the position of the crossing on that edge depend only
on the two endpoint samples. Neighbours physically cannot disagree, so **marching
squares cannot produce cracks.** In 3D the ambiguity lives on a shared **face**,
which is exactly why Dürst's 1988 correction to the Lorensen–Cline table exists
and why the asymptotic decider matters there. For us, the decider changes *which*
loops we get (joined vs split rooms) — a design choice, not a correctness one.

Three caveats to carry into a validator:

- **Ties.** If a sample equals the isovalue exactly, the sign is undefined. Pick
  "above" or "below" and be consistent; integer fields make this a live concern.
- **Border edges belong to one cell only**, so they yield degree-1 vertices —
  **open arcs, not loops**. Sample the field on a frame one cell larger than the
  map and force the outer ring below `u`. One line, and it makes every contour
  interior and closed.
- **Closed ≠ faithful.** A feature smaller than a cell is silently dropped. The
  guarantee is about the output polyline, not about fidelity to the continuous
  field. That is fine for us — a sub-cell feature is a sub-corridor feature and we
  did not want it.

One more precision point, because it interacts with the theorem below: the *true*
level set through a saddle of `f` is a **figure-eight** — it self-intersects, so
it is not a disjoint union of simple curves. Marching squares resolves that into
two disjoint arcs. **The nesting-tree theorem therefore applies to the marching-
squares output, not to the ideal level set.** That is the version we ship, so the
guarantee is the one we need, but do not state it about the continuous field.

Now the theorem this document is built on.

> **Theorem (contour nesting tree).** Let `C_1, …, C_m` be pairwise disjoint
> simple closed curves in a simply connected region `D`. Then `D \ union(C_i)` has
> exactly `m + 1` connected faces, and the face-adjacency graph — one node per
> face, one edge per curve, joining the two faces that curve separates — is a
> **tree**.
>
> *Proof.* By the Jordan curve theorem each `C_i` bounds a closed disc `D_i`.
> Pairwise disjointness forces, for every `i != j`, exactly one of
> `D_i ⊂ int D_j`, `D_j ⊂ int D_i`, or `D_i ∩ D_j = ∅`. A family closed under
> that trichotomy is **laminar**, and a laminar family ordered by containment is a
> forest; adding `D` itself as a root makes it a tree with `m + 1` nodes. The
> faces are exactly "`D_i` minus its children" (and the root's face is `D` minus
> its top-level discs), and two faces are adjacent iff their nodes are
> parent-and-child. `m + 1` nodes, `m` edges, connected ⟹ tree. ∎

**The construction that follows, and its guarantee:**

1. Extract the contours of `f` at level `u` with marching squares. By the (A)
   above they are disjoint closed simple loops, so by the theorem they induce a
   **tree** of faces.
2. Thicken each loop into a **ribbon of wall** of thickness `t`.
3. Punch `d_i >= 1` **doors** of width ≥ `RecommendedCorridorWidthPx` in loop `i`.

> **(A) HARD GUARANTEE — floor connectivity.** With `d_i >= 1` for every curve,
> every tree edge is realised, so the `m + 1` faces are connected. **The floor is
> connected by construction.** No flood fill, no repair pass, no retry.

### 6.4a The trap: one door per curve is a DISASTER, and the fix is the best result here

A spanning tree connects everything and *nothing more*. If `d_i = 1` for all `i`,
then between any two faces there is **exactly one** route, every door is a **cut
vertex**, and the map would score:

| Band | Requirement | One-door-per-curve gives |
|---|---|---|
| `routeCountMin` | **≥ 2, `bandHard`** — "a map with one route is a corridor" | **1 — REJECTED** |
| `chokeCount` | ≤ 6 | one per curve — blown |
| `midCrossCount` | ≥ 3 | 1 — blown |
| `chokeCoveredPenalty` | 0 | one camper watches the only door |

So the naive construction fails a **hard** band. This is exactly the trap that
sinks the D8 flow-tree idea in §9.2 as well, and it is worth stating loudly
because "guaranteed connected" sounds like the finish line and is actually the
starting line: **for a competitive map, connectivity is cheap and *redundancy* is
the thing that is hard.**

The fix is one line, and it converts the tree from a liability into the sharpest
control surface in this document:

> **(A) HARD GUARANTEE — exact route capacity.** In the door construction, the
> minimum vertex cut between two faces `F` and `F'` is exactly
> `min over the curves on the tree path from F to F' of d_i`. By Menger's theorem
> the number of vertex-disjoint routes between them equals that cut. Therefore:
>
> ```
> routeCountMin  =  min_i d_i          (over curves separating the two bases)
> ```
>
> **Set `d_i >= 2` for every curve and `routeCountMin >= 2` is satisfied by
> construction — the hard band can never fail.** Set `d_i >= 3` on the curves
> that cross the midfield seam and `midCrossCount >= 3` is satisfied by
> construction too.

And the same statement kills the chokepoint problem for free: **a door is a cut
vertex if and only if it is the only door on its curve.** So `d_i >= 2` for all
`i` gives `chokeCount = 0` from doors — which is exactly the arena's measured
value (`control: 0.0`, `map_metrics.nim:1316`).

This is the strongest thing in the survey. It is not "noise makes route counts
more likely to be good"; it is a **closed-form identity between a generator
parameter and a banded metric**, with the metric's definition (max-flow / min-cut
over a coarse grid, `map_metrics.nim:530`) matching the theorem's. Two caveats to
keep it honest:

- The identity is about the *door graph*. Rasterisation, the protected-floor
  carve, and the endzone apron all edit the mask afterwards; the guarantee is on
  the pre-carve structure and the measured value can only be *reduced* by a carve
  that seals a door. Carves open floor, they do not close it — so in practice the
  measured value should be ≥ the constructed one. Verify rather than assume.
- A door of width 68 px spans ~2.6 cells of `RouteCellPx = 26`, so the measured
  `routeCountMin` will typically exceed `min_i d_i`. The identity is a **lower
  bound** in cell units, which is the direction we want.

And simultaneously, from the same object:

> **(A)-adjacent — `interiorFrac` structure.** A thickened closed loop is a
> **ring**, and every point inside a ring of inner diameter ≤ 240 px has all 8
> directions blocked within 120 px. §12.3 works the numbers: at wavelength ~275 px,
> excursion fraction 0.35, ribbon 20 px, the model predicts `interiorFrac ≈ 0.32`
> at 150 permille cover — inside both bands, against a pool median of 0.118.

### 6.4b The deeper problem the identity does NOT fix — and the construction that does

Reconciling with the sibling surveys (`docs/research/mapgen-partition-geometry.md`
§7 and `docs/research/mapgen-constructive.md` §4.6) forced me to look harder at my
own result, and it has a flaw the metric cannot see. Stating it against myself
before anyone else does:

**`routeCountMin = min_i d_i` is a statement about the PIXEL min-cut. The room
graph is still a tree.** Three doors in one wall give three vertex-disjoint
*corridors* and the metric will happily read 3 — but every route visits **the same
rooms in the same order**, and all three doors are on one wall, so **one defender
standing back from that wall watches all of them.** That very likely trips
`chokeCoveredPenalty` ("ONE 1050 px isovist watches every chokepoint"), and more
to the point it is the map being a corridor while the number says otherwise. Our
own generator history is that the validators pass 96% of first attempts — they are
a crash guard, not a filter. **My identity would have been metric-gaming.**

The siblings' answer is structurally right and I adopt it: **do not open a tree,
close a triangulation.** Every plane triangulation with `n >= 4` vertices is
**3-connected**, so by Menger there are 3 vertex-disjoint paths between *every*
pair of nodes; start from the Delaunay/Voronoi partition with all doorways open
(3-connected) and close doorways only while the check still passes. That delivers
redundancy at the **room** level, which is the thing that matters.

But that is a *partition* construction, and nesting contours are inherently a
*hierarchy* — closed curves nest, they cannot form cycles. So rather than bolt a
partition onto §6.4, there is a one-line change to the contour construction that
dissolves the problem entirely:

> **Cut the rings. Thicken ARCS, not loops.**

Thicken only a contiguous **arc** of each extracted contour — 270° to 340° of the
loop — and discard the rest. A thickened simple arc is homeomorphic to a **closed
disc**: simply connected, and it does not separate the plane. Then:

> **(A) HARD GUARANTEE — connectivity, with no doors at all.** If every wall
> component is a thickened simple arc, components are pairwise disjoint, and none
> touches the map border, then the wall set is a finite disjoint union of closed
> topological discs, and the complement of such a union in a rectangle is
> connected. **The floor is connected, there are no sealed pockets, and no wall is
> a cut set — so `chokeCount` from walls is 0**, matching the arena's control of 0.
> This is the *same one-line proof* as §5.4, now applied to concave pieces instead
> of convex ones. Everything §5.4 gives scatter, arcs give too.

> **(A) HARD GUARANTEE — route capacity.** Enforce a minimum gap `g` between any
> two wall components and between any component and the border (a distance-
> transform check, or Poisson-disk on the arc centres). Any cut separating the two
> bases must cross at least one gap, and a gap of width `g` costs
> `floor(g / RouteCellPx)` cells. So **`routeCountMin >= floor(g / 26)` by
> construction.** Set `g = 78` (3 cells, comfortably above
> `RecommendedCorridorWidthPx = 68`) and the hard band `routeCountMin >= 2` cannot
> fail, with a full cell of margin.

> **(A)-adjacent — `interiorFrac`, with an exact design rule.** An arc spanning
> angle `theta` blocks about `8 * theta / 360` of the 8 probe directions from its
> centre. `InteriorBlockedMin = 6` therefore lands at **`theta >= 270°`** — the
> threshold at `map_metrics.nim:81` is *literally* a three-quarter horseshoe.
> **Keep at least 270° of every contour; cut at most 90° out.** The pocket inside
> the C counts as interior floor provided the arc's inner radius is
> ≤ `EnclosureReachPx = 120 px`.

The mouth of the C **is** the door, and it costs nothing: no door-punching pass,
no distance-transform door siting, no laminar-family repair bookkeeping. The cut
angle is a per-ring RNG draw, lifted by the orbit so every team's rooms have their
mouths in matching places. A horseshoe bunker with an open mouth is also a
thoroughly conventional FPS map element, so the output should read as designed
rather than as generated.

**What is lost:** the contour-nesting-tree theorem no longer does any work,
because there is no tree — which is the point. Keep §6.4/§6.4a in the document as
the reason the *loop* version fails, not as the recommendation. And leave
room-level redundancy where the siblings put it: at the **partition** layer
(Voronoi cells, Delaunay 3-connectivity), with contour arcs placed *inside* the
cells as the concave cover. **The two dimensions compose exactly there** — their
partition gives the lane network and the route redundancy; my arcs give the
enclosed pockets that a convex-blob generator provably cannot (§12.1).

**The failure modes, and the repair that PRESERVES the guarantee.** This is the
part that makes it engineering rather than a nice theorem:

| Failure | Detection | Repair |
|---|---|---|
| Two contours closer than `t` — ribbons merge, faces vanish | distance transform between contours < `t` | **delete one of the two curves** |
| A face too thin to walk after thickening | max of the floor distance transform inside the face < 34 px | **delete the curve bounding that face** |
| Fewer than `d_i` legal door sites (≥ 68 px clearance both sides, mutually separated) | scan the contour's distance transform | **delete the curve** |

All three repairs are the *same* repair: remove a curve. **Removing a leaf or an
internal node from a laminar family leaves it laminar** (contract the tree edge;
the node's children reattach to its parent). So the tree structure — and therefore
the connectivity guarantee — survives every repair. That is a rare property: a
repair pass that cannot invalidate the invariant it is repairing under.

**Door placement, concretely.** Compute the distance transform of the *floor*
(pre-thickening). Walk the contour scoring each vertex by
`min(clearance inside, clearance outside)`; that is the widest point of the wall,
where the door has the most margin over 68 px. Then pick the `d_i` best sites
**subject to a minimum arc separation** (say a quarter of the contour's
perimeter), so two doors never land next to each other and collapse back into one
effective route. Ties broken by the RNG so different seeds place doors
differently. Sites are chosen on the fundamental-domain copy and lifted by the
orbit, so every team's rooms have doors in the same places — fairness for free.

### 6.5 Contour → `shapePolygon`: the concrete emission

Our primitive is a **closed ring of integer vertices** with even-odd fill
(`sim_types.nim:752-759`). A ribbon is an *annulus*, which is not a simple ring.
Three options, in order of how much I like them:

1. **Quad chain (recommended).** Emit one 4-vertex `shapePolygon` per contour
   segment: the two offset points on each side of segment `i`. Adjacent quads
   overlap slightly at the joins (miter them or just let them overlap — the wall
   mask is a union). **The door is simply the quads you do not emit.** Integer
   vertices are natural, symmetry stays bit-exact, and there is no annulus
   problem. Cost: one shape per segment.
2. **Keyhole polygon.** Even-odd fill *can* express an annulus as a single ring
   with a slit joining outer to inner. Fewer shapes, but the slit is a
   degenerate feature that will interact badly with integer rounding and with the
   symmetry mirror. Not worth it.
3. **`shapeDiagonal` chain.** `shapeDiagonal` is `(x0,y0,x1,y1,thickness)`, and
   its uses in `arena.nim` (e.g. `:193-213`) are all at exactly 45°, matching the
   type's own comment ("a 45-degree wall segment"). **Check `inShape` before
   assuming it generalises** — if it does support arbitrary angles it is the
   cheapest possible ribbon representation (one shape per segment, no vertex
   maths).

**Shape budget.** At `L_A ≈ 0.009 px/px²` on a ~1.08M px² standard board, total
contour length is ~9,700 px. At 24 px per segment that is ~400 quads full-board,
~200 in a 2-team fundamental domain. Compare `genCaves`, which emits one 14-vertex
blob per filled CA cell and routinely emits low hundreds. So the budget is
comparable to what we ship — but `mapWallAt` is linear in shape count per pixel
query, so **simplify the contour first** and target ~40–60 px segments, i.e.
~100 shapes per half.

### 6.6 Polygon simplification: RDP, and a condition that makes it safe

**Ramer–Douglas–Peucker** (Ramer 1972; Douglas & Peucker 1973) recursively keeps
the point furthest from the chord and discards everything within tolerance `eps`.
**Visvalingam–Whyatt** (1993) instead repeatedly removes the vertex whose
triangle with its neighbours has the smallest area, which gives perceptually
better results on smooth curves — which ours are.

**Neither preserves simplicity in general**: a simplified polyline can
self-intersect, and can cross a *different* polyline it used to be disjoint from.
This is established, not folklore:

- **Saalfeld, 1999**, *Topologically Consistent Line Simplification with the
  Douglas-Peucker Algorithm*, Cartography and GIS 26(1):7–18 — analyses exactly
  how DP breaks topology and **proves that one extra test in the stopping
  condition** (via a dynamically maintained convex hull) guarantees the simplified
  polyline is topologically consistent with itself and with its neighbours. This
  is the cheapest correct fix and is what to implement if the bound below is ever
  inconvenient.
- **Estkowski & Mitchell, 2001**, *Simplifying a polygonal subdivision while
  keeping it simple*, SoCG '01 — **optimal homotopic simplification with simple
  output is NP-hard**. So there is no cheap optimal algorithm; use a guard, not an
  optimiser.
- **Visvalingam–Whyatt is unproven either way.** Its effective-area criterion
  bounds *local* area change but places no bound on displacement relative to a
  distant part of the curve. Treat it as the same risk class as RDP.

Topology-preserving variants exist (de Berg, van Kreveld & Schirra, 1998,
*Topologically correct subdivision simplification using the bandwidth criterion*),
but they are more machinery than we need, because of this:

> **Conditional (A) — simplification safety.** RDP with tolerance `eps` moves
> every point of the curve by at most `eps`. Therefore if
> `eps < (1/2) * min distance between any two non-adjacent parts of the contour
> family`, the simplified curves remain simple and pairwise disjoint, and the
> nesting tree is unchanged.

And that minimum distance is **something we already compute**: it is the value of
the distance transform, which §6.4's repair pass needs anyway. So set
`eps = min(t/2, halfMinContourGap)` and the simplification is provably safe with
no extra work. If the bound forces `eps` so small that the shape budget blows,
that is the same signal as "two contours are too close" — and the same repair
(delete a curve) fixes both.

### 6.7 Dual contouring and surface nets — not needed in 2D

Ju, Losasso, Schaefer & Warren, *Dual Contouring of Hermite Data*, SIGGRAPH 2002
(https://www.cs.wustl.edu/~taoju/research/dualContour.pdf), places one vertex per
*cell* (minimising a quadratic error function over the cell's Hermite data) rather
than on cell edges, which reproduces **sharp features** — creases and corners —
that marching cubes rounds off. Surface nets are the simpler, non-Hermite cousin.

**Verdict: skip it**, and for a sharper reason than the usual one. In 2D, a dual
vertex has degree equal to the number of sign-changing edges of its cell — 2 for
ordinary cells, but **4 for exactly the saddle cells**. So **2D dual contouring is
non-manifold precisely where marching squares is manifold by construction**, which
is the reverse of the "DC is cleaner" intuition and would cost us the §6.4
guarantee outright. Fixes exist (Manifold Dual Contouring: emit one vertex per
connected component of the cell's contour), but they are extra machinery to buy
back a property we already had for free.

DC also wants the field **gradient** (Hermite data), not just the scalar, and its
QEF minimiser can land outside its own cell and need clamping. Its real payoff is
sharp corners, which is what you want for *rectilinear architecture from a field*
— worth remembering if we ever want a "city" biome generator, and wrong for
organic rooms. Note the ancestor is arguably Gibson's **Constrained Elastic
Surface Nets** (MICCAI/VBC 1998), whose one good idea is the constraint that each
node stays inside its own cell — which is what preserves thin features.

---

## 7. Curl noise, flow fields, and the honest home for noise in a pipeline

### 7.1 In 2D, curl-noise streamlines ARE iso-contours — there is no second technique here

Bridson, Hourihan & Nordenstam, *Curl-Noise for Procedural Fluid Flow*, SIGGRAPH
2007 (https://www.cs.ubc.ca/~rbridson/docs/bridson-siggraph2007-curlnoise.pdf).
Take a potential `psi` and set `v = curl(psi)`. In 2D, with a scalar potential:

```
v = ( d(psi)/dy , -d(psi)/dx )
```

Two facts fall straight out:

- `div v = d2(psi)/dxdy - d2(psi)/dydx = 0` — **divergence-free by
  construction**, which is the whole point of the paper: advected particles never
  bunch up or vanish, because there are no sources or sinks.
- `v · grad(psi) = (d psi/dy)(d psi/dx) - (d psi/dx)(d psi/dy) = 0` — **`psi` is
  constant along every streamline.**

The second one is the finding, and the paper says it in as many words (§2.1):

> *"We recall from fluid dynamics that the potential in 2D may be called the
> 'stream function': its isocontours are the streamlines of the flow."*

**In 2D, the streamlines of curl noise are exactly the level sets of the
potential.** So "trace curl-noise flow lines to lay out lanes" and "extract
iso-contours to lay out walls" are *the same computation on the same object*,
differing only in which levels you pick. There is no second algorithm to build
here, and anyone proposing a streamline tracer alongside a contour extractor is
building the same thing twice. Two honest differences: same *set*, different
*parameterisation* (speed along the curve is `|grad psi|`, which contour
extraction discards); and contour extraction gives you **every** component of a
level set at once, whereas streamline tracing gives you one orbit per seed.

**A third connection worth flagging** because it unifies two "bugs": the level set
through a **saddle** of `psi` self-intersects (a figure-eight), and that is
precisely where `v = 0` (a stagnation point) and precisely where marching squares'
case 5/10 fires. **Our contour-simplicity question and a flow-stall bug have the
same root object.**

**Classification: (C) for us.** Divergence-free is a genuine (A) — Bridson is
explicit that the motivation is that raw Perlin velocity fields *"generally contain
many sinks ('gutters' where particles accumulate)"* — but it is an (A) about a
property of a velocity field that a static map has no use for.

**What IS worth stealing is the boundary handling, and it generalises.** To make
flow follow a solid boundary, Bridson multiplies the potential by a ramp of the
distance field (eqs. 3–4):

```
psi_constrained(x) = ramp( d(x) / d0 ) * psi(x)
ramp(r) = 1 for r >= 1;  (15/8)r - (10/8)r^3 + (3/8)r^5 for -1 < r < 1;  -1 for r <= -1
```

with `d(x)` the distance to the boundary and, his recommendation, `d0 = L` the
noise length scale. His reasoning is the reusable part:

> *"if we want the velocity field to be tangent to the boundary, we need the
> gradient to be perpendicular to the boundary. This happens precisely when the
> boundary is an isocontour of psi."*

Translated out of fluids: **multiplying a field by `ramp(d/d0)` forces any chosen
set to be a level set.** For us that is directly actionable — multiply the map
field by a ramp of the distance to the **endzone apron, the flag ring, and the
spawn pockets**, and the extracted contours will *hug* the protected regions
instead of being generated inside them and then destroyed by the carve. That is
strictly better than the current order of operations, where the generator emits
shapes and `arena.nim` deletes the ones that landed in protected floor.

Bridson's other transferable rule, §2.3: *"modulating the velocity field A(x)v(x)
no longer gives a divergence-free field, modulating the potential… does the
trick."* The general principle — **modulate the potential, never the derived
field** — is the right instinct for any of this, and it is the bridge to the next
subsection, where noise finally gets an honest job.

### 7.2 Designed potential + bounded noise: a converging loop instead of a rejection loop

Everything in §12 says a stationary field cannot produce structure. The fix is not
a better noise function; it is to stop asking noise to be the structure.

```
psi(p) = psi_design(p)  +  eps * noise(p)
```

where `psi_design` is a hand-built, deterministic potential encoding the intended
layout — bumps at the intended room centres, ridges along the intended lanes, a
saddle where the intended crossroads is — and `noise` is fBm, domain-warped,
whatever you like. Then extract contours of `psi` (§6.4).

> **Conditional (A) — the noise cannot break the designed layout.** Level-set
> topology changes only at critical points (Morse theory), and **Morse functions
> are structurally stable**: a sufficiently small C¹ perturbation moves the
> critical points but changes neither their number nor their indices. So for small
> enough `eps`, the contour nesting tree of `psi` is *isomorphic to the nesting
> tree of `psi_design`*. The rooms you designed are the rooms you get; noise only
> decides their exact shape.

The engineering consequence is better than the theorem. The stability threshold is
not analytically convenient, but **you do not need it**, because you can *check*
the conclusion cheaply and exactly: extract the contours, build the nesting tree,
compare it to the design's. If it matches, ship. If it does not, halve `eps` and
retry.

**That loop always terminates** — at `eps = 0` the field *is* the design, so the
trees match trivially — and it converges geometrically. This is categorically
different from generate-and-test: it is not "resample and hope", it is
**"anneal the randomness down until the invariant holds"**, on a monotone
parameter, with a guaranteed fixed point. If you want one sentence for where noise
belongs in an "always good" pipeline, it is this one.

(Practical note: in practice `eps` almost never needs to be reduced, because the
design potential's gradients are large by construction. The loop is insurance,
not a hot path.)

### 7.3 Tensor fields and hyperstreamlines — the only route-first technique in this dimension

Chen, Esch, Wonka, Müller & Zhang, *Interactive Procedural Street Modeling*,
SIGGRAPH 2008 (https://peterwonka.net/Publications/pdfs/2008.SG.Chen.InteractiveProceduralStreetModeling.final.pdf).
Instead of a scalar field, design a **tensor field**; at each point it has two
orthogonal eigenvector directions (major and minor). Trace **hyperstreamlines**
along each, and you get two interleaved, roughly-orthogonal, smoothly curving
families of curves — a road network that bends with the terrain instead of being a
grid.

Why this is the most interesting entry in my dimension for *lanes* specifically:
it is the only technique surveyed that natively produces a **route network** with
designer control, rather than producing a texture from which routes must be
inferred. Map it onto CTF directly: the **major** family is the base-to-base
attack lanes, the **minor** family is the cross-connections that make flanking
possible, and `midCrossCount` (band `[3, 12]`, arena 5) is literally a count of
minor-family crossings of the midfield seam.

Two structural facts worth carrying:

- Singularities of a 2D tensor field come in named types (**wedge** index +1/2,
  **trisector** −1/2, plus node/centre/focus/saddle at +1), and by the
  **Poincaré–Hopf index theorem** the indices must sum to the Euler
  characteristic of the domain — **+1 for a disc**. So a lane field on a
  simply-connected board *must* contain singularities and their indices *must*
  total 1. You cannot design a singularity-free lane network on a disc; the
  question is only which junctions you spend your index budget on. That is a
  genuine (A)-flavoured constraint on lane topology, and it is the sort of thing
  that explains why hand-made maps all have a small number of distinctive
  junctions.
- The output is curves, not regions, so it needs the same thickening + door
  machinery as §6.4 — and it does **not** come with the tree guarantee, because
  two streamline families cross, producing cycles.

**Classification: (B).** High implementation cost (field design UI, streamline
seeding, merging and termination rules are all fiddly), high payoff, and the
guarantee has to come from elsewhere. It is the right technique for a *later*
generation of the generator, and the wrong one to start with.

---

## 8. Directional control: Gabor, sparse convolution, and the cheap version

Our hard validator is directional (§2.4). It is therefore worth knowing that the
noise literature has an entire family built for **exact directional control**, and
also worth knowing that we can get most of the benefit for two multiplies.

### 8.1 The sparse-convolution lineage

- **Lewis**, *Algorithms for Solid Noise Synthesis*, SIGGRAPH '89 — sparse
  convolution noise: convolve a random impulse (Poisson) process with a chosen
  kernel. The kernel *is* the autocorrelation, so you control the spectrum by
  choosing the kernel.
- **van Wijk**, *Spot Noise*, SIGGRAPH '91 — the same idea aimed at flow
  visualisation, where stretching the "spot" along the flow direction encodes the
  vector field. This is directly the "elongate features along a chosen direction"
  primitive.
- **Lagae, Lefebvre, Drettakis & Dutré**, *Procedural Noise using Sparse Gabor
  Convolution*, SIGGRAPH 2009 — the modern form. The kernel is a **Gabor kernel**:
  a Gaussian envelope times a cosine harmonic. That gives **exact, intuitive,
  per-point control of frequency `F0`, bandwidth `a`, and orientation `omega0`**,
  with anisotropic (single orientation) and isotropic (orientation randomised per
  kernel) variants, and no texture-space setup.
- **Lagae et al.**, *A Survey of Procedural Noise Functions*, Computer Graphics
  Forum 29(8):2579–2600, 2010 — the canonical comparison, and the right citation
  for any claim about the spectra of Perlin vs simplex vs wavelet vs Gabor noise.
- **Tricard et al.**, *Procedural Phasor Noise*, SIGGRAPH 2019 — replaces the
  Gabor amplitude with a phase, giving **high-contrast oriented stripes** with
  uniform contrast everywhere. A stripe field is, structurally, a corridor field.

### 8.2 What directional control buys us, and the two-multiply version

The specific play: **orient the noise so features elongate perpendicular to the
gun lane.** On a sides map the lane is horizontal, so elongate vertically; wall
features then present their long axis to every horizontal ray, and long horizontal
open runs become rare. This is precisely what `verticalAnchors`
(`mapgen_styles.nim:120-153`) does by hand, expressed as a property of the field
instead of as a bolted-on repair.

**Classification: (B), firmly.** It shifts the distribution of horizontal run
lengths hard. It does **not** guarantee that any particular row is blocked, so
the validator and the anchor/plug repair still have to exist. Do not let anyone
delete `verticalAnchors` because "the noise is anisotropic now".

**And here is the cost note that matters.** Gabor noise is roughly 10–50× the cost
of Perlin, and for our purpose almost all of its benefit is available from
**anisotropic domain scaling**:

```
f(x / sx, y / sy)      with sy > sx
```

Compressing the `y` input stretches features along `y`. One divide each, no new
noise basis, no kernel machinery. If we later want the orientation to *vary across
the map* — vertical near the bases, diagonal at midfield — that is when Gabor
earns its cost, and not before.

One consistency caveat: §11's mean-free-sightline formula assumed **isotropy**. An
anisotropic field has a direction-dependent mean free path — which is the entire
point — so [11.3] then describes only the isotropic average. If you go anisotropic,
measure the horizontal and vertical mean free paths separately; they are the two
numbers you actually care about.

---

## 9. Erosion: the simulation is cosmetic, the flow structure is a guarantee

### 9.1 The simulation itself

- **Musgrave, Kolb & Mace**, *The Synthesis and Rendering of Eroded Fractal
  Terrains*, SIGGRAPH '89 — the origin. **Thermal erosion**: material above a
  talus angle slides to lower neighbours, which rounds slopes to a maximum
  gradient. **Hydraulic erosion**: water dissolves, transports and deposits
  sediment, which carves channels and builds alluvial fans.
- **Mei, Decaudin & Hu**, *Fast Hydraulic Erosion Simulation and Visualization on
  GPU*, Pacific Graphics 2007 — the shallow-water "virtual pipes" model, the
  standard real-time formulation.
- **Particle / droplet erosion** (Beyer's 2015 thesis; Sebastian Lague's widely
  copied implementation) — simulate individual droplets carrying sediment
  downhill. Cheapest to implement, hardest to control.

**Classification: (C), and not a close call.** Erosion produces the most natural
*heightfields* in graphics, and we **render no height**. The sim reads a binary
wall mask through `inShape`. Every visual payoff of erosion is invisible to us,
and the cost is the highest in this survey.

### 9.2 The part that is actually an (A): D8 flow routing

Strip the physics away and what erosion is *built on* is a flow-routing structure,
and that structure carries a hard guarantee.

- **D8 flow direction** (O'Callaghan & Mark, 1984, *The extraction of drainage
  networks from digital elevation data*): each cell drains to exactly one of its 8
  neighbours — the steepest downhill one.
- **Priority-flood depression filling** (Barnes, Lehman & Mulla, 2014,
  *Priority-Flood: An Optimal Depression-Filling and Watershed-Labeling Algorithm
  for Digital Elevation Models*, Computers & Geosciences 62:117–127,
  arXiv:1511.04463): raise every local pit to the level of its lowest outlet, in
  `O(N log N)` (or `O(N)` with the integer variant).

> **(A) HARD GUARANTEE — the flow graph is a spanning forest rooted at the
> outlets.** After depression filling, every cell has a strictly-descending path
> to the domain boundary. Each cell has exactly **one** outgoing edge, so the
> graph is *functional*; a descending path cannot revisit a cell, so there are no
> cycles; a functional acyclic graph is a **forest**, rooted at the boundary
> outlets. Therefore **carving corridors along any downstream-closed subset of the
> flow edges (e.g. all edges with flow accumulation above a threshold) yields a
> CONNECTED channel network** — every carved cell has a carved path to an outlet.

Honesty about how impressive that is: you could get the same guarantee from any
spanning tree on any graph, and `genMaze`'s recursive backtracker already does
exactly that (`mapgen_styles.nim:220-250`). **The flow formulation's value-add is
not the guarantee, it is the *geometry* of the tree it produces**: channels are
sinuous rather than lattice-aligned, junctions are Y-shaped and never X-shaped
(a functional graph merges, it never crosses), branch importance follows flow
accumulation so the network has a natural trunk/tributary hierarchy, and dead ends
are rare. Those are exactly the qualities a hand-made lane network has and a maze
does not.

### 9.3 The one place height means something in our sim: TRENCHES

`CtfMap.trenches` (`sim_types.nim:856-864`) are **walkable pits**: standing inside
slows movement and fire, and most incoming gun shots fly straight over. And
`map_rules.trenchSharePermille` (`map_rules.nim:403-417`) prescribes the share of
total cover that should be delivered as trench rather than wall — **250 permille
in the occlusion regime, 400 mixed, 500 range** — with the explicit rationale that
a trench *"gives survivability WITHOUT shortening a sightline"*.

That is a **three-level** structure, and a scalar field is a three-level object
for free:

```
f > u_hi           ->  WALL     (shapePolygon in leftObstacles)
u_lo <= f <= u_hi  ->  FLOOR
f < u_lo           ->  TRENCH   (shapeRect / shapePolygon in trenches)
```

Set **both** thresholds by empirical quantile (§11.5) and you get **(A) for the
cover fraction *and* (A) for the trench share** — the two numbers `map_rules`
asks for — on every seed, with no search.

This is, as far as I can tell, **the only place in the whole survey where terrain
"height" carries genuine gameplay meaning in our engine**, and it is cheap: one
extra threshold on a field you already computed. It is also the natural home for
erosion's drainage geometry, because a low-lying, branching, sinuous network is
exactly what a trench system should look like — and unlike walls, trenches do not
have to satisfy corridor-width or connectivity constraints, because they are
walkable. **Trenches are the risk-free place to spend organic-looking noise.**

Two implementation notes: `trenches` is documented as a **FULL-map** field (both
halves, already symmetrised), so generate them in the fundamental domain and lift
them explicitly rather than handing them to the left-half path; and the generator
today emits rect pits while the mechanic is `inShape`-based and shape-agnostic, so
polygonal trenches work but only the rect art has the organic-edge treatment.

---

## 10. Making noise meet our symmetry

### 10.1 The recommendation: don't symmetrise the field at all

Restating §2.3 because it is the one thing a noise implementer is most likely to
get wrong: our pipeline already generates in a fundamental domain and lifts by an
orbit (`mapgen_styles` returns a left-half/quadrant set; `arena.nim` and `hex.nim`
do the lift). **Evaluate the field only on the fundamental domain.** Symmetry is
then (A) by construction, exact, free, and you keep a *sharper* field than any
symmetrisation would give you.

Build symmetric noise only if you have a specific reason to evaluate the field
across the whole board. §10.3 is the one such reason.

### 10.2 If you must: folding vs averaging, and their different artefacts

**Folding (orbit representative).** `g(p) = f(rep(p))`, where `rep` maps every
point to a canonical representative of its orbit. Exactly invariant. But `g` has a
**gradient crease** on the fundamental-domain boundary: continuous (C⁰) across a
mirror, discontinuous in the normal derivative. Contours therefore meet the seam
at a **kink**, and if you thicken them, the kink becomes a visible V in the wall.

**Averaging (Reynolds operator).** `g(p) = (1/|G|) * sum_{s in G} f(s.p)`. Exactly
invariant **and** as smooth as `f`. Two consequences worth knowing before you use
it:

- **It is not stationary.** Away from the group's fixed points the `|G|` orbit
  images are nearly independent, so the variance of the average is about
  `sigma^2/|G|` — contrast drops by `sqrt(|G|)`. *On* the fixed-point set all
  images coincide and the variance is the full `sigma^2`. So an orbit-averaged
  field has **systematically higher contrast near the group's fixed points**, and
  for every group we use that means **near the map centre** — the flag ring and
  the midfield. That is the worst possible place for a statistical artefact.
- **`rot180` symmetrisation always puts a critical point at the map centre.** At a
  fixed point `p` of `s`, `grad g(p) = (1/|G|) sum_s s^T grad f(p)`. For
  `C2 = {e, rot180}`, `s^T = -I`, so `grad g = 0` **identically at the centre**.
  Every seed therefore has a local max or min exactly on the centre — i.e. a blob
  or a hole centred on the flag ring, forever. Sometimes that is a great central
  feature; it is never a coincidence, and you should decide which.

### 10.3 The one case where symmetric noise earns its keep: seam-crossing contours

If you *want* wall structures that span the mirror seam as single coherent
features rather than as folded chevrons, mirror-symmetrise the field. The reason
is a clean bit of calculus:

> For a mirror `s` about the axis, at any point `p` **on** the axis,
> `grad g(p) = (1/2)(I + s^T) grad f(p)`, and for `s = diag(-1, 1)` this kills the
> normal component exactly: `grad g` is **parallel to the axis**. Therefore every
> level curve of `g` **crosses the mirror axis at a right angle**, and a contour
> plus its mirror image join into a **single smooth closed curve** spanning both
> halves.

Which means the contour-tree theorem of §6.4 applies to the *whole board's* curve
family, not just to one half — you get one global tree, one door per curve, and a
door punched *on* the axis is its own mirror image, so it is automatically fair.
That is a genuinely elegant construction and the only argument I found for paying
the symmetrisation cost.

### 10.4 Tileable / periodic noise (for completeness)

Two standard tricks, neither of which we need but both of which come up:

- **Lattice permutation mod the period.** For Perlin, index the gradient table
  with `(ix mod P, iy mod P)`. Exactly periodic with period `P`, one line of code.
  Only works for lattice noise.
- **The 4D torus embedding.** Map `(x, y) -> (cos 2 pi x, sin 2 pi x, cos 2 pi y,
  sin 2 pi y)` and sample **4D** noise there. Gives a seamlessly tiling 2D field
  with no directional distortion, for any noise basis, at 4D evaluation cost.

### 10.5 Hex boards are a non-issue

Worth stating explicitly since the hex conversion is live: noise is defined on
continuous `R^2`, so it does not care that the authoring lattice is a cube-coordinate
hex grid. Evaluate the field at `cubeToPixel(q, r)` positions and everything in
this document applies unchanged. The fundamental domain for `D6` is a 30° wedge and
for `C6` a 60° wedge; generate there and let `orbit()` lift. The **only** thing to
be careful of is the same seam question as §10.2–10.3, now with a 6-fold rosette at
the centre instead of a 2-fold chevron — and §10.2's fixed-point warning applies
with more force, since `C6` has a 6-image orbit and the contrast artefact at the
centre is correspondingly larger.

---

## 11. Solving for the threshold instead of rolling dice

*(Section order note: §11–§12 are the analysis that motivates the
recommendation, and were written first because they are what the recommendation
rests on.)*

This section is the strongest *quantitative* thing noise buys us, and it is worth
more than any of the aesthetic tricks. It is largely a derivation, so I flag
which parts are cited and which parts I derived.

### 11.1 Two classical formulas

**Cauchy's mean-chord formula (2D).** For a region of free area `A_free`
containing obstacles whose total boundary length is `P`, the mean free path of an
isotropically-random ray — the *mean free sightline* — is

```
lambda = pi * A_free / P
```

This is the 2D case of the classical integral-geometry result (`4V/S` in 3D),
standard in integral geometry and in neutron transport. Sanity check against a
case we can do by hand: discs of radius `R` at number density `n`. Perimeter
density is `2*pi*n*R`; a ray of length `L` hits a disc when the centre is within
`R`, so hits per unit length are `2nR` and the mean free path is `1/(2nR)`.
Cauchy gives `pi*(1 - n*pi*R^2)/(2*pi*n*R) -> 1/(2nR)` for dilute `n`. ✓

**Rice's formula.** For a stationary Gaussian process with unit variance and
derivative variance `lambda2`, the expected number of crossings of level `u` per
unit length is `(sqrt(lambda2)/pi) * exp(-u^2/2)` (Rice 1944/45; the up-crossing
rate is half this).

**Cauchy–Crofton** ties them together: a curve's length per unit area is
`(pi/2) x` (its intersections per unit length with a line of random direction).

### 11.2 The composite result (derived here)

Let `f` be a stationary isotropic Gaussian field on the map, unit variance,
second spectral moment `lambda2 = Var(df/dx)`. Take the wall set to be the
excursion set `W = {f >= u}`.

Restricting `f` to a straight line gives a 1D stationary Gaussian process with
the same variance and derivative variance `lambda2` (isotropy). So by Rice, that
line meets the boundary curve `{f = u}` at rate `(sqrt(lambda2)/pi)exp(-u^2/2)`
per unit length, and by Cauchy–Crofton the **contour length per unit area** is

```
L_A(u) = (sqrt(lambda2) / 2) * exp(-u^2 / 2)                      [11.1]
```

The wall area fraction is `P(f >= u) = 1 - Phi(u)`, so the open fraction is
`Phi(u)`. Substituting into Cauchy:

```
lambda_sightline(u) = pi * Phi(u) / L_A(u)
                    = 2*pi * Phi(u) * exp(u^2/2) / sqrt(lambda2)  [11.2]
```

For a band-limited field whose energy sits at wavenumber `k0 = 2*pi/L0` (feature
wavelength `L0` in px), isotropy gives `lambda2 = k0^2 / 2`, i.e.
`sqrt(lambda2) = 4.443 / L0`. So:

```
lambda_sightline ~= sqrt(2) * L0 * Phi(u) * exp(u^2/2)            [11.3]
```

**This is the dial.** Two knobs (`L0`, `u`), two banded quantities (cover
permille, mean free sightline), one closed form. Worked example at our budget:
`CoverPermilleMax = 170` (`arena.nim:1097`) means walls ≤ 17%, so `u >= 0.954`;
take walls at 15% (`u = 1.036`, `Phi(u) = 0.85`, `exp(u^2/2) = 1.71`). Then
`lambda_sightline ~= 2.06 * L0`. To land at the middle of `map_rules`'
occlusion-regime band (`sightlineBand(vrOcclusion) = (262, 1050)`,
`map_rules.nim:399`), say 550 px, you want **`L0 ~= 267 px`**. That is a very
usable number: it is 4× the recommended 68 px corridor and ~10 features across a
standard board.

### 11.3 Adding octaves is not free — and the terrain-rendering default is wrong for us

With lacunarity 2 and persistence 0.5, octave `i` has amplitude `a/2^i` and
wavenumber `k0*2^i`, so its contribution to `lambda2` is
`(a/2^i)^2 * (k0*2^i)^2 / 2 = a^2*k0^2/2` — **identical for every octave.**
Variance, meanwhile, is `sum a^2/4^i -> (4/3)a^2` and converges immediately.

So `lambda2` grows *linearly in octave count* while variance does not, and by
[11.2] the mean free sightline falls like `1/sqrt(N_octaves)`. Every octave you
add shortens sightlines and pinches the wall boundary, for zero gain in the
large-scale structure that actually shapes play.

Concretely: at `L0 = 267 px`, octave 6 has wavelength 8 px. It cannot change
whether anything is walkable (`MinCorridorWidth` is 26 px, recommended 68), it
cannot change a sightline, and it *does* multiply the vertex count of every
extracted contour against a 48-vertex budget (`mapgen_styles.nim:18`). **Use 2–3
octaves for structure, and if you want fine detail, add it as an explicit
low-amplitude radial wobble on the extracted polygon** — which is exactly what
`blobPolygon` already does with two sinusoids (`mapgen_styles.nim:91-114`), and
is much cheaper than another octave of field evaluation.

Cite this one as *derived*, not *cited*: the "8 octaves of fBm" habit comes from
terrain *rendering*, where the fine octaves are what the eye sees. We do not
render the field; we rasterise a binary wall mask at 1 px. The habit does not
transfer.

### 11.4 The Gaussian assumption, honestly

Perlin and simplex noise are **not** Gaussian. A single octave of gradient noise
is bounded (roughly `|f| <= 1`), value-zero at every lattice point, and has a
visibly non-Gaussian, light-tailed distribution. Summing independent octaves
pushes toward Gaussian by CLT, but with persistence 0.5 the first octave carries
~75% of the variance so convergence is slow.

What survives that: the **functional form** of [11.3] —
`lambda ∝ L0 * Phi(u) * exp(u^2/2)`, monotone in both knobs, with a known
sensitivity — is robust. The **constant** is not. The correct engineering move is
to use [11.3] to get the starting point and then calibrate the single scalar
constant empirically against `map_metrics.evaluateMap` over ~100 seeds. That is a
one-off calibration, not a per-map search.

### 11.5 One real (A) hiding in here: threshold by EMPIRICAL quantile

**(A) HARD GUARANTEE — cover fraction.** Do not threshold at a fixed value `u`.
Sample the field on the map raster, sort the values, and take `u` as the order
statistic at the target fraction. Then the pre-carve wall fraction is *exactly*
the target, to raster resolution, for **every** seed — no distribution
assumption, no Gaussianity, no calibration, and it works identically for Perlin,
simplex, Worley, or a field you made up this morning.

This converts `CoverPermilleMin`/`CoverPermilleMax` (`arena.nim:1096-1097`) from
a rejection risk into a non-event, and it is about six lines of code.

Two honest caveats:
- It guarantees the **pre-carve** fraction. Downstream, `arena.nim` carves
  protected floor around pedestals, spawn pockets and endzones, all of which
  *remove* wall. So the shipped `coverPermille` is the target minus the carve.
  That offset is deterministic per size class and can be measured once and
  compensated — it does not reintroduce randomness.
- The validator measures `minWall` (walls present at *every* frame) for the floor
  and the max-over-a-turn mask for the ceiling (`arena.nim:2205-2215`), because of
  spinning diamonds. A field generator emitting static polygons is unaffected;
  a generator that emits animated diamonds is not.

---

## 12. Why `interiorFrac` defeats isotropic noise (the important negative result)

`interiorFrac` is the heaviest band we have (weight 3.0), the one the pool is
furthest from (0.118 vs the 0.25 floor and the arena's 0.342), and its own note
calls it *"the scatter-vs-buildings discriminator"*. It is defined
(`map_metrics.nim:77-84, 138`) as:

> the fraction of open floor from which **≥ 6 of 8 directions are blocked within
> 120 px**.

That definition has teeth, and they bite noise specifically.

### 12.1 A convex obstacle can never do it alone

**Proposition.** Let `K` be a compact convex obstacle and `p` a point outside
`K`. The set of directions from `p` that meet `K` is an *open arc of angular
width strictly less than pi*.

*Proof.* `p ∉ K`, `K` closed convex, so a line strictly separates them; the
parallel line through `p` has all of `K` strictly on one side. Every direction
from `p` to a point of `K` therefore lies in one open half-plane of directions,
an arc of width `< pi`. ∎

**Corollary.** Of 8 directions spaced 45° apart, an open arc of width `< pi`
contains at most **4**. So a single convex obstacle blocks at most 4 of 8, and in
practice far fewer: a disc of radius `R` at distance `d` subtends `2*arcsin(R/d)`,
which for our scatter parameters (`radMax = 32`, typical `d ~ 60-120 px`) is
30–65°, i.e. **1–2 directions**.

**Therefore ≥ 6 of 8 requires at least three distinct obstacles, all within
120 px, arranged around the point.** `interiorFrac` is not a density metric. It
is a *concavity* metric. You cannot buy it with more cover — and you especially
cannot buy it with more cover, because `CoverPermilleMax = 170` caps you at 17%.

This is why our pool sits at 0.118: `genScatter` emits discs and diamonds
(`mapgen_styles.nim:170-173`), which are convex, and `genCaves` emits
`blobPolygon`s (convex-ish, since the two low-frequency sinusoids at amplitudes
≤ 0.42 and ≤ 0.28 of the radius rarely produce a re-entrant vertex). Every
organic style we have is a convex-blob generator wearing different clothes.

### 12.2 Thresholded noise is *provably* in the blob regime at our cover budget

This is the part that closes the argument, and it comes from Gaussian-field
theory rather than from intuition.

For a 2D stationary isotropic Gaussian field, the **Euler-characteristic density**
of the excursion set `{f >= u}` — expected `chi` per unit area — is

```
rho(u) = lambda2 * (2*pi)^(-3/2) * u * exp(-u^2 / 2)
```

(the 2D Lipschitz–Killing / Gaussian-kinematic-formula term; Adler, *The Geometry
of Random Fields*, and Adler & Taylor, *Random Fields and Geometry*). In 2D,
`chi = (#components) - (#holes)`. So:

- `u > 0` ⇒ `rho > 0` ⇒ the excursion set is **component-dominated**: disjoint
  blobs, essentially no enclosed holes.
- `u = 0` ⇒ `rho = 0` ⇒ the percolation-transition regime; components and holes
  balance.
- `u < 0` ⇒ `rho < 0` ⇒ **hole-dominated**: a mostly-solid set riddled with
  pockets. *That* is a building.

Our cover cap forces `walls <= 17%`, i.e. `u >= 0.954`, which is **firmly in the
positive-`rho` blob regime** — and `rho` is near its maximum there, since
`u*exp(-u^2/2)` peaks at `u = 1`. In other words, at exactly the cover budget the
engine enforces, thresholded noise is at its *most* blob-like and *least*
room-like.

**Conclusion (the negative result).** Thresholding an isotropic random field at
our cover budget cannot produce rooms, and the obstruction is topological, not a
matter of picking a nicer noise function, a nicer lacunarity, or a nicer warp. To
get holes you would need `u < 0`, i.e. **> 50% wall**, which is 3× our cover cap
and would fail `validateGeneratedMap` outright. Every gradient-noise variant in
§4 — Perlin, simplex, OpenSimplex2, fBm, ridged, billow, turbulence, domain-warped
anything — inherits this, because they all threshold a field whose excursion-set
topology at 15% area fraction is "disjoint blobs".

### 12.3 The escape hatch, and it is a good one

The obstruction is on the **excursion set** `{f >= u}`. It says nothing about the
**level curve** `{f = u}`.

A closed level curve, *thickened into a ribbon of wall*, is a **ring** — a wall
component with a hole in it, by construction, at any threshold. The interior of
that ring is 8-of-8 blocked. And the wall *area* is only
`thickness x contour_length`, which is small even though the topology is
hole-rich.

Quantitatively, using [11.1]: contour length density is
`L_A = (sqrt(lambda2)/2)*exp(-u^2/2)`, so a ribbon of thickness `t` costs wall
fraction `W = t * L_A`, while the enclosed interior is roughly
`phi - W/2` where `phi = 1 - Phi(u)` is the excursion-set area (half the ribbon
eats inward). Then

```
interiorFrac ~= (phi - W/2) / (1 - W)
```

Worked target, at our caps:

| knob | value |
|---|---|
| excursion-set area `phi` | 0.35 (so `u = 0.385`) |
| ribbon thickness `t` | 20 px |
| contour density `L_A` | `0.464 * sqrt(lambda2)` |
| ⇒ noise wavelength `L0` | **~275 px** (from `W = 0.15`) |
| ⇒ wall fraction `W` | 0.150 = **150 permille** (cap is 170 ✓, floor 40 ✓) |
| ⇒ ring interior | 0.275 of the board |
| ⇒ **`interiorFrac`** | **~0.32** (band floor 0.25, arena control 0.342 ✓) |
| ⇒ ring inner diameter | ~125 px (≥ 68 px corridor ✓, ≤ 240 px so the centre is 8/8 blocked ✓) |
| ⇒ rings per standard board | ~12–14, so ~6–7 in a 2-team fundamental domain |

Those numbers are *estimates from the Gaussian model*, not measurements. But they
are the first quantitative story I have seen for how to move `interiorFrac` from
0.118 to 0.32 **without** exceeding the cover cap, and every input is a knob we
control. Verifying them costs one afternoon with `map_eval`.

And the construction that produces the ribbon — marching squares on the field,
one closed polygon per contour, thickened — also carries a **connectivity
guarantee** (§6.4). That is the recommendation.

---
