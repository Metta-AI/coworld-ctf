# Restore findings: closure check

Verified read-only in the peer scratchpad against `RESTORE_FOLLOWUP.md`.
No native use, build, production edit or commit. Frozen cards were not
touched by the root and their sidecar hashes were already verified in
`RESTORE_REVIEW.md`.

| Finding (P18) | Closure | Verified |
|---|---|---|
| Guest module bytes not archived | `guest-modules.tar.gz` with `guest-modules.sha256` | Sidecar `24657a95...` matches the archive bytes. Extracted members restore `play_sdk/.build/edge_ride.wasm` (23,403 bytes) and `docs/research/nav-512-2026-09-11/qualification/.build/nav_research_moving.wasm` (6,748 bytes); each member's SHA-256 equals its pin in `current-main/assets.json` (`52467f15...`, `d51b9cf8...`). The note that the root's local `edge_ride` build differed from the pin and was not substituted is the right call; the archived bytes are the benchmarked ones. |
| `production.patch` missing from the tree | `RAW_ARTIFACTS.md` now states that the card's and provenance note's `production.patch` reference means the copy restored from `source-and-profile-text.tar.gz` | Wording present at lines 22-26; the restored copy was shown in P18 to equal `git diff 58e6c947 c651dec9 -- src`. Frozen `current-main/CARD.md` unchanged (hash still matches). |
| H1 archive hash only in prose | `H1/raw-games.sha256` | Contains `117188ab...`, equal to the archive bytes and to `H1/RESULT.md`. |
| No viewer QA record at `c651dec9` | `checks/viewer-at-c651.txt` | Ten `PASS` lines including "committed wasm GameVersion matches" and "committed wasm sim-sources stamp matches HEAD". The root tree's HEAD is `c651dec9` and `src`, `replay-viewer`, `nimby.lock` and `static-replay-viewer` are clean, so "HEAD" is the checkpoint; this agrees with my P18 recomputation (`ed013f98...` present in the committed wasm). The file does not print the commit id or the stamp value itself; the filename carries the commit, which is adequate, and a future record could include both for self-containment. |
| README status one step behind | README updated | Now records all twelve current-base correctness games passed, the six training-confirmation games passed with worst misses 31 versus 109, and that the 36 held-out timing games are running with no held-out or fleet verdict available. |

All five findings are closed as evidence repairs. Nothing in this pass
changes an input, a gate, a frozen card or a result, and no acceptance
claim beyond training confirmation is made anywhere in the updated
files.

PHASE 19 READY
