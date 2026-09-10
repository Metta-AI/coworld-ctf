# Exact composition of the primary changing/repeated regime (counts only)

Tool: `bench_body_danger_cache_counts.nim` is root's primary
`tools/bench_body_danger_cache.nim` (the tool `run_c9_full.sh` copies) with one
added line, `row["conversions"] = %counts.conversions`, so the candidate's
conversion counter is emitted next to hits and misses. Nothing else changed.

Built in the peer-owned `nav-source-cache` tree against the frozen C9 candidate
(`src/shell/body_nav.nim` SHA-256 prefix `ad45ee0733ddc650`, unchanged before
and after the run):

```
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
nim c -d:release -d:dangerSourceCacheCounters --hints:off \
  -o:tmp/c9review/regime_counts tools/bench_body_danger_cache_counts.nim
./tmp/c9review/regime_counts > tmp/c9review/regime_counts.json
```

`regime_counts.json` carries Mac timings that are informational only and are
not used anywhere. What is used: the counters and the raster fingerprints. All
eight fingerprints equal the `raster_fingerprint` of every one of the 48
native rows (m5a and m8i, parent and candidate, three runs each), so the
native timing runs exercised exactly this lookup sequence.

| map | regime | hits | misses | conversions |
|---|---|---:|---:|---:|
| br-gen-5001 | changing_sources | 27 | 1,509 | 27 |
| br-gen-5204 | changing_sources | 26 | 1,510 | 26 |
| br-gen-5263 | changing_sources | 15 | 1,521 | 15 |
| colossal | changing_sources | 6 | 1,530 | 6 |
| every map | repeated_sources | 1,528 | 8 | 8 |

Lookups per regime: 192 rebuilds x 8 sources = 1,536.
