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
| v49 (pooled) | 717 | 717 | OK | 198 | 198 | OK | 26 | 26 | OK |
| v49_pre_gv16 | 80 | 80 | OK | 19 | 19 | OK | 3 | 3 | OK |
| v49_post_gv16 | 637 | 637 | OK | 179 | 179 | OK | 23 | 23 | OK |
| v50 | 47 | 47 | OK | 14 | 14 | OK | 1 | 1 | OK |
| v53 | 110 | 110 | OK | 41 | 41 | OK | 9 | 9 | OK |

## Result: ALL MATCH

## Fields that could NOT be independently recomputed from episodes.csv
- `declared_sim_pct`, `kickoff_coverage_pct`, `partners_per_commit`, `tags_per_ep_*` are
  pulled from each version's own metrics/report JSON (or, for v44_baseline tags/ep and
  v45/v46/v47/v48 tags/ep, from the prose in CONFIRM150.md / V46_FINAL_VERDICT.md /
  INTERIM.md) because the per-episode tag count and per-episode kickoff-family label
  are not both present in every version's rows.json export -- episodes.csv carries
  per-episode kickoff_present only for v46/v47/v48/v49 (the only versions with a matching
  kickoff_coverage_*_rows.json export); tags per episode is not exported anywhere at
  row level, only as a population aggregate, so episodes.csv leaves `tags` as
  `n/a_not_exported` for every row and the aggregate lives in summary.csv instead.
- v49 (2026-09-09 refresh) now has a full rows.json (n=717, 0 decode failures,
  `v49_full_rows.json` under `/tmp/monet_v49/read/`) and is included in
  episodes.csv / summary.csv like every other version. n / formed_k / win_k
  above are recomputed straight from episodes.csv and cross-checked against
  `v49_full_report.json`'s own `pact_formed_k` / `win_k` fields for the
  POOLED, PRE-GV16 and POST-GV16 splits -- all three match exactly.
  `tags_per_ep_*` for the three v49 rows in summary.csv is NOT taken from
  `v49_full_report.json` (that file's own tags figure, 0.556 mean, uses a
  narrower deed filter than the rest of this dataset); it was independently
  recomputed against `v49_full_rows.json` + the decoded replay cache using
  the same `glory_deed`-any-kind-credited-to-our-seat definition as
  `tags_and_kickoff_final.py` (v45/v46) and `tags_and_kickoff_v48.py` (v48),
  giving pooled mean=1.643, median=1, share_2plus=43.0% (n=717) -- see
  README's tags-definition note for the full method and why the two numbers
  differ.
- `platform_version` for v45 is not stated in any source file read for this dataset
  (grepped all of /tmp/monet_v45/read/*.md and recip/*.md for "platform"); v48's
  platform_version (49) is inferred from v49's SHIPPED.md line "Platform max Monet
  version was 49 pre-upload", not from a v48 file stating it directly.
- v50 (2026-09-09, n=47, rounds 4607-4610, policy_version_id 31e09e78,
  platform_version 51 per SHIPPED.md's "Uploaded policy-monet:v50 ...
  -> Monet:v51") is a fresh read, not a refresh of an existing cohort.
  n / formed_k / win_k above are recomputed straight from
  `/tmp/monet_v50/read/v50_episodes_rows.csv` (itself built from
  `v50_n40_rows.json`) and match `v50_n40_metrics.json`'s own
  `pact_formed_k`=14 / `win_k`=1 fields exactly, with 0/47 decode
  failures. `kickoff_coverage_pct` (85.1%) uses the same `kickoff-reemit`
  broad definition as v48/v49 (see README's kickoff_coverage_pct note),
  computed by `/tmp/monet_v50/read/v50_extras.py` against the same cached
  policy logs. `tags_per_ep_*` (mean 1.574, median 1, share_2plus 38.3%,
  n=47) uses the identical `glory_deed`-any-kind-credited-to-our-seat
  definition as v44-v49 (`tags_and_kickoff_final.py`'s `tags_per_ep()`),
  also computed by `v50_extras.py` against the decoded replay cache
  under `/tmp/monet_v50/read/cache/v50_n40/decoded/`. Marked INTERIM in
  `summary.csv`'s verdict column per the read brief, not because any
  check failed -- see README's Known Gaps.
- v53 (2026-09-09, DECIDING READ at n=110, rounds 4620-4628,
  policy_version_id a3479a93, platform_version 54, GV17/GameVersion 62 --
  the first cohort in this dataset on that era) REPLACES the interim
  v53_n40 read (n=48, rounds 4620-4623) that was previously in these
  CSVs; the interim's 48 episode rows and summary row were removed and
  replaced with the full n=110 set, not appended alongside them, to
  avoid double-counting the shared rounds 4620-4623. n / formed_k /
  win_k above are recomputed straight from `episodes.csv`'s own v53 rows
  and match `/tmp/monet_v53/read/v53_n100_metrics.json`'s own
  `pact_formed_k`=41 / `win_k`=9 fields exactly, with 0/110 decode
  failures. `kickoff_coverage_pct` (81.8%) and `tags_per_ep_*` (mean
  2.736, median 2.0, share_2plus 56.4%) both use the identical
  `tags_and_kickoff_final.py`-derived definitions as v44-v50 (script:
  `/tmp/monet_v53/read/tags_kickoff_v53.py`), run against the same
  decoded-replay/policy-log cache `read_v53.py` built. `partners_per_commit`
  (3.935) is the mean of `aim_partner_counts` flattened across all 110
  episodes' rows, same method as v50's `v50_extras.py`. The comparison
  baseline (pooled v51+v52, n=88) is the same one used for the interim
  read and is NOT itself a row in this dataset's CSVs -- see README's
  GV17 era note. A secondary baseline (whole pre-v53 GV17 population =
  v50 tail rounds 4611-4612, pv 31e09e78, n=25, freshly decoded for this
  read + v51 + v52, n=113) was also read and is likewise not a CSV row;
  it tracks the primary baseline closely (rank<=4 40.7% vs 44.3%) and
  does not change the verdict. `summary.csv`'s verdict column is now
  **KEEP**: at n=110 neither pre-registered rollback trigger fired
  (Trigger A: SR CI-upper=1.0, not <1.0; Trigger B: rank<=4 36.4%
  [40/110] vs baseline 44.3% [39/88], p=0.307, Fisher exact -- NOT <0.10).
  This reverses the interim read's Trigger-B FIRE (22.9% vs 44.3%,
  p=0.0157 at n=48) -- mechanism checks (F4-reach rate flat, death-phase
  showing no earlier dying, unchanged same-round field composition) found
  no support for a real decline, consistent with the n=48 estimate being
  a small-sample low. See README's Known Gaps and
  `/tmp/monet_v53/read/READ_N100.md` for the full read (supersedes
  READ_N40.md).
