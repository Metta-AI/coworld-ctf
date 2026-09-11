# First-divergence probe: report

Diagnostic only. No production edit, no native access, no commit, three
ticks exactly.

## What changed in P14

The mirror-and-cast probe is replaced by one that reads the private
planner state with `std/importutils.privateAccess` (`BodyPlanner`,
`BodyPlanJob`, `BodyFieldMinter`, and the nested heap, store and node
types via `typeof`). Nothing is exported from production. The old probe
and its dump are kept as `superseded-mirror-*` and are not current
evidence. The new dump prints the actual heuristic input: the
connector-chosen target lattice point (`job.targetIndex` through
`job.step`/`job.latticeW`), labelled `target`, beside the unsnapped
`goal`.

## Local results (Nim 2.2.6, Apple clang 17, arm64)

- `local-original-6b6b3408.txt` (original sources, scratch checkout) and
  `local-h1h2.txt` (current peer working tree) are byte-identical,
  51,832 lines each. **Label correction (P15):** this second dump was
  first labelled H3. The peer tree is H1 (committed `e730021a`) plus
  uncommitted H2 only; its three planner files hash equal to the root's
  recorded H1+H2 parent files (`H3/parent-*.nim`:
  `cdf40dbc...`, `98309495...`, `b0a0a20f...`) and contain no
  `stackTrace: off` annotation. H3 equality rests on the root's own
  local and native fingerprints, not on this dump.
- Every one of the 1,296 heap entries across the three ticks satisfies
  `priority == cost + hypot(point, target)` bit-for-bit
  (`pri_is_cost_plus_hypot` on all, `pri_differs` on none). So in these
  ticks the route-field term of the heuristic is absent (no field is
  ready yet) and the only libm-dependent input to any priority is that
  one `hypot` call per pushed node; `cost`/`gScore` values are sums of
  `step x {1, sqrt2} x (1 + w x danger)` in IEEE double.
- `HYPOT_NOT_CR` appears on no line locally, consistent with the local
  grid probe.

## Suggested native comparison (separating floats from decisions)

Run `sh docs/research/nav-512-2026-09-11/CROSS_ARCH/first_divergence/run.sh native`
on the original sources, then:

1. **Digest level.** Compare each `seat` line's `heap_ints`/`rec_ints`
   against the local file. If every integer digest matches and only
   `heap_floats`/`rec_floats` differ, no heap position, record id, key,
   closed flag or predecessor differs in these ticks: the divergence is
   numeric only.
2. **Line level, integers only.** Strip the float columns and diff:

   ```sh
   strip() { sed -E 's/ (pri|cost|g|hypot_to_target|cr_sqrt_to_target|cost_plus_hypot)=[0-9A-F]{16}//g; s/ (pri_is_cost_plus_hypot|pri_differs_from_cost_plus_hypot|HYPOT_NOT_CR)//g; s/ (heap_floats|rec_floats)=-?[0-9]+//g' "$1"; }
   diff <(strip local-original-6b6b3408.txt) <(strip first_divergence-native.txt) | head
   ```

   An empty diff proves identical heap order, record allocation order,
   closed sets and predecessor links for ticks 0-2.
3. **Line level, floats.** `diff` the unstripped files; the first `H` or
   `R` line that differs names the first value. On an `H` line, check
   whether the native side carries `HYPOT_NOT_CR` and whether its
   `cost` bits still match: if `cost` matches and only `pri`,
   `hypot_to_target` differ by one ulp, the difference is the libm
   `hypot` at that `(point - target)` pair and nothing upstream. If
   `cost`/`g` differ first, an edge cost differed, which these ticks
   would attribute to the danger sample or the sqrt2 constant, both
   currently expected identical.
4. **Bound.** If the stripped diff is empty and the float diff is
   non-empty, the result is: decisions identical, priorities differ by
   libm rounding, for ticks 0-2. That does not prove ordering stays
   identical in later ticks, where a one-ulp priority difference can
   flip a near-tie; it bounds where the first difference is and what
   kind it is. If both diffs are empty for all three ticks, report that
   the first divergence lies beyond tick 2 rather than extending the
   probe.

PHASE 14 READY
