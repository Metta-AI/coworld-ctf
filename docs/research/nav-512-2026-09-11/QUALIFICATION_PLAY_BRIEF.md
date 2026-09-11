# Bounded qualification support while root times H2

PROCEED P6: implement one test-only WASM controller for the eventual held-out
real-game tests, using the existing play_sdk and real SDK build recipe. Put
source and .nims under docs/research/nav-512-2026-09-11/qualification/; do not
change SDK production APIs or any planner code. Read HELDOUT_DRAFT.md first:
the golden map equals practice; it is not held out.

The play should change its goal deterministically every12 ticks, alternate
carrier/hunter profiles (profile field accepted by emit_validator), set
moving_goal true, and emit only on a new12-tick interval. Pick goals from
opposite interior quarters of the current safe-zone rectangle, with a fixed
fallback only if the view lacks a zone; validate through nearestReachable.
Reuse the existing SDK view decoder and emitRaw byte-array overload. A small
JSON string built from validated integer coordinates is sufficient; don't add
another generalized serializer or export private SDK emit-buffer functions.
Manifest name nav_research_moving, params empty. Log init so the full-game
runner can prove all guest seats loaded; preserve finite fuel/memory limits.

Compile locally through the sanctioned wasi-sdk if available; otherwise record
the exact needed native command. Add a focused test or SDK probe proving the
emitted intent is valid (same profile/moving_goal schema) and interval behavior
if feasible with existing tools; root verifies actual game installation,
profile changes and replans before freezing qualification inputs. No native
host use, timing, commit, budget change, source optimization, or publication.
Write QUALIFICATION_PLAY.md with source paths, commands, limits; end literal
PHASE 6 READY and wait. This is support for qualification, not a benchmark win.
