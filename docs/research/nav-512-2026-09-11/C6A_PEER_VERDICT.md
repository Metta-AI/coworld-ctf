# Peer verdict on the c6a.4xlarge fleet campaign

Independent recomputation from `fleet/c6a-rows.json`, `c6a-verdict.json`
and the raw archive `fleet/c6a-raw.tar.gz` (sidecar
`399112a7...` matches the bytes), extracted into the peer scratchpad,
against the frozen `fleet/CARD.md` (hash unchanged, `338c9a9e...`) and
the m5a reference streams in `current-main/performance-rows.json`. No
native access, build, source edit or commit.

## 1. Verdict recomputed: all four cells pass

| Cell | mode | total | p50 | p95 | max | worst misses cand / orig | repeat-exact | equals m5a stream |
|---|---|---:|---:|---:|---:|---|---|---|
| map5001-s32-edge-r1050 | pinned | 0.868 | 0.933 | 0.762 | 0.894 | 3 / 3 | yes | both variants |
| scale29-s32-moving-r1050 | pinned | 0.895 | 0.890 | 0.890 | 0.904 | 2 / 4 | yes | both variants |
| map5001-s32-edge-r1050 | unpinned | 0.886 | 0.952 | 0.774 | 0.898 | 3 / 3 | yes | both variants |
| scale29-s32-moving-r1050 | unpinned | 0.897 | 0.894 | 0.892 | 0.903 | 2 / 3 | yes | both variants |

Medians of three paired candidate-512 / original-256 ratios. Every
median is below 1.00, candidate worst misses never exceed the original's
(equal at 3 on the edge cell), every variant's stream repeats exactly,
and every stream equals its same-case, same-budget m5a reference. My
values equal the root's `c6a-verdict.json` and its pass flags. **All 12
individual pairs improve all four metrics**; the pair closest to the
line is edge-unpinned repeat 3 at p50 0.975.

## 2. Raw archive: all 24 games reproduced

For every game: exit 0, no `failure.json` or `mismatch.json`, 1,200
`BUDGET_FRAME` rows over ticks 1..1200, an init log for all 32 seats
under the case's play, `SHELL_MOVEMENT seats=32` on every row, zero play
faults. Total, p50, p95, max, deadline misses and the semantic hash
recomputed from each `server.log` equal `rows.json` exactly. Candidate
runs reach 16,384-unit visits and originals stay within 8,192, so the
budgets are the ones claimed. The archive's `rows.json`, `verdict.json`
and `c6a.4xlarge-instance.json` are byte-identical to the tree copies.
The run log shows 24 `START` and 24 `complete` lines, in the card's
order (edge-pinned, moving-pinned, edge-unpinned, moving-unpinned per
repeat, pair order alternating by the parity rule).

## 3. Host, image, libc, affinity (context)

- Instance `i-08b7fb62b50e0740a` as `c6a.4xlarge`, running, us-east-1d;
  AMD EPYC 7R13, 8 cores x 2 threads, L2 512 KiB per core, L3 32 MiB,
  FMA and AVX2 present; kernel 6.8.0-1063-aws.
- Sibling map recorded: CPU 5's sibling is 13, CPUs 6 and 7 pair with 14
  and 15; so pinned runs keep the server's sibling free and the client
  cores' siblings free, as on m5a.
- Docker image digest `sha256:5629fc83...` in the instance record, the
  same image as the m5a campaign; `libc` recorded as glibc 2.36 in
  `host.json`. Both items I asked for in P17 are present.
- Runner affinity was all 16 CPUs; pinned runs used `{5}`, unpinned none.

Lifecycle `/proc/stat` deltas (whole process lifecycle, not the playing
interval; context only, no run affected):

- Steal time is at most 0.01 s per game on every game.
- Pinned games: CPU 5 busy 13.1-14.7 s (edge) and 29.7-33.2 s (moving)
  of about 54 s wall, candidate consistently below original; client
  cores 6-7 busy about 0.2 s.
- Unpinned games: CPU 5 mostly idle as expected, with one exception,
  scale29-moving-unpinned original repeat 2, where the scheduler placed
  about 9.3 s of server work on CPU 5. That is ordinary scheduling, not
  a defect; the run is retained and passes.

## 4. Limitations and things that are not wins

- **This host is roughly twice as fast as the m5a screening core.** The
  moving stress cell that missed the 24 Hz deadline on most frames on
  m5a misses on 2-4 frames here for both variants, and the edge cell on
  3. The gates are relative, and they pass, but "the stress workload
  meets the deadline on c6a" is a statement about this host, not about
  the workload's headroom on the m5a-class floor.
- Two cells at 32 seats only, by design of the card; 16 seats and the
  shorter ranges rest on the m5a matrix. Both plays' seats spend the
  reflex windows under native control, as before.
- Unpinned mode still pins the presence clients to 6-7, a stand-in for
  the 1-CPU-request-no-limit shape rather than a reproduction of it.
- Cross-family stream equality held on this family, so the P16 concern
  about libm dispatch did not materialize here; it remains a possibility
  for the Intel family and the card's stop rule still applies there.
- `host.json` does not itself carry the image digest (the instance
  record does); minor.

## 5. Verdict

The current-main candidate at 512 passes the frozen fleet card on
c6a.4xlarge in both pinned and unpinned execution by my independent
recomputation: all medians below 1.00, worst misses not above the
original's, streams repeat-exact and equal to the m5a references, full
coverage and raw-log reproduction on all 24 games, steal negligible. The
Intel family is still to be qualified separately; no production or live
budget claim follows from this.

PHASE 23 READY
