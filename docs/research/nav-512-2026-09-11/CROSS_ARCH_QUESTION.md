# Cross-architecture fingerprint question (open)

Native original Nim2.2.4/GCC12.2.0 printed:
ticks1119, suspension_digest-7750959843466495734,
path_digest3301525546362550601, points29546.
Local original/H1/H2/H3 Nim2.2.6/Apple clang17 printed:
ticks1119, suspension_digest5936823674378073636,
path_digest3301525546362550601, points29546.

Do not claim the internal-state digest matches across platforms. The final path
digest and tick/point counts do match; the cause of the internal difference is
not established. jobFingerprint hashes raw float priorities/costs and full
route-cache fields. Hypot/libm rounding or compiler/library differences are
hypotheses, not conclusions. Native H3 vs native original must still match
exactly before H3 timing. Investigate this separately from within-toolchain
candidate exactness; do not normalize away an actual decision difference.
