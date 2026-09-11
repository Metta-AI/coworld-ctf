# Campaign runner review (read-only)

Reviewed: `qualification/run_campaign.py`, `run_training.py`,
`metrics.py`, `run_case.py`, `qualification/assets.json`,
`qualification/PROTOCOL.md`, `PROTOCOL_NOTES.md`,
`old-base-correctness-passed.json`, `current-main/CARD.md`,
`current-main/run_native.sh`, `build.sh`, `checks.sh`,
`training-config.json`. No native access, no production change, no
commit, no experiment.

## 0. Label correction carried out first

The first-divergence dump previously labelled H3 was produced from the
peer working tree, which is H1 (committed `e730021a`) plus uncommitted
H2 and carries no `stackTrace: off` annotation; its three planner files
hash equal to the root's recorded H1+H2 parent files. It is renamed
`local-h1h2.txt`, and `README.md`, `REPORT.md` and `sha256.txt` under
`CROSS_ARCH/first_divergence/` now say so. H3 parity rests on the
root's own local and native fingerprints.

## 1. What the runners get right

- **Budgets and comparators.** Correctness pairs `/original/server-256`
  with `/candidate/server-256`; performance pairs `/original/server-256`
  with `/candidate/server-512`; training does the same on the frozen
  training config. `build.sh` substitutes exactly one budget line and
  records source and binary hashes per budget.
- **Frozen pair order.** Performance alternates by
  `(index + repeat - 1) % 2` with zero-based case index and one-based
  repeat, which is the protocol's "zero-based case index plus zero-based
  repeat index" rule; training uses original/candidate,
  candidate/original, original/candidate as the card says.
- **No overwrite, no discard.** `execute` refuses an existing directory;
  `run_case.run` uses `mkdir(exist_ok=False)`; every failure writes
  `failure.json` and re-raises; `performance-rows.json` is rewritten
  cumulatively after every run so partial campaigns are visible.
- **Full-frame and guest coverage.** `metrics.inspect` requires exit 0,
  exactly 1,200 `BUDGET_FRAME` rows with ticks 1..1200, an init log for
  every configured seat under the case's play name, `SHELL_MOVEMENT
  seats=` equal to the seat count on every row, no `play_fault`, and
  1,200 `BUDGET_SHELL` rows. Timing is taken over all frames, no
  exclusions; misses use `ns * 24 > 1e9`.
- **Gate arithmetic** matches the protocol: per-cell median paired total,
  p50, p95, max all <= 1.00, candidate worst misses <= parent's, repeat
  streams identical per variant, every cell must pass. Performance is
  gated on a complete correctness list and a passed training verdict.
- **Same-budget exactness** stops the campaign on the first mismatch.
- **Training config** is key-for-key identical to the H3 screen's
  candidate game config (verified against the H3 raw archive), so the
  card's "identical to the H3 inputs" holds.
- **Asset pinning** covers both server binaries, the presence client and
  both guest WASM modules by absolute path, verified before any run,
  which closes the WASM-bytes gap raised in P10.

## 2. Findings

1. **Base provenance of the pinned assets (must check before the
   current-main runs).** The repository copy of
   `qualification/assets.json` pins `/original/server-256` at
   `802389df...` and `/candidate/server-512` at `d5984cb8...`. Those are
   the old-base binaries (the H1 archive's original 256 and the H3
   screen's candidate), matching the old-base correctness campaign now
   recorded in `old-base-correctness-passed.json`. The current-main
   campaign reads `assets.json` from the mounted results directory, so a
   fresh file with the `nav512-main58-results` hashes must be there; the
   scripts verify that files match `assets.json` but nothing verifies
   that `assets.json` itself belongs to the current base. Suggested
   fix, script-only: have `run_campaign.py` and `run_training.py` also
   verify the workspace's `src/shell/*.nim`, `src/ctf/server.nim`,
   `src/ctf/glory.nim` and `nimby.lock` against `build.sh`'s
   `source-256.sha256` (with `body_nav.nim` compared after normalizing
   the budget line), and copy the `assets.json` digest into every
   verdict file. Without that, a stale results directory would pair
   old-base binaries under a current-main card, which the card forbids.
2. **Correctness mismatch is not persisted.** On a same-budget mismatch
   the script raises without writing anything; only stdout records
   which case failed and the two hashes. Write a
   `correctness-mismatch.json` with case name and both `metrics.json`
   paths before raising, so the stop is on disk.
3. **First failure aborts the rest.** A failed or early-ending run in
   any cell stops the whole phase. That is a legitimate reading of the
   protocol, but the report must then say "campaign incomplete", not
   "cell failed on timing", and the remaining cells stay unrun rather
   than being executed under a new name. If the root prefers to finish
   the other cells for information, that needs a preregistered note,
   since the protocol's replacement rule requires a separately named
   campaign.
4. **Timeout headroom.** `server.wait(timeout=300)`: the heaviest cells
   (scale 2.9, 32 seats alive all game at `hitPoints` 1000, 1050 range,
   candidate 512) ran about 73 s on the pool-505 preflight; 300 s leaves
   margin, but a timeout produces `failure.json` with no `exit.json` and
   no frame count, which `inspect` reports as a failed run. Fine as
   long as it is reported as coverage failure, not timing.
5. **Minor.** `run_case.py` prints `<dirname> complete` without the
   phase or variant, as noted for H1; `execute`'s own `START` line
   covers it. The fixed port 21814 has not failed in four screens; keep
   as is.

No wrong budget, comparator, order or silent discard was found in the
code as written. Finding 1 is the only item that can invalidate a
result and it is a provenance check, not a code defect.

PHASE 15 READY
