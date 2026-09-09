# CHECKS -- recomputed from episodes.csv vs source metrics.json

Recompute method: for each version, count rows in episodes.csv (n),
count rows where formed==True (formed_k), count rows where win==True (win_k).
Compare against the pact_formed_k / win_k fields already computed by the
original read pipeline's own metrics.json for that version (the same file
the VERDICT/READ markdown tables quote).

| version | n (csv) | n (source) | match | formed_k (csv) | formed_k (source) | match | win_k (csv) | win_k (source) | match |
|---|---|---|---|---|---|---|---|---|---|
| v44_baseline | 172 | 172 | OK | 6 | 6 | OK | 12 | 12 | OK |
| v44_gv15_control | 25 | 25 | OK | 1 | 1 | OK | 0 | 0 | OK |
| v45 | 106 | 106 | OK | 5 | 5 | OK | 5 | 5 | OK |
| v46 | 96 | 96 | OK | 9 | 9 | OK | 1 | 1 | OK |
| v47 | 12 | 12 | OK | 0 | 0 | OK | 1 | 1 | OK |
| v48 | 37 | 37 | OK | 11 | 11 | OK | 4 | 4 | OK |

## Result: ALL MATCH

## Fields that could NOT be independently recomputed from episodes.csv
- `declared_sim_pct`, `kickoff_coverage_pct`, `partners_per_commit`, `tags_per_ep_*` are
  pulled from each version's own metrics/report JSON (or, for v44_baseline tags/ep and
  v45/v46/v47/v48 tags/ep, from the prose in CONFIRM150.md / V46_FINAL_VERDICT.md /
  INTERIM.md) because the per-episode tag count and per-episode kickoff-family label
  are not both present in every version's rows.json export -- episodes.csv carries
  per-episode kickoff_present only for v46/v47/v48 (the only versions with a matching
  kickoff_coverage_*_rows.json export); tags per episode is not exported anywhere at
  row level, only as a population aggregate, so episodes.csv leaves `tags` as
  `n/a_not_exported` for every row and the aggregate lives in summary.csv instead.
- v49 has no rows.json (ship-verification pass only, 8 episodes scanned by hand in
  SHIPPED.md's table, different schema) -- excluded from episodes.csv entirely, and
  summary.csv's v49 row is n/a on every ladder-read metric by design.
- `platform_version` for v45 is not stated in any source file read for this dataset
  (grepped all of /tmp/monet_v45/read/*.md and recip/*.md for "platform"); v48's
  platform_version (49) is inferred from v49's SHIPPED.md line "Platform max Monet
  version was 49 pre-upload", not from a v48 file stating it directly.
