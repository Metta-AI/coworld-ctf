# Pre-run implementation notes for the frozen protocol

Peer P10 review accepted the bounded six-cell coverage and raised details to
make execution reproducible. These clarify the frozen gate; they do not change
its configurations, thresholds or handling of failed/early games.

- Attach hashes of both native-built guest WASM modules and the server/presence
  binaries before the first correctness run. Config hashes alone do not pin
  gitignored guest module bytes. Verify them before each campaign.
- The protocol's twelve same-budget correctness games run before its thirty-six
  performance games. A semantic mismatch stops the campaign before timing.
- View cadence is six ticks. Expect at most one moving-play emission per
  observed twelve-tick interval; a missing valid goal can prevent emission.
  Confirm both carrier and hunter installs, moving_goal=true, and their cadence.
  Moving-goal follower replans and stuck replans can add revisions between
  installs; revision count need not equal install count.
- All moving seats converge on two points. Late collision/stuck work is part
  of this stress case; report pending/no-path/stale counts without calling them
  independent route-quality measurements.
- Memory measurement: calculate constructor allocation bytes per map/seat count
  and measure process RSS after newBodyNavSystem activation, using separate
  parent/candidate processes on the same geometry. Retain absolute bytes and
  deltas. H1-H3 change no capacities, types or allocations; expect identical
  logical bytes. RSS can include allocator variation and must be labeled.
- No fallback-health rerun is currently authorized by this card. An early
  ending fails coverage and stays recorded. Any later replacement requires a
  new preregistration and a separately named campaign; it does not rescue the
  original result.
