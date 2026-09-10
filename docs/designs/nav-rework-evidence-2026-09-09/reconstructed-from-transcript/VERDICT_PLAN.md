PLAN: GO

Notes (binding, none require replanning):
1. Edge-ID width: `RouteEdgeRef` as uint16 with a direction bit leaves 32,767 segment IDs. Assert at activation that segments + crossings fit, with the map name in the message; colossal (13,046 + 1,237) fits, but do not rely on that silently.
2. Merging origin/main: do it at phase boundaries (before the phase's first commit), not before every commit inside a phase. If a merge touches src/shell/body*.nim or episode.nim, say so in the phase report.
3. Phases 3-9 keep the legacy planner alive alongside the new path. Every pre-existing shard must stay green through those phases; a phase report that only lists the new focused tests is incomplete.
4. Phase reports: exact commands, exit codes, and pasted output excerpts (test summaries, gate rows), plus `git log --oneline origin/main..HEAD` at the end of the phase. Claude re-runs the tests independently before PROCEED.

Start Phase 1 now. End with the literal line PHASE 1 DONE.
