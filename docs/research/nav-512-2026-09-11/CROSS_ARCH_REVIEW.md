# Cross-architecture suspension-digest difference: bounded investigation

Question (`CROSS_ARCH_QUESTION.md`): native original (Nim 2.2.4, GCC
12.2.0, amd64) and local original (Nim 2.2.6, Apple clang 17, arm64)
print the same `path_digest`, point count and 1,119 ticks for
`H1/crossbuild_fingerprints.nim`, but different `suspension_digest`
(`-7750959843466495734` native vs `5936823674378073636` local). Local
scratch work only; no native access, no production edit, no timing, no
commit. Internal cross-platform parity is **not** claimed anywhere below.

## What the digest contains

`jobFingerprint` (`body_planner.nim:801-822`) folds, per seat per tick:
stage, revision, unit and expansion counters, `heap.len`, `search.count`,
endpoint-scan integers, then every heap node's `priority` and `cost`
(float64), every search record's `gScore` (float64), `keys`, `closed`,
`cameFrom`, and `routeStateFingerprint` (clock, pins, per-slot integers
and every route-field `distance` float plus `hops` byte).
`mintFingerprint` (`:534-544`) adds the mint job counters and the minter
heap's float priorities. A one-ulp difference in any hashed float
changes the digest even when no comparison outcome changes; a change in
any counter means a decision changed.

Where the floats come from:

- A\* `priority` = `nextCost + heuristic`; `nextCost` = `cost + baseCost *
  (1.0 + dangerWeight * danger.sample)`; `heuristic` = `max(hypot(dx, dy),
  routeDistance * 8 * 0.999) * 1.0` (`:546-552`, `:621-636`).
- Minter priorities and route distances = sums of `1.0` and the
  compile-time constant `Sqrt2` (`:480-486`), IEEE additions only.
- `danger.sample` values are float32 from `attenuation(hypot(dx, dy) *
  8, range)` = `1.0 - fraction * 0.4` with `fraction = (d - 400) / 650`
  (`body_nav.nim:160-167`, `:188-191`).

So the platform-sensitive inputs are exactly: libm `hypot` (Nim's
`math.hypot` is `importc: "hypot"` from `<math.h>`), floating-point
contraction of `a*b+c` shapes, and the integer wall raster if it were
host-dependent.

## Established locally

1. **Hashing is not the cause.** `lib/pure/hashes.nim` in Nim 2.2.4
   (fetched from the tag) and local 2.2.6 have identical `hash(float)`
   (`hashWangYi1(cast[Hash](x + 0.0))`), identical `hash` for ordinals
   (`hashWangYi1(uint64(ord(x)))` by default) and identical
   `hashWangYi1`. `path_digest` matching across platforms already shows
   the integer/tuple path agrees.
2. **Local libm `hypot` is correctly rounded on every input the planner
   can feed it.** For integer deltas the exact `dx^2 + dy^2` is a
   representable double and IEEE `sqrt` is correctly rounded, so
   `sqrt(float(dx*dx + dy*dy))` is the correctly rounded `hypot`. Apple
   libm agreed bit-for-bit on all 2,563,200 pairs with `0 <= dx, dy <=
   1600` and 200,000 random pairs up to 3600 x 1900 (the practice map's
   extent). Local `hypot` cannot be the local side's contribution to a
   difference.
3. **Contraction is present locally but does not explain this
   difference.** Apple clang fuses by default; the arm64 assembly of the
   production-flag build has one `fmadd` in `advanceAstar`, one in
   `advanceConnector` and one in `attenuation`. Rebuilding the cross-build
   program with `--passC:-ffp-contract=off` produced the **same** local
   digest `5936823674378073636`. Whatever differs natively is therefore
   not something the local fused operations changed on this workload.
   (GCC on baseline x86-64 emits no FMA, so the native side is unfused
   unless `-march` says otherwise; the probe below confirms it.)
4. **The wall raster is designed to be host-independent.** `arena.nim:1491`
   documents that shape geometry "must not use host libm" and uses a
   fixed-point cosine table; the only `cos`/`sin` calls in the module are
   in generator placement (`:1699-1726`), not in `rasterizeWallMasks`.
   Not yet verified natively; the probe prints the raster hash.

## Plausible, not established

