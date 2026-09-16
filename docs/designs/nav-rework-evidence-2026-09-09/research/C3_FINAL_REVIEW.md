# C3_FINAL_REVIEW: peer review of the decision not to retain C3

Peer (Claude) documents-only review per `C3_FINAL_REVIEW_REQUEST.md`, from
`C3-trace-native-summary.json`, `C3-regimes-native-summary.json`,
`C3-configured-native-summary.json`, `C3_STATUS.md`, and the C5 v2
attribution. No source or native change.

## 1. Data (native, exact everywhere)

- Exactness: all 27 trace pairs, all 24 regime rows, and all 198
  configured rows are marked exact; masks and pops identical on every
  configured row; ledgers identical on all 33 map-repeats; full quality
  reproduces the old hash and the combined root hash. C3 is a correct
  strength reduction, as the `C3_REVIEW.md` proof and its exhaustive index
  check said.
- Real recorded traces (m8i, 9 traces, 3 pairs): total ratio median
  1.0086, range 0.9939 to 1.0182; p95 ratio median 1.0183, range 0.9727 to
  1.0806, slower in 23 of 27 pairs.
- Regime diagnostics (m8i, 4 maps, 3 pairs): repeated sources median
  0.885, range 0.874 to 0.953; changing sources median 0.982, range 0.974
  to 0.990.
- Configured harness (m5a, 11 maps, 6 rows, 3 repeats, 198 rows): p95
  ratio median 0.9875, range 0.9631 to 1.0193, improved in 179 of 198;
  worst p95 6.480 to 6.357, 6.481 to 6.374, 6.481 to 6.344 ms by repeat;
  worst max 6.658 to 6.551 ms; 0 of 11 maps pass every repeat, in both
  arms.

## 2. Inference

- Why the configured rows improve and the traces do not: `C5/v2` showed
  that every changed rebuild in the configured rows is a first fill of 8
  static sources served 94 to 97 percent from the cache, so those rows are
  almost pure replay, the one path C3 changes. Real traces are 25 to 58
  percent hits with 3 to 8 sources per changed rebuild, and the rebuild is
  a smaller share of the tick, so a replay-only gain has little to act on
  there. That explains the sign difference; it does not explain why the
  traces get slower rather than staying flat.
- The changing-source regime moved by 2 to 3 percent with unchanged miss
  code, and the trace p95 rose in 23 of 27 pairs by up to 8 percent. Root's
  reading (code layout or noise, not a hit-path mechanism) is the
  plausible inference; it is not established, and a consistent 23 of 27
  is not what noise alone usually looks like. Either way the observation
  stands against retention: the candidate does not improve the workload
  that matters and measurably worsens its p95 in most pairs.

## 3. Does a 1 to 2 percent synthetic gain justify the tradeoff?

No. Three reasons, in order of weight:

1. The gain is on a workload whose danger cost is first fills by
   construction (`C5/v2`), and it moves no gate: 0 of 11 configured maps
   pass in both arms, and the 331 px short rows already passed headroom
   before C3.
2. The real recorded workload, which the project adopted precisely to
   avoid optimising the harness, shows no total gain and a small but
   consistent p95 regression. Adopting a change that is neutral to
   negative on the representative workload because it is positive on the
   synthetic one inverts the evidence hierarchy the research has used
   since the trace unit.
3. C3 carries no dependency: C6 is measured against C2 directly and C8 is
   defined over the parent without C3. Nothing downstream needs it, and
   dropping it keeps the primary source at the last state with a positive
   real-trace result (C2).

The one thing worth keeping is the test C3 added (multi-range, border,
empty-word regression), which pins C2 behaviour and costs nothing.

## 4. Recommendation

Agree with root: do not retain C3; restore the C2 primary source,
preserving the new cache regression test and all C3 evidence (patches,
native summaries, `C3_STATUS.md`) as a completed negative with an exact
proof. Record in the ledger that C3's mechanism is sound and that its
adoption failed on workload relevance, not correctness, so the row cursor
can be revisited only if a future candidate makes replay a dominant share
of real ticks.

C3 REVIEW READY
