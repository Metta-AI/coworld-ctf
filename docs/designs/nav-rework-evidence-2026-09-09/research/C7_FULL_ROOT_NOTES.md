# Root notes for the C7 full freeze

Both-host v2micro nowpasses; C7_NATIVE_MICRO_REPORT.md has all120rows. A7 native comparison finished, fails5%both-host threshold (m5a3.8%); primary source remainsC2, A6/A7unintegrated.

When freezing C7full: the addVisibleCell comment saying beyond1050px is wrong for331px range. Say zero kernel weight or beyond min(live range,DangerLosRangePx), as C8_ROOT_REVIEW already established. Keep the cache owner allocation allowance distinct: isolated C2 parent omitted16Bowner allowance; rootintegrated source alreadyincludes it and will preserve it on application.

The full/baseline directory copied all repository tools. Root will preserve that local backup but exclude unrelated existing tools from the evidence commit; identify the small set of cache/trace/check tools actually needed. No need to edit unrelatedfiles.

## Test correction found in the frozen diff

The stale-entry test currently inserts64other origins after the long source, which already evicts the original long slot; the short source then reuses a different slot. Change this to63other unique origins (slots minus1), assert the long key remains before the short miss, then assert it disappears after that miss. This guarantees the short list overwrites the exact long slot whose prior length the test measured, making the stated stale-tail risk test real. Keep the short-length comparison and independent uncached raster check.
