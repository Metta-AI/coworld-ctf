# Memory cap ruling — 2026-09-09

## RATIFIED: James's current instruction

“Ok, fter some consultation, you are welcome to raise memory caps of non-collossus maps (which already have larger memory budgets) by up to 4x as needed”

This supersedes the earlier prohibition on raising non-colossal memory caps. Colossal's existing256 MiB total cap remains unchanged. The permission is an upper bound, not a requirement to allocate four times as much memory.

## Implementation decision

Use32 MiB (33,554,432 bytes) for the shared-navigation cap on non-colossal maps, twice the previous16 MiB. The latest complete W6 configured screen has maximum 31,607,620 bytes, leaving 1,946,812 bytes of margin. The total navigation cap remains256 MiB on every map because no measured map needs an increase. Retain full capacity and installed-context accounting from M1/M2/M3.

Earlier16 MiB failures remain valid historical results under that limit. Do not rewrite raw artifacts or turn them into passes retroactively; new gate results must record the new32 MiB limit. No timing, quality, determinism or activation threshold is changed by this ruling.

The proposed bridge/workspace compression programme is no longer required to meet the observed memory gate. Do not implement those structural changes merely to recover the superseded16 MiB target. Retain the design/review notes as proposals and focus on throughput and final qualification. Code and authoritative design updates are pending the current branch sync/checkpoint work.
