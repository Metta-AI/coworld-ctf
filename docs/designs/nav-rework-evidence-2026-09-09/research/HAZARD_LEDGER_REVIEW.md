# Hazard ledger review: the overlay and safe cache are shared nav data the nav ledger omits

Written 2026-09-09 by Claude (peer) at Codex's request. Source and ratified-text review; no
edits. Codex's M2 (capacity-based ledgers) is running on m8i; nothing here is folded into
M2's claimed results, and the finding below is a separate, later correction.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Ownership as it is in the tree
- `initShellEpisode` (`episode.nim:395-407`) owns `result.hazard` (the supplied overlay, or
  `newDarkBodyHazardOverlay()` when none, which is an empty owner with `state = bhsDark` and
  no sequences) and `result.safeCache = newBodySafeCache()`. When route queries are prepared
  it calls `nav.installSafetyContext(hazard, safeCache)` (`body_nav.nim:1041-1047`), which
  stores the overlay in `system.hazard` and hands both references to
  `system.safetyScratch.installSafetyContext`, so `BodySafetyScratch` holds `index`, `hazard`,
  `cache` as references (`body_safety_query.nim:21-24`) next to its fixed-size hash and record
  arrays.
- `BodySafetyScratch.retainedBytes` is `sizeof(scratch[])` only (`body_safety_query.nim:45-46`):
  the fixed arrays, not the payloads behind the three references.
- `retainedNavigationBytes` counts `routeIndex` (by its own ledger, although the episode or
  harness may own it, the precedent Codex noted), `safetyScratch` (sizeof only), and the
  mixed graph and workspace; it has no line for `system.hazard` or the safe cache.
- `BodyHazardOverlay.retainedBytes` and `BodySafeCache.retainedBytes` exist
  (`body_hazard.nim:55-73`, now capacity-based in the working tree) but nothing on the nav
  path calls them.
So in production the overlay and cache payloads are retained for the whole episode, are
read by the nav system on every safety query, and are counted by no gate.

## 2. Does the ratified shared cap include them?
Yes, on three independent readings:
- The design brief's overlay section states its size as retained data ("172 KB / 686 KB",
  `.nav-rework-brief.md:106`, arrival per nav cell on giant and colossal) and lists the
  safe cache as a shared structure recomputed per bucket (line 108); the Asana thread says
  "Shared index, overlay and safe cache persist" across death (comment line 137) in the same
  breath as the index that the ledger does count.
- The Phase 9 harness (`9dce21b6`, the one whose canonical numbers the Asana thread records
  as "retained memory (1.9 MB pool / 28.4 MB colossal)") computed `retained = indexBytes +
  scratchBytes + overlayBytes + safeCacheBytes` after building the overlay from the armed
  snapshot and refreshing the cache once. The 16 MiB pool figure was ratified against that
  sum.
- The Asana description's own phrase is "retained shared nav data", and the overlay and
  cache are shared (one per episode) and nav data (read only by nav's safety queries).
The current harness dropped the two lines when it moved to `retainedNavigationBytes`; the
mixed graph was added, the overlay and cache were lost. That is a ledger regression against
the ratified definition, not a reinterpretation of it.

## 3. Sizes and maximum retention (formulas from the constructors; no new measurement)
- Overlay (immutable per episode): `arrival` uint16 per nav cell, `segmentArrivalMin` and
  `segmentArrivalMax` uint16 per index segment, `roomMaxArrival` uint16 per room, plus the
  owner. Arrival alone: about 85 KB on the largest s2 pool map (42.7k cells), 172 KB on the
  giant maps, 686 KB on colossal (the brief's figures). Segment arrays add
  `4 * segments` bytes. All `newSeq` to a computed count, so `capacity == len`.
- Safe cache (mutable, one instance): `safeDistQ4` uint32 and `safeNext` uint16 per portal
  side, `roomHasDry` bool per room, rebuilt by `newSeq` on every key change (overlay
  fingerprint, game generation, or 48-tick bucket roll; `body_hazard.nim:198-226`). Maximum
  retention is one set: `6 * sides + rooms` bytes plus owner. Because `newSeq` replaces the
  old sequences, the transient peak during a refresh is two sets for the duration of the
  assignment; the old payload is released immediately. Nothing accumulates across buckets.
- Dark overlay (no zone armed): owner only, no payloads.
These are small next to the 16 MiB cap (hundreds of KB at most on colossal) and cannot flip
the giant-map failure, but on the s2 pool the L1 margin was 753,615 bytes, and the overlay
plus cache plus their headers belong inside it.

## 4. What the harness measures today, and why it is incomplete
- `activationRow` builds a bare nav system with a prepared index and no `installSafetyContext`
  (`bench_body_nav_rework.nim:214`), so its ledger cannot see the overlay or cache even if
  the nav ledger counted them; the `rss_delta_bytes` there also excludes them.
- `tickRow` and the latency rows build `newBodyHazardOverlay(index, map.armedSnapshot)` and
  pass it into the episode, so the timing rows run with the overlay and cache installed and
  live, which is the production shape; they just do not ledger it.
- Net: every retained-memory pass so far (B0, M0, L1, and M2 when it lands) was computed
  without the overlay and cache payloads. Verdicts: the giant-map failures stand; the s2 pool
  passes need the two lines added before they can be called complete, with the expected
  effect being at most a few hundred KB against a 753 KB margin.

## 5. Minimal complete measurement (proposal; Codex owns)
1. Nav ledger: add `hazardOverlay` and `safeCache` lines to `BodyNavigationBytes`, filled
   from `system.safetyScratch`'s references (or `system.hazard` and the scratch's cache) via
   the existing capacity-based `retainedBytes` procs, counted once, and included in `total`.
   Attribute them as shared (they are one per episode) so the harness's shared upper bound
   picks them up automatically. A nil overlay or cache counts zero.
2. Harness `activationRow`: build the overlay from `map.armedSnapshot` and a fresh safe
   cache, `installSafetyContext` on the nav system, and refresh the cache once
   (`refreshSafeCache(index, overlay, 0, 1)`, exactly as the Phase 9 row did) before reading
   the ledger, so the row measures the production shape at maximum cache retention. Emit the
   two lines in `retained` and include them in `shared_retained_upper_bound_bytes`.
3. Keep `BodySafetyScratch.retainedBytes` as the scratch's own fixed size; do not count the
   payloads there too, or they double count.
4. Test: a ledger self-test that `total` equals the sum of its lines and that
   `hazardOverlay` equals `overlay.retainedBytes` computed independently; and the existing
   capacity self-check extends to the overlay and cache sequences (both exact-built).
5. Report: the next activation rows carry the two new lines; the prior rows get a one-line
   caveat ("overlay and safe cache not counted; expected at most a few hundred KB"), appended,
   not rewritten. M2's capacity-only numbers stay reported as capacity-only, with this
   ownership gap listed as a separate open item, per Codex's instruction.

## 6. Limits of this review
No sizes were measured here; the formulas are from the constructors and the brief's stated
arrival sizes. Whether the production overlay carries the segment arrays populated (it does
when the zone is armed; the dark overlay carries none) is a runtime state the row must choose
explicitly, and the armed snapshot is the conservative choice.
