# Fleet card review (read-only)

Reviewed: `fleet/CARD.md` (SHA-256 `338c9a9e...`),
`current-main/ASSET_PROVENANCE.md` and `assets.json`,
`CROSS_ARCH/first_divergence/NATIVE_RESULT.md` and
`native-comparison.json`, `HARDWARE.md`, `hardware-inventory.json`. No
native access, mutation, benchmark or code change.

## 0. Provenance and cross-arch status, acknowledged

- The current-main pins (`/original/server-256` `d0aebbd1...`,
  `/candidate/server-512` `b33a1028...`, candidate 256 `f550c797...`)
  are read back from the fresh mounted results directory and tied to
  `builds.tar.gz` build logs and source hashes. My campaign finding 1 is
  closed.
- The three-tick native comparison shows every stored priority, cost,
  gScore, heap position, record, closed flag and predecessor equal to
  the Mac; the six raw differences are the recomputed diagnostic
  `hypot` column for two inputs where glibc is one ulp off correctly
  rounded, and those round away in `cost + hypot`. The full-state
  baseline difference is therefore outside ticks 0-2 or outside the
  dumped state. No parity claim, no further probes.

## 1. Counts and order

Two cells x two affinity modes = 4 cells per family; x 2 variants x 3
repeats = 24 games per family, 48 in total. Correct. The order rule
(repeat index 0..2 plus cell index 0..3, even sum starts original) is
well defined and mirrors the six-cell protocol; cells interleaved within
each repeat; one game at a time; every frame retained. Cell selection
(`map5001-s32-edge-r1050`, `scale29-s32-moving-r1050`) is declared before
any held-out timing is seen, which is the right way round, and it covers
the realistic and the replan-stress workloads at 32 seats. The family
choice (c6a.4xlarge, c8i-flex.4xlarge) matches the inventory: 31 and 11
of the 49 running CTF games, against 4 m6a, 2 m7i-flex and 1 m5a.

## 2. Deterministic-stream reference

The card requires each variant's semantic stream to repeat exactly and
to equal its same-case, same-budget m5a reference. Two remarks:

- **Repeat-exactness within a family is the load-bearing check** for
  the pairing; it proves the game is not scheduler-dependent, including
  in unpinned mode where server threads float. That is the right gate.
- **Equality with the m5a reference is a stronger, separate claim** and
  can fail for reasons that have nothing to do with the candidate: the
  same binary bytes call the image's glibc, and glibc selects some libm
  implementations at run time by CPU feature (ifunc dispatch). Both
  variants on a given family see the same dispatch, so a cross-family
  difference would show as "both streams differ from m5a, but original
  and candidate still agree with each other". The card says a mismatch
  "stops acceptance and requires investigation"; it should also
  pre-declare how that case is classified so the stop is not read as a
  candidate defect. Bounded suggestion: if the m5a equality fails on a
  family, run one extra same-budget pair on that family (original 256
  and candidate 256, two games) under the existing correctness rule; if
  those two streams match each other, record the cross-family
  difference as a platform finding beside the cross-arch question and
  let the family's timing gates stand on their own repeat-exactness. If
  they do not match, the campaign is incomplete and the investigation is
  mandatory. This adds at most four games and only conditionally.

## 3. Pinned versus unpinned

Testing both on each family, gated independently, is what the 1-CPU
request without a limit calls for. Two details worth writing down before
the runs:

- In pinned mode the presence clients sit on CPUs 6 and 7; on the
  Intel part CPU 5's SMT sibling (13 on a 16-vCPU layout) stays free as
  on m5a, so pinned results remain the conservative single-logical-CPU
  screen. Record `lscpu`'s sibling map with the other host facts.
- `c8i-flex` is a flex family: full CPU performance most of the time
  with possible throttling. Record steal time from `/proc/stat` before
  and after each game and report it with the rows; a game with
  non-trivial steal is still retained, but the report can then say why a
  repetition was slow instead of guessing. That is a recording
  requirement, not a new gate.

## 4. Gates

Per family and cell: median paired total/p50/p95/max <= 1.00, candidate
worst misses <= original's, full-frame and guest coverage, no faults, no
averaging, no discards. These are the m5a gates unchanged, applied per
family, which is what "representative family" requires. Nothing is
missing that would invalidate the qualification claim the card makes;
the claim is scoped to two workloads at 32 seats on two families with
the same bytes, and the card says so. The memory check need not be
repeated (same binaries, same maps); the m5a 16-seat and short-range
cells are explicitly left to the m5a matrix.

## 5. Sequencing and instance handling

Fleet timing only after current-main correctness, training confirmation
and all 36 held-out games pass: correct. Stopping the instance only
between completed campaigns, changing type in place, preserving the EBS
disk and re-recording state, type, kernel, image and binary hashes after
each restart: sufficient provenance. Reusing the binaries is valid
because the flags target baseline x86-64.

## 6. Summary

No count, order, gate or comparator error found. One clarification is
worth adding to the card before it is executed: the pre-declared
classification for a cross-family stream difference (section 2), with
its bounded two-game fallback per family. Two recording additions
(SMT sibling map, steal time) cost nothing and protect the report.

PHASE 16 READY
