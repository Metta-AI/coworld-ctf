# Validation at 46ddc845 plus H1-H3

All four release runtime-linked shards exited0. Counts: {1: {'passed': 429, 'failed': 0}, 2: {'passed': 799, 'failed': 0}, 3: {'passed': 650, 'failed': 0}, 4: {'passed': 423, 'failed': 0}}.
Both runtime-linked and runtime-stub server nim checks passed. Docker viewer
rebuild and node tools/qa_module_eval.cjs passed, including GameVersion and
sim-sources stamp. Native current-base checks and qualification are recorded
separately. Prior-base full suite logs remain in the parent checks directory.
