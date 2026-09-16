# C9 diagnostic review: frozen-binary disassembly on m5a

Reviewed: `C9_DIAG_DECISION.md`, `C9/disassembly/m5a.json` (both arms'
symbol tables, sizes, addresses and assembly), and the five normalized diffs
in that directory. Documents only. C9 stays rejected under the registered
m5a changing-regime gate; nothing here reopens it, and no timing or
implementation is proposed for this unit.

## 1. Corrections applied to `C9_FULL_REVIEW.md`

Root's two corrections are right and are now in the file:

- The micro conversion figure is an average over warm, repeated conversions
  of one origin. It is not an upper bound on a cold per-origin conversion in
  the regime (fresh entries region, cold bitmap). The section 4 table and
  text now say "estimate", and the verdict says conversion is an unlikely
  explanation under that cost model, not that counts rule it out. The
  arithmetic is unchanged: at the micro average, conversions come to 0.01
  to 0.03 percent of the regime total against a 1.2 to 1.6 percent excess,
  so a cold conversion would need to cost 40 to 90 times the micro average.
  Implausible, not excluded.
- "Bounded away from the conversion path" in section 6 is replaced by
  "judged unlikely, not excluded".

## 2. What the disassembly shows

Symbols from `m5a.json` (the same binaries ran on both hosts; all five
hashes match per root):

| function | parent addr / size | candidate addr / size | addr mod 64 | normalized diff |
|---|---|---|---|---|
| castRay | 0xc7140 / 4,609 B | 0xc7180 / 4,609 B | 0 / 0 | empty (885 instructions identical) |
| rebuildDangerFromPoints | 0xc8350 / 3,136 B | 0xc8390 / 3,192 B | 16 / 16 | slot offsets, list init and dispatch, register renames, nop padding |
| sourceCacheSlot | 0xc6560 / 223 B | 0xc6600 / 223 B | 32 / 0 | one slot-offset constant |
| sourceCacheVictim | 0xc6ed0 / 247 B | 0xc6f10 / 247 B | 16 / 16 | two slot-offset constants |
| materializeVisibleCells | absent | 0xc66e0 / 1,446 B | 32 | new |
| replayListEntries | absent | 0xc6c90 / 639 B | 16 | new |

Reading of the diffs, function by function:

- `castRay` is instruction-identical and shifted by exactly 64 bytes, so
  every loop head and branch target inside it keeps its alignment modulo 64,
  32 and 16. Relative code alignment on the ray walk is the same in both
  arms. `addVisibleCell` has no symbol in either arm; it is inlined (the
  generated C already showed `static N_INLINE`), and since `castRay` is
  identical it is inlined identically.
- `rebuildDangerFromPoints` grew by 56 bytes. The normalized diff contains:
  the slot array base moving from object offset 0x18 to 0x30 and the clock
  from 0x418 to 0x430 (the cache object gained `capacity` and `entries`
  ahead of the slots); the miss-path slot store gaining one
  `movl $0xffffffff,0x34(%rax)` (`listLength = -1`); the hit path testing
  `listLength` and dispatching to `materializeVisibleCells` or
  `replayListEntries` instead of calling `replayVisibleCells`; a handful of
  register renames in prologue and stack-frame setup; two added nop
  paddings. No added spill in the per-source loop, no change to the
  `castRay` call sequence, no change in inlining. The per-source miss path
  therefore differs by one extra 4-byte store per miss plus the offset
  constants and register renames; no obvious large instruction-level
  regression, and the effect of these differences was not measured.
- `sourceCacheSlot` and `sourceCacheVictim` differ only in the slot-offset
  constant; both are 64-iteration scans over 16-byte slots, invoked once
  per lookup. `sourceCacheSlot` moves from 32 to 0 modulo 64, so its entry
  alignment changes; the relative-alignment statement above applies to
  `castRay` only, not to the whole miss path.

Conclusion from the code side: no obvious large instruction-level
regression in the miss path (`castRay` identical; the surrounding function
differs by a store, offsets and register renames whose effect was not
measured; one small function's alignment changes). What the disassembly
cannot exclude:

- Absolute placement. All shared functions sit 64 bytes later in the
  candidate, and the two new functions occupy 2 KB between
  `sourceCacheSlot` and `sourceCacheVictim`. Instruction-cache set and
  branch-predictor aliasing depend on absolute addresses and on what else
  maps to the same sets, which normalized diffs do not see. The 64-byte
  shift keeps line alignment but not set indices for the whole text
  region. Whether this host is sensitive to that is not established here.
- Data placement. The candidate's cache object is 24 bytes larger ahead of
  the slot array, and it allocates the 27.7 MB entries region at
  construction. Every heap allocation after that (raster, visited
  generations, kernel copies, bitmap words) can land at different
  addresses than in the parent, changing L1 and L2 set aliasing among the
  arrays the ray walk touches. The hosts differ in cache size (from the
  recorded `lscpu`: m5a 512 KB L2 per core, m8i 2 MB), but a hardware
  difference alone does not establish a cause; it only says the two hosts
  need not behave alike. m8i, running the same binaries, showed no excess.
- Noise. As recorded in `C9_FULL_REVIEW.md`, the parent's own run-to-run
  spread on m5a is 0.8 to 2.0 percent, the same size as the measured
  excess; only br-gen-5263 is clearly outside it.

None of these can be separated from each other with the existing
artifacts, and none of them would change the gate outcome, which was
registered as three pairs and failed.

## 3. Standing statements

- C9 remains rejected under the m5a changing-regime gate; the 1.01 limit
  is unchanged; no adoption. The C9 source in nav-deferred-cache has been
  restored; that tree is now the A8 experimental tree, not a frozen C9
  candidate. The C9 candidate remains frozen only in the peer's
  nav-source-cache tree and under `C9/full/snapshots/`.
- Conversion is an unlikely explanation under the micro cost model, not an
  excluded one. `castRay` is normalized instruction-identical; the rest of
  the miss path shows no obvious large instruction-level regression, with
  its small differences unmeasured; absolute code placement, data
  placement, and three-pair noise on m5a remain open and are not
  distinguished.
- No timing or implementation is proposed for C9. If root ever wants to
  spend a run on this host, the parent-versus-parent null pair set named in
  `C9_FULL_REVIEW.md` is the only one that informs a future screen design
  without touching the candidate, and it is root's call, not a request.
- A8: root owns the implementation in nav-deferred-cache on current A4
  source; the peer will not edit A8 code or run native jobs. Handoffs stay
  in this repository.

C9 DIAGNOSTIC REVIEW READY (wording corrected per C9_DIAG_WORDING_FOLLOWUP.md)

C9 WORDING FINAL READY
