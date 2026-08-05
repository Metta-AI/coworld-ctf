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

## 11. Solving for the threshold instead of rolling dice

*(Section order note: §3–§10 are the technique survey and follow below in the
final document; §11–§12 are the analysis that motivates the recommendation, and
were written first because they are what the recommendation rests on.)*

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
