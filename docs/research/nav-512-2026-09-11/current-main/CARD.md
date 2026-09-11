# Current-main confirmation before final qualification

Frozen before current-main performance runs. Base is origin/main 58e6c947;
root merged it at 46ddc845. Runtime delta since the earlier screens is scoring
(glory.nim); other upstream changes affect docs, manifest and viewer. Preserve
all earlier results as evidence at 6b6b3408. Do not combine timing pairs across
bases or call an old-base campaign final qualification.

Candidate is the unchanged H1+H2+H3 mechanisms plus documentation nits, captured
in production.patch. Default remains256 in the source checkpoint. Build separate
256/512 binaries, record every source and binary hash and pin the same native
Nim/GCC/image/flags and guest WASM bytes. No extra optimization is introduced.

First complete same-budget256 exactness on the six held-out cells under the
frozen qualification/PROTOCOL.md, using newly built original and candidate.
Older-base correctness may finish, but cannot replace these runs.

Then confirm the training target with three original256/candidate512 pairs,
1,200 frames,32 seats and training-config.json (identical to the H3 inputs).
Orders: original/candidate, candidate/original, original/candidate. Apply the
same target thresholds: median paired total/p50/p95/max<=1, candidate worst
misses<=original, no faults, same semantic stream across repetitions. Retain
all runs, without warmup or outlier exclusions. These six games are confirmation
of the already-passed H3 target, not a newly selected optimization screen.

Only if current-base correctness and training confirmation pass, run all36
held-out performance games under the unchanged six-cell protocol. No build,
profile or compression overlaps these timings. Common-family and unpinned
qualification still follows its own preregistered hardware card.
