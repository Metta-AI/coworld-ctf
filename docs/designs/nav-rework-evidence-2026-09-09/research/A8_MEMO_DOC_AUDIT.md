# Documentation audit: A8 memo screen and C9 diagnostic closure

Scope: research artifacts, experiment runners and result claims added since3594b628. Primary src/tests/tools/viewer remain unchanged, so no gameplay, public API, GameVersion, ENV_VARIATION, replay or viewer documentation change is required for this checkpoint.

Verified: frozen parent equals retained A4 source; candidate is isolated and restored; all76map retained-field identity;173424pixel path-chain results and12mode-sensitive cases match the eager reference; five focused tests; actual memo size; native3pair/5sample timing calculations; both native DONE markers and source restoration; C9 failed gate retained. Ledger and scoreboard link the new negative result. The full native activation/quality suite was not run for the rejected A8 candidate; no final qualification claim is made.

The legacy path diagnostic initially failed to compile because its arm-label constant was absent. Only its output label was adapted, and the rerun passed. The unchanged transientPeakBytes counter is explicitly distinguished from real additional stack bytes. Neither the C9 disassembly nor three timing pairs establish a cause for its small m5a regressions.

Validation: Python comparison assertions over raw JSON and frozen-reference outputs, native-result recomputation, git diff --check on authored Markdown/Nim/shell/Python, clean production-source diff. Research source snapshots and runners are retained for reproduction; compiler caches and binaries are excluded from the checkpoint.

Raw native patch context, original compiler error output and objdump diff lines contain whitespace that git diff --check flags. Those diagnostic bytes are retained unchanged; authored files pass the targeted whitespace check. DONE markers are intentionally force-added despite the global ignore pattern.
