# Native H3 checks before timing

Original and H1+H2+H3 fingerprints match exactly on Nim 2.2.4 / GCC 12.2.0:
`ticks=1119 suspension_digest=-7750959843466495734 path_digest=3301525546362550601 points=29546`.
Native heap, segment and navigation suites passed. Diagnostic probe raised
IndexDefect and retained diagnosticCaller plus sysFatal, omitting setPosition
as intended. Generated production C was inspected before timing: all eleven
selected helpers lack nimfr_; array-access helpers retain raiseIndexError
checks. Helpers with no array accesses do not need such checks themselves.
Native raw logs and binary hash reside in nav512-h3-results/candidate.
This is within-toolchain exactness; the pre-existing Mac/Linux internal-state
hash difference remains under investigation.

The baseline moving-goal preflight on certified pool505 completed 1200 frames,
exit 0, 32 registered modules. It was concurrent with correctness work and is
excluded from performance acceptance. Detailed install coverage remains to be
summarized. The earlier stale-fixture boot failure is retained separately.
