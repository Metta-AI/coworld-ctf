# Resumed navigation research: 512 without slowing the game

James explicitly unparked the loop on 2026-09-11. New objective: improve the
CURRENT shipped planner so 512 pooled planning units per configured cog per
tick costs no more whole-game time than the current 256 baseline. These units
are not exclusively A* pops; preserve accounting and measure both. No publish,
Asana writes or live budget change before qualification. Keep route quality,
determinism and memory gates. Non-colossal memory caps may grow up to 4x only
as needed and measured. The earlier rewrite stays archived unless we jointly
justify changing approach; the old 4/5ms synthetic gate is not this gate.

Root tree: /Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-budget-screen
Peer tree: /Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-512-peer
Base 6b6b340860afc72057431f4232f6c91562f6615d, includes current origin/main
1a8d3695 (new upstream delta is wiki docs only) and local screening evidence.
Only edit your own tree. Neither agent may change the primary coworld-ctf
checkout or old research tree. No native host changes from peer; root owns EC2.

Read AGENTS.md, docs/reports/nav-budget-screen-2026-09-11.md and its protocol,
summary, real-game runner, and reviews. Current planner: body_planner.nim,
body_map.nim, body_cache.nim, body_nav.nim. Root obtains Fluffy profiles and
sets up native paired qualification; you independently inspect/rank bottlenecks,
check existing research and primary literature before proposing an algorithm.
The archived loop/practices are under docs/designs/nav-rework-evidence-2026-09-09;
reuse conclusions with explicit distinction from current planner behavior.

Phase 1 (read-only code): write docs/research/nav-512-2026-09-11/PEER_PLAN.md
in YOUR tree. Identify likely dominant costs, exact-preserving optimizations
and meaningful differential/quality checks. Recommend a reproducible paired
criterion for candidate512 vs baseline256 (median, p95, maxima, deadline misses,
route latency and legality), corpus breadth, and how to separate profiling
from qualification overhead. Analyze saved tick362/1082 and the effect of field
minting vs A* vs connectors if possible. Do not implement code yet. We are
co-equal partners: challenge the objective/gates or root assumptions as needed.
End the file and reply with literal PHASE 1 READY, then wait for PROCEED P2.
Communicate substantive content in files, not the pane.
