# Held-out qualification draft (not frozen, no runs yet)

Important discovery: config.practice.json mapSpec and
 tests/fixtures/br-golden-map.json are the SAME geometry, including genSeed4242
(normalized JSON SHA2564c6121fb63c27156e51376ceca6e9d2c46fe216f9f27c213d9c4d42bffef8f65).
The replay recipe's seed4248 does not make that fixture a second map. Existing
cross-build tests used the training geometry; do not count it as held out.

Existing distinct checked-in inputs:
- br-match-map-r9-301.json:3211x1713, genSeed301, normalized SHA256
  b5863f671fbafbd7c39a9bd72d43a6af967052c81c3339c6dbdbea9a624fdd9f.
- br-match-map-14005.json:3211x1713, genSeed14005, normalized SHA256
  37c58b6da3fbf440d209f8175735532907f9aaf7bddfb0f323662a10c32b8456.
Use both at16/32 seats, gun ranges331/1050, plus the training map16 seats497.
Add an independently generated different-size map and colossal memory case.

Guest diversity should use existing reference plays where they exercise the
intended path (scatter/bodyguard/jackal), after inspecting actual navigation
profiles and replan behavior. A filename alone is not evidence of moving-goal
coverage. Add a test-only moving-goal play only if existing plays do not cover
it deterministically. Preserve full real-game frame, legality and fault gates.
Current draft is a proposal; freeze exact inputs/rosters/criteria before running
any candidate held-out timings. Common production CPU-family qualification and
an unpinned burst comparison remain outstanding.

Different-size map preparation uses the existing BR authoring CLI with
--scale2.9 (supported doctrine variant), not the deprecated classic generator.
Try seed5120911 first; if the real validators reject it, retain the rejection
and take the first passing seed in5120912..5120920, without inspecting any
performance result. Convert through br_spec_to_ctf, then freeze output hash.
Local map generation uses Nim2.2.6 and the CommandLineTools SDK; native timing
remains pinned to Nim2.2.4.

For the moving-goal workload, use nav_research_moving (P6): moving_goal true,
carrier/hunter alternation, opposite zone-quarter targets every12 view ticks,
one emission per interval through the real SDK. Validate actual installs and
replans before freezing the benchmark. Set hitPoints1000 for this deliberate
32-seat stress workload to keep early combat deaths from silently removing the
planning load; retain normal health for the realistic edge_ride cases. An early
ending is a coverage failure, not a cheap timing win. Do not compare totals over
unequal tick counts or silently truncate a slow/failed run.

## Preflight correction

The older301/14005 match fixtures fail current engine boot: no shieldSpawns
pool on a flagless16-group BR map. Both also lack spray pools. Their proposed
configs are retained under qualification/rejected-stale-fixture-configs and
the failed baseline preflight is archived. Replace them with the first two
entries of the current certified data/br_map_pool.json (505,5001), selected by
file order before timing, not by candidate performance. Add larger32-seat
1050-range moving stress as a sixth cell. New proposals/hashes are generated
by qualification/prepare_cases.py; still not frozen for performance.
