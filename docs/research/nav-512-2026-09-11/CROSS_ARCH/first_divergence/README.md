# First-divergence probe (cross-architecture, original planner)

Diagnostic scratch only: no production source, no commit. Built against
the original `6b6b3408` planner (a scratch checkout of `src/` at that
commit); the same probe against the H1+H2+H3 tree gives a byte-identical
dump locally, as expected from the fingerprint parity.

## What it dumps

Same 32-seat golden-map workload as `../split_digest.nim`. After each of
the first three planning ticks, for every seat whose plan has started:

- a `seat` line: stage, units, pops, heap length, record count, search
  generation, goal, start, plus four separable digests (heap integers,
  heap float bits, record integers, record float bits);
- one `H` line per heap entry, in heap array order: record id, lattice
  key, lattice point, tie fields, `priority` and `cost` raw float bits,
  the record's `gScore` bits, the exact heuristic input
  `hypot(point, target)` bits (target = the connector-chosen lattice
  point `job.targetIndex`, printed on the `seat` line beside the
  unsnapped `goal`), the correctly rounded `sqrt(dx*dx + dy*dy)` bits,
  `cost + hypot` bits, a `pri_is_cost_plus_hypot` flag when that
  recomputation reproduces `priority` bit-for-bit (it does for all 1,296
  entries locally, so no route-field term is present in these ticks),
  and `HYPOT_NOT_CR` when the host's libm disagrees with the correctly
  rounded value;
- one `R` line per search record, in allocation order: key, closed,
  `gScore` bits, `cameFrom`;
- the minter heap if it holds anything (it does not in the first three
  ticks: plans consume the whole pool).

The planner's heap, search store and job fields are private; the probe
reads them with `std/importutils.privateAccess` in its own scope, so no
production internals are exported and no object layout is hand-kept.
(An earlier mirror-and-cast version is retained as
`superseded-mirror-*` and is not current evidence.)

## How to use

```sh
sh docs/research/nav-512-2026-09-11/CROSS_ARCH/first_divergence/run.sh native
diff docs/research/nav-512-2026-09-11/CROSS_ARCH/first_divergence/local-original-6b6b3408.txt \
     docs/research/nav-512-2026-09-11/CROSS_ARCH/first_divergence/first_divergence-native.txt | head
```

The first differing line is the first observable divergence in these
ticks. If it is an `H` line whose integer fields agree and only `pri`
or `g` bits differ, the difference is numeric (a heuristic or edge-cost
value) with ordering intact at that point; if integer fields or record
order differ, a decision differed. If the dumps are identical for all
three ticks, that bounds the divergence to later ticks, and this probe
should not be silently extended: report the bound.

## Local reference

`local-original-6b6b3408.txt` (51,832 lines; Nim 2.2.6, Apple clang 17,
arm64, original `6b6b3408` sources) and `local-h1h2.txt` (current peer
working tree: committed H1 plus uncommitted H2; it carries no H3
annotations, verified by file hashes against the root's recorded H1+H2
parent files), byte-identical. Tick 0: seat 0 spends the whole 8,192-unit
pool (8,190 pops, 209 heap entries, 8,399 records); tick 1 adds seat 1;
tick 2 adds seat 2. No `HYPOT_NOT_CR` on this host. Hashes in
`sha256.txt`.

## What is and is not proven

Proven so far (native `../NATIVE_RESULT.md`): the native libm returns a
one-ulp-different `hypot` for 17,374 of 2,763,201 integer inputs where
the local libm is exact; the map raster, danger bits, per-tick counters,
sampled route floats and paths match across hosts. Not proven: which
planner value first differs, whether any pop order differs within a
tick, and whether the full-state digest difference is entirely numeric.
This probe is designed to answer the first of those for the first three
ticks; it cannot by itself prove absence of ordering differences later.

## Root archive storage

Raw text dumps and their original sha256.txt are stored losslessly in
raw-dumps.tar.gz to keep the repository diff reviewable. Run
`tar -xzf raw-dumps.tar.gz` in this directory before the comparisons above.
The earlier H3 label was corrected to H1+H2; see CAMPAIGN_REVIEW.md two levels up.
