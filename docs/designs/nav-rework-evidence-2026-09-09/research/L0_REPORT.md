# L0 result: partial improvement, qualification failed

Exact ordered-source reuse preserves unfinished search work when the scheduled
inputs are identical. Installed routes still expire on every cadence. Public
rebuild and initialization remain forced. The peer found no correctness defect;
strengthened tests also compare against a forced rebuild, self movement without
reordering, removal/return/reordering, and forced initialization generation.
Focused checks passed on c6a (Nim2.2.10) and Mac (Nim2.2.6); Mac timing is not a gate.

Three interleaved B1024 processes per variant, CPU5, Nim2.2.6:

| Host | M0 parent worst p95/max ms | L0 worst p95/max ms |
|---|---:|---:|
| c6a | 2.510745 / 2.545707 | 2.409229 / 2.456372 |
| m5a | 5.901241 / 5.999752 | 5.740836 / 5.838279 |

The initial per-seat rebuilds still occupy more than5% of measured ticks, so
p95 remains dominated by rebuilding. m5a still fails. No doubling is claimed.

Two c6a latency processes reproduce the same non-timing result: each far wave
publishes only3seats, leaving65/145 measured seat-waves unpublished at16/32seats.
Every far wave hits the2000tick cap. Reordering the same source set as a seat
moves still changes the generation. Published-route latency is censored data:
the observed far p95 of1226ticks does not describe the unfinished majority.
L0 is not accepted as a complete liveness fix. L1 exact packed-table equality
is the next separately registered candidate; no relaxation of changed-table
invalidation or the completion cap is authorized by this result.

Viewer rebuilt and module/source-stamp check passed for this experimental
checkpoint. GV63 and old fixtures remain intentionally pending final acceptance;
this checkpoint is not a shippable Phase10/11 result. Full corpus/final suite,
new GameVersion/fixtures and canonical gate remain required before acceptance.

Documentation audit before this local experiment checkpoint: source and tests
match the exact-input reuse description above and in the peer review. The
failed outcomes are stated explicitly; the production qualification guide
continues to point to the ledger rather than claim an accepted budget. No
public command or wire-schema change is introduced by L0. Broad Phase11 docs
and final replay artifacts remain pending, as recorded above.

Accounting correction: pre-M1 danger geometry was copied per seat but counted once. Total-memory numbers understated retained payload; see [GEOMETRY_ACCOUNTING_CORRECTION.md](GEOMETRY_ACCOUNTING_CORRECTION.md). Raw results are preserved.