- **glibc `hypot` not correctly rounded on some lattice inputs.** Debian
  bookworm ships glibc 2.36, whose `hypot` was rewritten in 2.35 for
  accuracy; I could not verify from source whether it is correctly
  rounded on all of these integer inputs, and I will not assert it. If it
  differs by one ulp on any `(dx, dy)` reached by a heuristic call or by
  the danger kernel, every downstream priority and any float32 kernel
  cell it feeds differ in the last bit, producing a different digest
  with, in the common case, identical pop order and paths. This is the
  simplest explanation consistent with "paths identical, digest not",
  and it is checkable natively in under a minute (item 2 below).
- **A decision difference that leaves the final paths unchanged.** A
  one-ulp priority difference can flip a near-tie pop order; the closed
  set and final path can still coincide while `astarExpansions`,
  `workUnits` and suspension points differ. The digest cannot tell these
  apart; only a counters-only digest can (item 3 below). Until it is
  run, "the paths match" must not be read as "the decisions match".

Excluded as far as local evidence goes: hashing (1), local `hypot` (2),
local contraction (3), compile-time `Sqrt2` (IEEE `sqrt`, correctly
rounded on both hosts' VMs), x87 excess precision (x86-64 uses SSE2 by
default), and Nim version differences in the hashed code paths (the
planner sources are identical by hash in every card).

## Small exact outputs the root can obtain natively

All are read-only scratch programs; none touches production or timing.

1. **Contraction and `hypot` bit probe** (`CROSS_ARCH/fma_probe.nim`; local output in
   `CROSS_ARCH/local-fma-probe.txt`): prints
   `a*b+c` bits for `a = 1 + 2^-27, b = 1 - 2^-27, c = -1` (local:
   `BC90000000000000`, fused; unfused gives `0`) and `hypot` bits versus
   the correctly rounded value for ten lattice inputs (local: all
   `same`). Expected native: `0` and all `same`. Any `DIFFERENT` line is
   the cause, established.
2. **Full-grid `hypot` check** with the Python `ctypes` script used
   locally (glibc `libm.so.6`, `dx, dy in 0..1600` and random up to
   3600 x 1900, compared against `math.sqrt(float(dx*dx+dy*dy))`). Local
   result: 0 mismatches. A non-zero native count with the first
   mismatching pair identifies the input class.
3. **Split digests** (`CROSS_ARCH/split_digest.nim`, public APIs only,
   same workload as the cross-build program). Local reference in
   `CROSS_ARCH/local-split-digest.txt`:

   ```
   map_raster=7809616305346269554 width=3211 height=1713 grid=401x214 atlas=2478 components=1 rooms=24 chokes=106
   danger_bits=-523662051239749665
   ticks=1119 counters=-3640950424532083340 floats=8266816153613578351 path_digest=3301525546362550601 points=29546
   ```

   followed by 1,119 per-tick counters-only digests. Reading the native
   output against it:
   - `map_raster` differs: the map, not the planner, diverges; stop
     there.
   - `danger_bits` differs, `map_raster` same: the kernel path
     (`hypot`, `attenuation`, float32 rounding) differs at the source.
   - `counters` same, `floats` differs: decisions identical, values differ
     by rounding; the aggregate digest difference is numeric provenance
     only. Still not "parity", but a bounded, understood difference.
   - `counters` differs: a decision differed; the first differing
     per-tick line gives the tick, and a follow-up dump of that tick's
     seats localizes the seat and stage.
4. **`objdump -d /results/server-512 | grep -c vfmadd`** on the native
   binary: expected 0 on baseline x86-64 GCC; a non-zero count would make
   the native side the fused one, which the local contraction-off run
   shows does not change the local digest but might change the native.

## What this means for the H3 decision

Nothing here weakens the within-toolchain exactness argument: every
candidate has matched its parent bit-for-bit on the same host and
toolchain (native H1, native H2, local H1/H2/H3, and the pending native
H3 comparison). The cross-platform question is about the planner's
floating-point provenance across libms and compilers, which predates this
campaign (the original source shows it) and is independent of H1-H3. It
matters for the held-out protocol's "cross-architecture determinism"
line in `QUALIFICATION_PROTOCOL_REVIEW.md` section 4: that line should
be restated as "counters-only digest and paths identical; float digests
reported, not gated" unless item 3 shows counters differ, in which case
the decision difference must be localized before any cross-host claim.

PHASE 9 READY
