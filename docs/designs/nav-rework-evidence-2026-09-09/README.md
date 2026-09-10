> **Parked 2026-09-10:** [Start with the durable archive and restore instructions](park-2026-09-10/README.md). These are research records; the archived navigation implementation is not active on main.

# Evidence for the navigation rework exploration (2026-09-04 to 2026-09-09)

Transcript of the session that produced all of this: https://claude.ai/code/session_01H4Tq8mKE8YCb7mvENxWfct (session_01H4Tq8mKE8YCb7mvENxWfct). That transcript is the primary source; everything here was either written by the Codex implementer into the session scratchpad and copied unchanged, or reconstructed from what the transcript shows.

The narrative record that indexes and interprets these files is `../nav-rework-exploration-record-2026-09-09.md`.

## How the copies were made

- `scratchpad-impl/`: a byte-for-byte copy (`cp -R`) of `<session scratchpad>/impl/` taken on 2026-09-09 while Phase 10 was starting. Written by Codex (the implementer, gpt-5.6-sol via the Codex CLI) except for the `PROCEED_*.md`, `FIXUP_*.md`, `RESOLVE4_P2.md`, `INVESTIGATE_P9.md`, `CAMPAIGN_P9B*.md`, `PLAN_P10_REQUEST.md` files, which were written by Claude (the orchestrator) as dispatches to Codex. Nothing was edited.
- `claude-orchestrator-LEDGER.md`: Claude's own running ledger from the scratchpad root, copied unchanged.
- `reconstructed-from-transcript/`: files that were in the scratchpad during the work but had been deleted by the macOS temporary-file cleaner (by access age) before this copy was taken. Each was re-created from the session transcript. Provenance per file:
  - `PLAN.md`: the persisted tool-result dump of `cat PLAN.md` from 2026-09-04 17:15 (`~/.claude/projects/.../tool-results/blqjbd073.txt`), first line (the `wc` line) removed. Verbatim.
  - `REVIEW.md`, `VERDICT.md`, `VERDICT2.md`: Codex's three design-review replies as printed by `cat` in the transcript on 2026-09-04. Verbatim; the reconstructed `REVIEW.md` and `VERDICT.md` byte counts (15,855 and 8,725) equal the original file sizes recorded by `ls -la` in the transcript.
  - `DRAFT_DESIGN.md`, `RESPONSE.md`, `RESPONSE2.md`, `BRIEF.md`, `VERDICT_PLAN.md`, `PROCEED_P2.md`, `RESOLVE_P2.md`, `RESOLVE2_P2.md`, `RESOLVE3_P2.md`: written by Claude as shell heredocs in the transcript; re-created from those heredocs. `BRIEF.md` includes the two later in-place patches (the wasmtime path line and the appended "Commit drift" section). The reconstructed `DRAFT_DESIGN.md` is 21,134 bytes against an original 21,082, so treat it as near-verbatim rather than byte-exact.
  - `nav_census.tsv`, `cell_probe.tsv`, `seg_probe.tsv`: the probe tables exactly as printed in the transcript (column headers added from the transcript's own descriptions). The map labels `pool:N` in these three files refer to the LEGACY `map_pool.nim` entries used by the bench tool, not to `data/br_s2_map_pool.json`; the implementation plan (PLAN.md section 0) made that distinction explicit.
  - `PHASE_1_REPORT.md`: reconstructed from two displayed windows (`head -150`, `sed -n 150,220p`); the join is exact, the tail may be truncated; see the note at its top.
  - `s2-cog-body-tick-report-as-read-2026-09-04.md`: the pre-existing research report `docs/reports/s2-cog-body-tick-2026-09-03.md` as it was read on 2026-09-04 (persisted tool output); kept only because the design brief cites it.
- `asana-task-1218165906459726-comments.md`: the task's comment thread as fetched via the Asana MCP on 2026-09-09; index of all twelve comments plus four reproduced verbatim.

## What is NOT here

- The design collab directory's probe source files (`cell_probe.nim`, `seg_probe.nim`) were lost with the scratchpad cleanup; their outputs survive in the three TSVs above and their logic is described in PLAN.md section 0 and in the record.
- Raw Docker gate JSON/log files from Phase 9 (`/tmp/nav-gate-amd64-final.json` etc.) and the P9B experiment JSON/TSV artifacts lived in `/tmp` and the worktree's untracked paths; the reports quote them, and the Phase 10 raw rows are copied under `scratchpad-impl/phase10-logs/`. Phases 5, 6, 7 raw logs are under `scratchpad-impl/phase5-logs/`, `phase6-logs/`, `phase7-logs/`. No raw logs exist for Phases 2, 3, 4, 8, 9 or the campaign rounds other than what the reports quote.
- The branch itself: `james/s2-nav-rework` in `/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-rework` (not pushed at the time of writing). Every experiment cited in the reports is a commit there; hashes are in the record.

## File list (scratchpad-impl)

- `LEDGER.md` — Codex's decision ledger, D001–D054, with per-phase open-risk lists.
- `PHASE_2_REPORT.md` … `PHASE_9_REPORT.md` — Codex's phase reports with commands, outputs, and git state. (`PHASE_1_REPORT.md` is in `reconstructed-from-transcript/`.)
- `PHASE_10_REPORT.md` — the P10.0 pop-budget ruling packet (measurement only).
- `PROCEED_P3.md` … `PROCEED_P10.md` — Claude's gate messages accepting the previous phase and dispatching the next; `PROCEED_P10.md` carries James's three rulings.
- `FIXUP_P3.md`, `FIXUP_P4.md` — Claude's fix-up demands after Phase 3 and Phase 4 gates.
- `RESOLVE4_P2.md` — Claude's fourth Phase 2 ruling (pixel-grid pocket connectors); RESOLVE 1–3 are reconstructed.
- `INVESTIGATE_P9.md`, `P9_INVESTIGATION.md` — Claude's investigation brief after the Phase 9 gate failure and Codex's investigation report.
- `CAMPAIGN_P9B.md`, `CAMPAIGN_P9B_REDIRECT.md`, `_REDIRECT2.md` … `_REDIRECT5.md`, `CAMPAIGN_P9B_IDEA_DANGER_ADAPTIVE.md` — Claude's campaign brief and per-round redirects (the danger-adaptive idea is James's, relayed by Claude).
- `P9B_SCOREBOARD.md`, `P9B_REPORT.md` — Codex's campaign scoreboard (one row per experiment) and full report (rounds 1–5).
- `PLAN_P10_REQUEST.md`, `PLAN_P10.md` — Claude's request and Codex's Phase 10 plan.
- `p2_pocket_diag.nim` — a scratch diagnostic Codex used in Phase 2.
- `phase5-logs/`, `phase6-logs/`, `phase7-logs/`, `phase10-logs/` — raw logs and JSON artifacts for those phases.
