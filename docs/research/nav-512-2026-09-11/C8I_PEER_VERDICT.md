# Peer verdict on the Intel c8i-flex.4xlarge fleet campaign

Independent recomputation from `fleet/c8i-rows.json`, `c8i-verdict.json`
and the raw archive `fleet/c8i-raw.tar.gz` (sidecar `99f2e18e...`
matches the bytes), extracted into the peer scratchpad, against the
frozen `fleet/CARD.md` and the m5a and c6a reference streams. No native
access, build, production edit or commit. This closes the "independent
recomputation pending" line in `fleet/C8I_RESULT.md` and
`QUALIFICATION.md`.

## 1. Verdict recomputed: all four cells pass

| Cell | mode | total | p50 | p95 | max | worst misses cand / orig | repeat-exact | equals m5a and c6a streams |
|---|---|---:|---:|---:|---:|---|---|---|
| map5001-s32-edge-r1050 | pinned | 0.880 | 0.932 | 0.741 | 0.935 | 2 / 3 | yes | both variants |
| scale29-s32-moving-r1050 | pinned | 0.893 | 0.877 | 0.880 | 0.935 | 2 / 2 | yes | both variants |
| map5001-s32-edge-r1050 | unpinned | 0.880 | 0.929 | 0.742 | 0.934 | 2 / 3 | yes | both variants |
| scale29-s32-moving-r1050 | unpinned | 0.890 | 0.876 | 0.875 | 0.947 | 2 / 2 | yes | both variants |

Medians of three paired candidate-512 / original-256 ratios. Every median
is below 1.00; candidate worst misses never exceed the original's (equal
at 2 on both moving cells); every variant's stream repeats exactly and
equals both its m5a reference and its c6a stream, so the same recorded
behaviour has now been observed on three CPU families and two placements.
My values equal the root's `c8i-verdict.json` and its pass flags, and the
percentages in `fleet/C8I_RESULT.md` match to the printed precision.
**All 12 individual pairs improve all four metrics**; the closest pair is
moving-unpinned repeat 2 at max 0.960.

## 2. Raw archive: all 24 games reproduced

For every game: exit 0, no `failure.json` or `mismatch.json`, 1,200
`BUDGET_FRAME` rows over ticks 1..1200, an init log for all 32 seats
under the case's play, `SHELL_MOVEMENT seats=32` on every row, zero play
faults. Total, p50, p95, max, deadline misses and the semantic hash
recomputed from each `server.log` equal `rows.json` exactly; candidate
visits reach 16,384 units and originals stay within 8,192. The archive's
`rows.json` and `verdict.json` are byte-identical to the tree copies. The
run log shows 24 `START` and 24 `complete` lines, no failure, in the
card's order.

## 3. Host, image, libc, topology, steal (context only)

- Instance `i-08b7fb62b50e0740a` as `c8i-flex.4xlarge`, running,
  us-east-1d; Intel Xeon 6975P-C, 8 cores x 2 threads, L2 2 MiB per
  core, L3 480 MiB; FMA, AVX2 and AVX-512 present; kernel
  6.8.0-1063-aws. Sibling map recorded: CPU 5 pairs with 13, CPUs 6 and 7
  with 14 and 15, so pinned runs keep the server's and the clients'
  siblings free, as on the AMD hosts.
- Same Docker image digest `sha256:5629fc83...` as the m5a and c6a
  campaigns; `libc` recorded as glibc 2.36 in `host.json`.
- Lifecycle `/proc/stat` deltas: steal at most 0.01 s per game across all
  24 games, so the flex family's possible throttling did not appear.
  Pinned CPU 5 busy 9.2-10.2 s (edge) and 21.8-24.2 s (moving) of about
  53 s wall, candidate consistently below original; unpinned runs leave
  CPU 5 idle. Whole-lifecycle counters, no run filtered.

## 4. Limitations

- Two 32-seat workloads on one owned instance per family, synthetic
  presence clients pinned to 6-7 in both placements, no production
  contention; the card says so and nothing here extends it.
- This host, like c6a, is far faster than the m5a screening core: both
  variants miss the 24 Hz deadline on only 2-3 frames per game. The pass
  is relative, as everywhere in this campaign.
- Cross-family stream equality held on both AMD and Intel, so the libm
  dispatch concern from P16 did not materialize on either family; it was
  a possibility, not an observation.

## 5. Reports

`QUALIFICATION.md` now states the pool semantics correctly (a shared
pool of 512 per configured seat, plans first, one visit may take it all,
minter takes the remainder, not a per-cog quota), carries an evidence
index, and marks only the Intel independent recomputation as pending,
which this file closes. `INTEGRATION.md` lists the concrete steps a
budget change would need (fresh main, GameVersion under AGENTS.md rules,
re-derived budget tests, nine fixtures re-recorded, viewer rebuild, design
and module docs, the stale bench asserts) and carries the limits forward.
I found no remaining material overclaim: the research target is stated
as passed on every registered gate, the default and publication as
unchanged, and the caveats (older m5a cores, arbitrary policies,
contention, reflex windows, stale-counter diagnostics, the unresolved
Mac/Linux internal-state difference) are retained.

## 6. Verdict

The current-main candidate at 512 passes the frozen fleet card on
c8i-flex.4xlarge in both placements by my independent recomputation, with
full coverage on all 24 games, raw logs reproducing every recorded
metric, exact repeats, and streams equal to the m5a and c6a references.
With m5a held-out, c6a and c8i-flex all passed and independently
verified, every registered gate of this research campaign is met. No
production budget change or publication follows from that; the handoff
in `INTEGRATION.md` is the next step and is not authorized by this file.

PHASE 25 READY
