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
| 5.6 | **Maximal Poisson-disk (Ebeida)** | **(A)** | **+ covering: no gap > 2r (an r-net)** | O(N log N) | Bounds *dead floor* from above — the max-void guarantee |
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

Distance metric matters: Euclidean gives round cells, Manhattan gives
axis-aligned diamond cells (**do not use — see §2.4**), Chebyshev gives squares.

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

**What it does NOT guarantee, stated plainly:**

- **Not maximality.** With finite `k`, a gap can survive simply because all `k`
  darts happened to miss it. So Bridson gives you a *separated* set, not a
  *maximal* separated set, and therefore no upper bound on hole size. Raising `k`
  makes this rarer; it does not make it impossible.
- **Not an unbiased Poisson-disk distribution.** Bridson's sampling is biased
  relative to true dart-throwing / true maximal Poisson-disk sampling — the
  annulus-based propagation correlates a sample with its parent. For texture and
  rendering this matters; for cover placement it does not.

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
Sampling*, SIGGRAPH 2011 / ACM TOG 30(4); and Ebeida et al., *A Simple Algorithm
for Maximal Poisson-Disk Sampling in High Dimensions*, Computer Graphics Forum
2012. These give **provably maximal** and **provably unbiased** sampling, which
Bridson does not.

Maximality matters because of a clean piece of metric geometry:

> **Theorem (r-net).** If `S` is a *maximal* `r`-separated subset of a metric
> space `X` — i.e. no point of `X` can be added while keeping all pairwise
> distances ≥ `r` — then `S` is `r`-**covering**: every point of `X` is within
> `r` of some point of `S`.
>
> *Proof.* If some `x ∈ X` were at distance > `r` from every point of `S`, then
> `S ∪ {x}` would still be `r`-separated, contradicting maximality. ∎

So maximality is **(A) for a maximum-void bound**: no disc of radius `r` anywhere
in the region is empty of samples. In map terms that is *"no region of the board
larger than `r` is featureless"* — a direct, constructive bound on **dead
floor**, which `MapPlay.deadFloorFrac` and `biggestDeadPx`
(`map_metrics.nim:204-205`) measure and which nothing in our generator currently
controls.

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

**Classification: (B), and I want to be precise about why it is not (A).** Lloyd's
algorithm converges to a *local* minimum of the CVT energy, not a global one, and
it comes with no bound on the resulting cell-size spread after a finite number of
iterations. In practice 2–3 iterations visibly evens out a Poisson point set,
which is a genuinely useful distribution shift. But "visibly evens out" is not a
theorem, and after relaxation you have **lost** the min-separation guarantee you
started with unless you re-check it — Lloyd moves points, and it can move two
points closer together. If you want both, relax *then* re-run the separation
filter, and treat the guarantee as coming from the filter.

### 5.9 Low-discrepancy sequences (R2, Sobol, Halton)

Martin Roberts, *The Unreasonable Effectiveness of Quasirandom Sequences*
(http://extremelearning.com.au/unreasonable-effectiveness-of-quasirandom-sequences/)
popularised the **R2 sequence**: the 2D generalisation of the golden-ratio
sequence, `p_n = frac(n * (1/phi2, 1/phi2^2))` where `phi2 ≈ 1.324718` is the
plastic number (real root of `x³ = x + 1`).

Its attractions for us are real: **stateless, O(1) per sample, seekable, and
deterministic** — you can ask for "the 47th cover position" without generating the
first 46, which is a genuinely nice property for a seed-reproducible generator.

**Classification: (B), and here is the honesty note.** Bounded *discrepancy* is
proven for low-discrepancy sequences generally, and that is a statement about how
evenly the points fill the space *in the limit*. A **minimum-separation lower
bound** is a different and much stronger claim. For the 1D golden-ratio sequence
the three-distance (Steinhaus) theorem does give a clean minimum-gap result. For
R2 in 2D, the claim that the minimum pairwise distance is bounded below by
`c/sqrt(N)` circulates in blog posts and I have **not** been able to verify it
against a primary source in this session. **Treat it as folklore until checked.**
If it holds it would be a lovely (A) — a stateless, allocation-free generator with
a proven separation bound — so it is worth someone spending an hour on the
literature. Until then: if you want the separation guarantee, use Bridson, where
the guarantee is enforced by construction and needs no theorem at all.

For comparison, **stratified sampling gives a trivially provable guarantee** —
exactly one sample per stratum — and that is §5.7. When in doubt, prefer the
guarantee you can see in the code over the one you have to look up.

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
