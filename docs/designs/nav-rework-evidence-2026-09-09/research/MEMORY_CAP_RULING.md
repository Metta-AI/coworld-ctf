# Memory cap ruling — 2026-09-09

## RATIFIED: James's current instruction

“Ok, fter some consultation, you are welcome to raise memory caps of non-collossus maps (which already have larger memory budgets) by up to 4x as needed”

This supersedes the earlier prohibition on raising non-colossal memory caps. Colossal's existing256 MiB total cap remains unchanged. The permission is an upper bound, not a requirement to allocate four times as much memory.

## Implementation decision

Use32 MiB (33,554,432 bytes) for the shared-navigation cap on non-colossal maps, twice the previous16 MiB. The latest complete W6 configured screen has maximum 31,607,620 bytes, leaving 1,946,812 bytes of margin. The total navigation cap remains256 MiB on every map because no measured map needs an increase. Retain full capacity and installed-context accounting from M1/M2/M3.

Earlier16 MiB failures remain valid historical results under that limit. Do not rewrite raw artifacts or turn them into passes retroactively; new gate results must record the new32 MiB limit. No timing, quality, determinism or activation threshold is changed by this ruling.

The proposed bridge/workspace compression programme is no longer required to meet the observed memory gate. Do not implement those structural changes merely to recover the superseded16 MiB target. Retain the design/review notes as proposals and focus on throughput and final qualification. The harness now enforces and reports the 32 MiB shared limit. The design HTML carries this ruling above its historical measurements. Fresh CAP32 memory qualification passes all 76 maps; see CAP32_REPORT.md. Timing and activation-time requirements remain unresolved.

## C2 integrated readback

The fresh C2+V1+A4+H1 ledger passes all 76 maps. Maximum non-colossal shared bound is 32,464,268 bytes, leaving 1,090,164 bytes under 32 MiB; maximum total is 229,158,347 bytes. This includes the cache owner allocation allowance corrected during integration. No additional cap increase is needed. See C2-integrated-memory-summary.json and C2_INTEGRATION.md.
