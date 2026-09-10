# Current research state after the memory ruling and P1

The goal remains active and incomplete. Source checkpoint 067a4af2 includes main 3c127d1c. The shared cap is 32 MiB, the total cap is 256 MiB, and B1024 remains provisional. James permits up to 4x the original non-colossal caps as needed. Timing, quality, determinism and activation requirements remain unchanged.

CAP32 passes memory on all 76 maps: configured shared maximum 31,607,620 bytes; total maximum 266,478,979 bytes. Full 3072-case quality is unchanged. All 75 non-colossal maps still exceed the inherited 2x activation ratio; colossal passes 3x.

## Completed experiments

- D0a retained at 8fe2cbad: worst p95 5.948740 -> 5.838907 ms.
- D1 rejected at 490a96be: 5.839953 -> 5.936474 ms; restored D0a.
- P1 retained at 09ae4721: 5.828086 -> 5.242172 ms; weight refresh 1.092082 -> 0.423183 ms. No empty/sparse diagnostic regression observed.

All masks, pops, full quality and retained ledgers match their parents. Both server shapes, focused tests and viewer stamps pass. None of this establishes final acceptance.

## Main sync and remaining qualification

The P1 command batch mistakenly committed after fetch reported behind=1. It was corrected immediately by merging 3c127d1c; see MAIN_3C127D1C_SYNC.md. Never batch fetch and commit without an explicit freshness guard.

Main's wire change uses GV63; origin/maxwell/glory-s8-ship claims GV64. Navigation is now GV65. The incoming nine fixtures and capture claims are main's GV63 artifacts, pending re-recording at the final selected budget as required by the handoff. The rebuilt viewer matches GV65 and merged source; the version guard passes. Final fixtures, full tests, containment, canonical Docker, latency, budget selection and Phase10/11 remain incomplete.

## Next work

Preregister and implement the exact ray-set wavefront prototype from WF0_IMPLEMENTATION_PLAN.md. It is not implemented yet. The peer's 885 standalone trials match; proof scripts and outputs are being preserved in peer-proofs. Claude is also reviewing ACTIVATION_NEXT.md's exact construction shortcuts. The peer is in tmux nav-research-peer with a bounded read-only review task; root owns production code.

## Hosts and worktrees

Owned m5a: ubuntu@3.90.148.165. Owned m8i: ubuntu@54.91.165.255. All P1 runs are done and retrieved; no benchmark is active. Fresh wavefront worktrees at 067a4af2 were created from the verified bundle and configured with Nimby 0.1.26. Keep the old owned checkout and results. c6a and c8i are stopped. Protected m6i 3.81.19.75 and its live ~/metta tournament remain untouched.

No CLI was used for these experiments. Live config remains unverified because the DB connection was refused. No Asana, push, PR, publishing or production writes are authorized.

The primary consolidation backup remains in sibling nav-throughput-root-backup-20260909. The auxiliary checkpoint worktree remains at addaad7a. Stash 8dcfb570029db7424b614c2bf3036fd29d54da99 is retained and must not be reapplied. The original protected coworld-ctf checkout remains untouched.
