# M0: shared-memory qualification fix

The default Dial queue now uses 131,072 buckets, retaining support for up to
262,144 through the existing constructor. Exact absolute-f matching and FIFO
ordering are unchanged. Three int32 bucket arrays shrink by 1,572,864 bytes.

The full 3,072-case native corpus passes with zero missing or illegal routes,
37,637,596 pops, and unchanged route hash
`5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500`.
All 64 pool maps meet the 16 MiB shared upper bound: the largest is
15,938,095 bytes on published pool 29. Colossal retains 261,140,828 bytes total,
below 256 MiB. `M0/MEMORY_SUMMARY.json` derives each shared sum from the raw
ledger, including all allocator overhead conservatively.

Three interleaved c6a processes per variant, B1024, CPU5, Nim2.2.6:

| Variant | Worst p95 ms | Worst maximum ms |
|---|---:|---:|
| Parent | 2.484543 | 2.524236 |
| Smaller ring | 2.484964 | 2.642113 |

Every pop array matches. Both retain 3.6/4.5 ms headroom; no speed improvement
is claimed. The focused suite passed under CI Nim2.2.10, including identical
routes and pop counts with 262144, 131072 and 2 buckets under variable danger.

## Validation limits and retained orchestration failures

The first quality command used Docker-only `--all`; its canonical guard refused
before evaluation. Its failure is retained in `M0/quality-activation.*`.
The subsequent explicit native `--quality --activation` run passed. However,
the harness transfer and compile overlapped, and the resulting JSON lacks the
new shared-cap fields. It proves the algorithm and ledger, not execution of
the new pool gate. All 65 raw allocation rows were independently checked above.
A subsequent verified build must exercise the new gate; the final canonical
Docker run remains required. Do not treat the intermediate DONE file as a pass.

This closes the measured allocation gap, not overall Phase10/11 acceptance.
The m5a timing failure and far-route completion failures remain open. Viewer,
full suite, fixtures, final compile checks and canonical qualification are
tracked separately in LEDGER.md.

## Verified new gate check

After transfer completed, a forced rebuild with the recorded harness SHA ran
`--activation --pool-index 29` (largest pool plus colossal). It passed and
emitted the new shared-cap fields:15938095bytes for pool29 and132979292bytes
shared on colossal. `M0/gate-verified.json` and `gate-harness.sha256` identify
this check. Full canonical Docker verification remains pending.

Accounting correction: pre-M1 danger geometry was copied per seat but counted once. Total-memory numbers understated retained payload; see [GEOMETRY_ACCOUNTING_CORRECTION.md](GEOMETRY_ACCOUNTING_CORRECTION.md). Raw results are preserved.
