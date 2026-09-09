# Navigation rework: exploration record (2026-09-04 to 2026-09-09)

Status: historical record, written 2026-09-09 while Phase 10 (production cutover) was starting. It records what was tried, what was measured, and what was decided, up to and including James's three rulings. It does not describe Phase 10 or 11 outcomes.

## 0. Provenance and how to read this

- **Transcript of the whole session** (design, orchestration, every gate, every ruling): https://claude.ai/code/session_01H4Tq8mKE8YCb7mvENxWfct (`session_01H4Tq8mKE8YCb7mvENxWfct`). When this record and the transcript disagree, the transcript wins.
- **Evidence files**: `docs/designs/nav-rework-evidence-2026-09-09/` (this directory's `README.md` states the provenance of every file, including which ones are byte-for-byte copies and which were reconstructed from the transcript after the temporary-file cleaner deleted them). Paths below of the form `evidence/...` are relative to that directory.
- **Design document**: `docs/designs/nav-rework-2026-09-04.html`, with its source brief `docs/designs/.nav-rework-brief.md`. Note: that document describes the design as approved on 2026-09-04. Several of its mechanisms were superseded during implementation (Phase 2 portal derivation) and by the campaign (the search itself). It has not been rewritten yet; the Phase 10 plan assigns the rewrite.
- **Branch**: `james/s2-nav-rework` in worktree `/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-rework`, based on `origin/main` `52103b10` (2026-09-04) and merged with `origin/main` repeatedly afterwards. Not pushed as of this writing. The exploratory commit range is `f289a8ee` (first Phase 1 commit) through `2906751b` (the P10.0 measurement harness); the complete list with messages is in section 9.
- **Who did what**: Claude (this session) wrote the design draft and the phase dispatches, gated every phase by re-running tests itself, and made the rulings marked "Claude ruled". Codex (OpenAI Codex CLI 0.153.x, model `gpt-5.6-sol`, run in a tmux session with approvals bypassed) reviewed the design and implemented every phase and experiment; text attributed to Codex is quoted from its reports. James made the decisions marked "James ruled".
- **Platforms**: "native" means this Mac (macOS 15.5, arm64, Nim 2.2.6, release build). "canonical" means the repository Dockerfile built for linux/amd64 with Nim 2.2.4 under OrbStack's emulation on the same Mac, limited to one CPU. Canonical route-quality, activation and memory rows are the gate's own numbers; canonical tick latencies are provisional because emulation is not a production CPU. Every number below says which it is.
- **What "single run" means here**: unless a table says otherwise, a route-quality figure is one pass over the 3,072-case corpus, and a latency figure is the median/percentile of the stated sample count. Repetition counts are quoted where the reports give them.

## 1. The task and the gate that governed it

Asana task 1218165906459726 ("Precompute shared cog navigation and replace per-tick route planning with immediate zone-aware movement"), Paintbot board, Layer Sim & Rules. Its description (rewritten by Codex on 2026-09-04 after James's review; see `evidence/asana-task-1218165906459726-comments.md`) fixed:

- Architecture: one deterministic room/portal index built at map install from BodyMap's existing rooms and chokes; one immutable zone hazard overlay per episode; during play only bounded small-graph queries, scoring of precomputed segments, following of precomputed local fields, and local steering; "No full-board A*, Dijkstra, route-field mint, or other resumable search may run during active body ticks."
- Liveness: "A living cog with a valid navigation goal must begin safe progress immediately rather than standing still while a route is prepared."
- Quality gate (comment 1218197326946541, quoted in the evidence file): weighted-cost inflation versus the current 4 px planner's route, p95 <= 3.0 % and max <= 10.0 %, overall and within every roster x profile x dynamic-state x near/far stratum; C(R) = sum over 4 px-resampled steps of Euclidean length x (1 + profileDangerWeight x danger(midpoint)), x8 on the blocked-penalty cell; a missing route is a failure.
- Performance gate: complete body slice p95 <= 4.0 ms and max <= 5.0 ms at 16 and 32 seats on the canonical build; activation <= 2x BodyMap baseline (pool) / 3x (colossal); retained shared nav data <= 16 MiB (pool) / 32 MiB (colossal).

Two facts about the task's own state that mattered: it was in "5 · Blocked" on the cover-hold task 1218165969208626 when James told Claude to proceed anyway (2026-09-04; the cover-hold corpus row was left as a disabled TODO), and its earlier comments record a measured baseline of the old planner (cold far routes 10-21 scheduler ticks; alternating goals leaving 260-483 of 512 seat-ticks with zero movement; ~2.37 GB process RSS).

## 2. Design review (2026-09-04)

Claude drafted `evidence/reconstructed-from-transcript/DRAFT_DESIGN.md` from a code reading of `body_map.nim`, `body_planner.nim`, `body_nav.nim`, `body_cache.nim`, `body.nim`, `episode.nim`, `zone_field.nim`, and three measurements taken that day on this Mac at commit `fad3029f`:

- `nav_census.tsv` (the bench tool's uncommitted `nav-census` case): per-map rooms, chokes, intra-room portal pairs, portal-field cells, BodyMap build time. Caveat recorded in PLAN.md later: the `pool:N` maps in this census are the legacy `map_pool.nim` entries, not the 64 published `data/br_s2_map_pool.json` specs the gate uses.
- `cell_probe.tsv` (scratch probe, 8 legacy pool maps): every walkable 8 px cell has a room; orthogonal centre-to-centre steps were legal in 100 % of sampled cases; diagonal steps were illegal in 1.3-2.7 %; 0.7-2.0 % of standable pixels lie in cells whose centre is not standable; on `pool:0` one pixel component became two legal 8 px components.
- `seg_probe.tsv` (scratch probe): one room-restricted Dijkstra per (room, portal) with segment-cell totals, longest chain, and build time; giant maps 189-283 ms index build against 479-499 ms BodyMap; generated colossal 2,245 ms against 2,263 ms.

Codex reviewed in three rounds; the files are reconstructed verbatim in `evidence/reconstructed-from-transcript/` (`REVIEW.md`, `RESPONSE.md`, `VERDICT.md`, `RESPONSE2.md`, `VERDICT2.md`).

- Round 1 (`REVIEW.md`): nine fact checks, all verified by Claude against the code and accepted. The ones that changed the design: the zone overlay must read `ZoneArrivalField.damage`, not the render-gated `arrival`; the ETA speed is the derated 2.0625 px/tick from PR #408, not the 2.75 px/tick top speed; the old planner's endpoint connector scan is unbounded, so the new attach needed its own bound; room ids are one-based in the raster and zero-based in `BodyRoom`; colossal has 13,730 intra-room pairs (27,460 directed); the zone field is built lazily and needed an explicit server seam; nine replay fixtures, not eight; the hazard overlay had to be split from a mutable safe cache.
- Round 2 (`VERDICT.md`, REVISE): seven corrections, all accepted. Three were errors in Claude's draft: a Euclidean heuristic in 1/16 px units is inadmissible because 181/128 = 1.4140625 < sqrt 2 (fixed by the exact octile heuristic); collapsed portal nodes let the search change rooms without paying the crossing (fixed by (portal, room) side nodes and edge-id routes); `gameStartTick` is -1 until `startGame`, so it cannot be snapshotted at construction (fixed by passing the live elapsed zone tick).
- Round 3 (`VERDICT2.md`, GO) with three implementation notes (memo accounting; octile on cell-index deltas with the rounding rule in the oracle; an adversarial earliest-arrival hazard case).

What the review did NOT do: it did not measure route quality against the oracle. The design's central risk, "A single static shortest segment cannot preserve dynamic weighted cost ... This is the largest 3%/10% risk" (REVIEW.md section 3), was accepted as the task's explicit trade with bounded endpoint-room refinement as the mitigation. That risk is what failed at the Phase 9 gate.

## 3. Implementation, phases 1-8

Codex wrote `evidence/reconstructed-from-transcript/PLAN.md` (Phase 0) mapping the eleven subtasks to eleven phases; Claude approved it (`VERDICT_PLAN.md`) with four binding notes. Codex's decision ledger for the whole implementation is `evidence/scratchpad-impl/LEDGER.md` (entries D001-D054). Each phase has a report `evidence/scratchpad-impl/PHASE_n_REPORT.md` (Phase 1's is reconstructed). Claude's acceptance of each phase is in `PROCEED_P(n+1).md`, which states exactly which suites Claude re-ran and with what counts.

| Phase | Commits (branch) | What was built | Claude's independent verification (native, this Mac) | Fix-ups |
|---|---|---|---|---|
| 1 | `f289a8ee`, `7f589dc2`; compaction `7e1364c0` in Phase 2 | 3,072-case literal corpus (64 published maps x rosters 16/32 x 3 profiles x 4 dynamic states x near/far), independent 4 px float oracle, byte-reproducible writer; three deliberately red liveness/no-live-search tests kept out of the shards | `test_shell_body_nav_rework`: 1 OK, 3 FAILED as intended; `test_shell_body_nav` 20/20 | none |
| 2 | `24b05e1d`, `e8a7b75a`, `585ea565`, `ebb0c525`, `db22311b`, `71e2d2d1` | legality centralised in `body_map`; immutable `BodyRouteIndex`; four rulings (section 3.1); qualification tool over 64 published maps + arena + colossal | route_index 7/7, body_map 15/15, body_nav 20/20, body_seat 23/23, both server compile shapes | none, but four stop-and-rule cycles |
| 3 | `fd224c2c`, `0722e0b8`, `d39655b5`, `6b6e3b69`; fix-up `eaa2046a` | bounded side-graph route query (Q4 integer costs 128/181, octile heuristic, 4,096-pop caps, transactional install), wired into shard 2 | query 8/8, index 7/7, nav 20/20, seat 23/23, shard 2 771 OK / 1 FAILED (the containment timing test) | `eaa2046a`: index and scratch construction had run inside the containment test's timed window (~0.95-1.08 ms measured by Codex's 36-sample diagnostic); now built only for episodes with a play seat. Claude's isolated containment runs: origin/main 5,391 us (fail on this Mac), HEAD before fix 6,492 us, HEAD after fix 5,803 us max with ordinary waves 4.4-4.8 ms |
| 4 | `9a9a77a7`, `5e6b2159`; fix-up `eb3515e1` | zone hazard overlay from the `damage` surface, separate safe cache, shared query-local danger memo, cell-by-cell hazard pricing, earliest-arrival alternative label (adversarial two-prefix test) | hazard 10/10 (linked and stub), query 10/10, index 7/7, nav 20/20, seat 23/23, first_light 14/14, both shapes, containment 5,494 us pass | `eb3515e1`: `zone_field.nim` had imported a shell module (would reach the wasm replay build); `ZoneDamageSnapshot` moved to the ctf layer with a source-architecture test. Claude also asked for a per-tick delta investigation; Codex's three adjacent pairs had mixed-sign deltas and no tick-path change was made (D035) |
| 5 | `64be5b20`, `c008ec82`, `c9823bce`, `fc989898` | integer safety hints (JSON `nav`, binary section 14 appended, `SdkNav`), byte-identical when dark; one code-layout-only commit (`fc989898`, 175/172 lines moved) | hazard 17/17, view 20/20, binary_view 9/9, play_sdk 2/2, nav 20/20, seat 23/23, first_light_server 15/15, manifest_schema 11/11, both shapes, containment 4,708 us | none; Claude flagged the layout commit as timing-motivated and accepted it as organisation |
| 6 | `73a60cc6`, `dba865de` | `Intent.target_class = zone_safe_ground` with required literal fallback; canonical order preserved; reserved binary slot used; stable request anchors; `setStandingIntent` no longer cancels | emit_validator 13/13, seat 26/26, nav 20/20, view 21/21, binary_view 10/10, play_sdk 3/3, hazard 17/17, episode_ladder 25/25, both shapes, containment 4,683 us | none; a pre-existing shard-3 temp-path collision was recorded as a follow-up |
| 7 | `2d6715da`, `2c46b6ac` | the new path owns play-seat movement: descriptor follower, K = 6 exact-clear smoothing, eight-octant steering, `bnsStalePath` removed, death reset; the three Phase 1 laws turned green without changing their assertions and were wired into shard 4 (measured fastest) | rework 11/11, nav 20/20, seat 27/27, query 10/10, ladder 28/28, episode 15/15, hazard 17/17, both shapes; containment under identical heavy load (load average 9-14): origin/main 6,579 us, HEAD 5,868 us, both failing the local 5 ms floor | none |
| 8 | `635727c8` (fix-up), `dafe63a7` | regression matrix; `ShellNavSummary` diagnostic cutover; cover-hold merge from main resolved | rework 12/12, query 12/12, index 7/7, hazard 17/17, seat 30/30, nav 21/21, episode 16/16, ladder 31/31, emit_validator 14/14, view 21/21, binary_view 10/10, play_sdk 3/3, default_play 6/6, standing_order 4/4, server_seam 19/19, both shapes | `635727c8`: the Phase 4 server seam had passed the raw `sim.tickCount - sim.gameStartTick` into the shell step; `gameStartTick` is -1 in the lobby. Found by Claude while reading the nav handoff Asana task (1218200004252283), which had predicted this exact bug class; fixed with the guarded `gameTicksElapsed()` and a lobby/start regression test |

The FIRST LIGHT probe after Phase 7 printed `SHELL_MASK_SUMMARY tick=1 seats=32 moving=32` (`PHASE_7_REPORT.md`), which is the direct evidence that cogs move on their first navigate tick.

### 3.1 The four Phase 2 rulings and the evidence that forced them

Phase 2 stopped four times at its own qualification gate. Each stop is recorded in `PHASE_2_REPORT.md` and Codex's ledger D013-D024; Claude's rulings are `RESOLVE_P2.md` through `RESOLVE3_P2.md` (reconstructed) and `RESOLVE4_P2.md` (copied).

1. Published map `br-gen-20049`, choke 47: no legal 8 px crossing inside the +-4-cell box at 64 pops. Codex's diagnostic: a global 8 px path exists only as a 96-step detour visiting 9,240 nodes, while a 4 px path exists inside the box in 8 steps visiting 29 nodes. Claude ruled: sparse 4 px points inside crossing segments (negative int32 encoding), search order direct 8 px, then 8 px in-box 64 pops, then 4 px in-box 256 pops; caps unchanged.
2. Arena choke 81 and a census of all 66 maps: 68 portal sides on 26 maps had no walkable cell of the choke's BodyMap-labelled room within ring 4 (rings needed up to 29). Claude ruled: derive portals from the index's own coarse room raster (cluster legal cross-room moves per room pair at 64 px) and use BodyMap chokes only as hints for 4 px-only gaps. This is a departure from the approved design, which treated chokes as the portals.
3. `br-gen-20184`: 562 standable pixels unresolved; the first failing pixel component has 72 pixels and no walkable 8 px cell, another has 7. Claude ruled: the coverage proof applies only to validator components (those containing a spawn point, the only ones `validateGoal` can resolve into); islands are counted, not represented.
4. Same map after scoping: 483 pixels in validator component 1 still unresolved; anchored cells exist within ring 2 but the fixed-phase 4 px graph reaches none of them (9 nodes total). Claude ruled: pocket connectors search on the pixel grid inside the fixed +-32 px box, string-pulled into fine points, chained in row-major seed order.

After the fourth ruling the qualification passed on all 66 rows with zero uncovered validator pixels (native): worst published activation ratio 1.9298 (`published:48`), worst published retained bytes 1,399,698; colossal 2.1146 and 26,709,081 bytes. These are `PHASE_2_REPORT.md` "Final full qualification" numbers; the same rows re-measured canonically in Phase 9 gave 1.901 and 1,942,861 (pool worst) and 1.851 / 28,449,996 (colossal).

## 4. The Phase 9 gate (canonical run at `b24d8d8d`, 2026-09-08)

Harness `tools/bench_body_nav_rework.nim` run by `tools/run_body_nav_gate.sh` in the repository Dockerfile (linux/amd64, Nim 2.2.4, one CPU, image `sha256:5dde6255…`). Source: `evidence/scratchpad-impl/PHASE_9_REPORT.md`.

Passed:
- Determinism: native arm64 and canonical amd64 corpus route hashes identical.
- Activation and retained memory: all 64 published maps and colossal; worst published activation ratio 1.901047x (limit 2.0), worst published retained 1,942,861 bytes (limit 16,777,216); colossal 1.850716x (limit 3.0) and 28,449,996 bytes (limit 33,554,432).

Failed:
- Route quality: 3,072 cases, 3,068 scored, 4 missing (all `brfDescriptorOverflow` on `m32-br-gen-23457`, carrier, far), 0 illegal; overall p95 19.910469 %, max 86.650066 %; 30 of 48 strata failed plus the overall row. Every stratum with a danger snapshot failed (p95 from 7.4 % to 36.8 %); the blocked-only far strata failed narrowly (p95 3.357926 %); the no-danger strata passed. The full failing-row table is in the report.
- Inclusive body-slice tick time: 8 of 12 canonical rows failed, 11 of 12 native rows. Canonical 16-seat `first_goals` p95 611,277,552 ns; 32-seat 1,201,193,789 ns. The steady rows (`worst_degree`, `bucket_danger_rollover`) passed canonically at 1.7-3.4 ms.

Codex's approved-fallback attempts inside Phase 9 (all reverted, `PHASE_9_REPORT.md` "Approved fallback investigation"): fine structural alternatives (p95 18.55-19.93 %, max 86.47 %); a global structural A* over the side graph (p95 15.74 %, max 86.65 %); weighted A* (p95 14.78 %); an anytime variant (p95 19.50 %); segment/follower cost-aware sampling ("did not close the quality gap and worsened the already-catastrophic cold tick cost"); broad global/guide/bidirectional experiments ("made tick time impractical"). None of these has a scoreboard row or commit of its own; they are described only in that report section, so treat them as reported-but-not-separately-reproducible.

## 5. Investigation and optimisation campaign (2026-09-08 to 09-09)

All campaign work is measurement code on revertible commits; the production navigator was unchanged through the end of P10.0, and every canonical rerun of the production path during the campaign returned the expected failing verdict (quoted in each round's "final qualification" section of `P9B_REPORT.md`). The scoreboard `evidence/scratchpad-impl/P9B_SCOREBOARD.md` has one row per experiment with the commit, the numbers, and Codex's stated verdict; the report `P9B_REPORT.md` has the method and tables. Claude's briefs are `INVESTIGATE_P9.md`, `CAMPAIGN_P9B.md`, and `CAMPAIGN_P9B_REDIRECT*.md`; James's idea is `CAMPAIGN_P9B_IDEA_DANGER_ADAPTIVE.md`.

A note on tooling: Claude's campaign brief asked for Fluffy tracing markers (the repository's `-d:ProfileTracePath` facility). The reports never reference a Fluffy trace artifact; the per-stage profiles came from the investigation harness's own counters (`-d:navQueryProfile`) and from microbenchmarks. Whether Fluffy markers were added to the navigation code cannot be established from the reports; the transcript does not show a trace being produced.

### 5.1 Investigation (`P9_INVESTIGATION.md`, commits `0b1c495f`, `c43b97dd`, `f3f77693`)

- **Correctness bug found and fixed (`c43b97dd`)**: the side search kept one mutable parent slot per portal side; with the earliest-arrival alternative label a side could be settled twice and the second settle overwrote the first's parent, so reconstruction walked a two-edge cycle until the 4,096-edge descriptor cap fired. The four "missing" routes were this bug; after the fix all four validate with 7 edges, a 65-point start leg and a 61-point goal leg. A corpus-pinned regression test was added. Native 16-seat `first_goals` before/after: 854,258,459 vs 835,556,417 ns p95, which Codex labels "ordinary host variance, not a claimed speedup".
- **Where the per-query time went** (native, seven-run medians): the `br-gen-22010` far danger case took 35.77 ms, of which endpoint attach 0.18 ms, same-room candidates and connection chains 15.77 ms, side-graph A* 19.54 ms (hazard pricing nested inside those at 13.49 ms), validation and assembly 0.20 ms, install 1 us. Counts: 226 side pops, 3,522 arcs relaxed, 2,144 segment memo fills, 87,515 segment cells read, 69,091 connection-chain cells read. Codex's interpretation: the cost is per-seat, per-query re-pricing of retained static paths against that seat's danger, not O(map) work. Note that this profile was taken with the memo still cleared per query.
- **Where the quality gap was**: of the 30 worst cases, 26 use the same room sequence as the oracle, and in all 30 the excess weighted cost inside rooms shared with the oracle is 98-104 % of the total excess (table in the report). Codex's interpretation, later refined by round 1 and 2 (below): static intra-room segments cannot follow danger.
- **Corridor-restricted weighted 8 px A*** (measurement tool only, `f3f77693`): searching only the rooms on the hierarchical route plus endpoint rooms, replacing static intra-room segments where the search reaches the goal: overall p95 8.322 % / max 86.650 % at 8,192 pops, 7.025 % / 86.197 % at 16,384 pops (native, full corpus); adds 5.5-11.3 ms per query. Stated reason for not promoting it: "too slow, still fails the quality gate, and its remaining carrier-danger failures show that restricting refinement to the static side-graph room choice is not enough".

### 5.2 Round 1: bounded global weighted A* on the 8 px grid (Claude's "Idea 0")

| Row | Commit | Tried | Result (native, full corpus unless noted) | Codex's stated verdict |
|---|---|---|---|---|
| 1a | `0c267361` | global weighted 8 px A*, single containing-cell endpoints, caps 16k/32k/65k | invalid: 48 corpus endpoints could not see their containing cell centre | "Superseded: did not use the required endpoint ring." |
| 1b | `79c831ba` | same with radius-4 exact connectors, 16,384 pops | 7.627 % / 86.650 %, 148 fallbacks | "Reject: cap is too low and quality fails." |
| 1c | `79c831ba` | 32,768 pops | 7.093 % / 84.807 %, 0 fallbacks; carrier-danger-near 19.647 % / 84.807 %; query 8.5 / 9.2 ms p50/p95 | "Reject: complete and legal, but 8 px resolution misses the quality gate." |
| 1d | `79c831ba` | 65,536 pops | identical routes to 1c | "Reject: identical routes to 32k; larger cap buys nothing." |

What this establishes: a complete weighted search on the 8 px legality graph, with full dynamic cost, still exceeds the gate on danger strata and even shows a 22.555 % max on `default/none/far`; therefore neither room choice nor cap fallback explained the residual. It does not by itself say why; round 2 tested the hypothesis.

### 5.3 Round 2: lattice resolution (H1), per-pop cost (H2), James's danger-adaptive idea (D)

| Row | Commit | Tried | Result | Codex's stated verdict |
|---|---|---|---|---|
| 2a | `fcc58a75` | global weighted A* on the full 4 px oracle lattice, 262,144-pop cap | 0.000 % / 0.000 % in every stratum (reproduces the oracle exactly); pops p50/p95/max 25,134 / 73,171 / 130,641; query p50/p95 14.7 / 41.8 ms; profiled median 30.5 ms, far 59.4 ms; largest pool workspace 3,442,080 bytes | "Confirms H1 exactly, but reject as measured: p95 query 41.849 ms and 73,171 pops." |
| 2b | `fcc58a75` | one max-clearance 4 px anchor per 8 px cell | 4.021 % / 50.265 %; carrier-danger-near 11.782 % / 50.265 % | "Reject: better than center anchors, but still misses both quality gates." |
| 2c | `8541ac94` | mixed graph: 4 px nodes within two cells of centre-dead geometry, coarse anchors elsewhere (geometry only) | 3.295 % / 15.011 %; carrier-danger-near 10.415 % / 15.011 %; query p95 19.6 ms | "Reject: geometry-only refinement remains outside both quality gates and p95 query is 19.578 ms." |
| 2d | `61590874` | H2: precomputed Q4 weights, lazy int64 heap, no floats, on the complete 8 px graph | 291.4 / 345.6 ns per pop p50/p95 versus 665.1 / 786.7 baseline; quality unchanged (8 px) | "Reject: 291.4 ns/pop median … remain far above 60 ns/pop; quality was already disqualifying." (The 60 ns target was Claude's; see 5.4.) |
| D1 | `5935030e` | 4 px nodes only in cells with danger > 0 dilated one cell, 8 px elsewhere, lazy exact legality | 0.755 % / 83.301 %; worst stratum carrier-danger-far 5.436 % p95; query p50/p95 45.1 / 148.0 ms | "Reject: large quality improvement, but far-carrier p95 and global max fail; exact lazy legality is far over budget." |
| D2 | `5935030e` | dilation two cells | 0.780 % / 83.253 %; slower | "Reject: the larger margin does not repair the coarse cold-route maxima and is slower." |
| D3 | `5935030e` | D2 restricted to the hierarchical corridor rooms | 7.093 % / 84.355 % | "Reject: corridor restriction removes the alternate-room freedom Idea D needs and regresses to the 8 px baseline." |

H1 attribution measured by Codex: among the 30 worst 8 px routes, 14 oracle routes use at least one 4 px point whose containing 8 px cell is not walkable at its centre (756 such points, average clearance 8.923 px). What this establishes: the oracle's cheaper lanes run through the band of cells whose centres are within 6 px of a wall, which the centre-based 8 px legality excludes; full 4 px freedom reproduces the oracle, and neither one anchor per cell nor geometry-only band refinement is enough. What it does not establish: that the wall band is the *only* missing freedom (D1's 83 % max on a danger stratum was attributed by Codex to "cold cells" the oracle uses, an interpretation, and was resolved empirically by R3.3 rather than proven).

### 5.4 Round 3: precomputed 4 px legality, per-pop cost against the legacy planner, danger-plus-wall-band graph, synchronous per-tick budget

| Row | Commit | Tried | Result | Codex's stated verdict |
|---|---|---|---|---|
| R3.1 | `7a7a25d4` | exact 8-way legality byte plus standable bit for every 4 px lattice point at activation; exhaustive readback against `canStand` + `segmentClear` | 193,617 bytes on the largest pool lattice (172,104 points), build p50 193.8 ms; colossal 1,752,192 bytes, build 1.98-2.00 s (three samples) | kept |
| R3.2 | `82db2590` | dense full-4 px weighted A*: stamped int32 arrays, precomputed integer weights, packed int64-key binary heap; and a measurement of the legacy `BodyPlanner` on the same two cases (15 sequential samples each) | legacy: 2,131-2,201 ns per work unit; median case 97.8 / 103.5 ms, far case 231.2 / 235.2 ms. Dense loop: 335 / 356 ns per pop (median case, 13.0 / 13.8 ms at 38,813 pops), 364 / 410 ns (far, 38.5 / 43.4 ms at 105,773 pops). Colossal dense workspace 37,380,096 bytes | "Keep as the optimized full-4 comparison, not a ship candidate". Codex also corrected Claude's premise: "the repository contains no evidence for the stated 30-60 ns legacy work-unit cost". |
| R3.3 | `2b38d427` | union of danger > 0 dilated one cell and the static wall band gets 4 px nodes; one 8 px anchor elsewhere; cold anchor edges are exact contracted 4 px chains built at index time; no `segmentClear` in the search loop | 0.313 % / 0.829 % overall; worst stratum 0.461 % / 0.829 %; zero missing/illegal; pops 10,407 / 31,248 / 52,518; corpus query 2.294 / 6.693 ms p50/p95; profiled median 2.949 / 3.214 ms, far 9.902 / 11.162 ms; largest pool shared footprint 13,440,682 bytes | "Quality winner: all gates pass, but point-query targets still fail." |
| R3.4a-c | `bf77c710` | K = 2 / 4 / 8 synchronous route constructions per tick, deferred seats steer | navigation-only lower bound, 30 waves: K = 2 p95/max 20.1 / 23.4 ms (16 seats), 21.0 / 25.1 ms (32); K = 4 43.0 / 46.8 and 39.6 / 46.0; K = 8 77.8 / 79.8 and 78.3 / 84.1 | all rejected against the 4 / 5 ms gate; "synchronous completion remains the binding constraint" |

What R3.3 establishes: a graph that is 4 px only where danger is nonzero or along walls matches the fine-grid oracle to within 0.83 % on every corpus stratum (native, one full pass). It does not establish tick-time feasibility; that is round 4.

### 5.5 Round 4: fewer pops (ALT), cheaper pops (Dial), resumable budgeted scheduling

| Row | Commit | Tried | Result | Codex's stated verdict |
|---|---|---|---|---|
| R4.1a-c | `93fada39` | ALT landmarks L = 4 / 8 / 16 over 8 px cells with a 64 Q4-per-cell projection (the direct 128 Q4 potential was inconsistent on the mixed graph) | pop p95 reduced at most 1.0 %; latency rose (2.26-2.54 ms p50 vs 2.18); equal-cost tie changes moved max inflation to 3.640-3.766 % | rejected: "do not repay eight landmark reads per pop"; R4.4's requirement to preserve R3.3's inflation exactly |
| R4.1d | `93fada39` | corridor = hierarchical route rooms plus adjacent rooms | 1.594 % / 79.659 %; pops -1.6 % | "Reject: the one-room margin still excludes quality-critical alternatives and barely reduces pops." |
| R4.2a | `9b6ca3be` | exact width-1 Dial bucket queue, one combined int32 cell table | 182 / 221 ns per pop (median case 2.30 / 2.80 ms), 182 / 247 (far, 8.22 / 11.15 ms); identical route checksums over 15 repeats | advance |
| R4.2b | `9b6ca3be` | width-16 buckets | 258-263 ns per pop | rejected |
| R4.3a-c | `197133f4` | one shared resumable workspace, FIFO in seat order, B = 4,096 / 8,192 / 12,288 pops per tick, waiting seats use production steering; 18 rows (16/32 seats x first goals / moving goals / stuck replans) | every row under 4 / 5 ms: worst p95/max 1.10 / 1.24, 2.03 / 2.11, 3.09 / 3.17 ms; worst time-to-route p95/max 501 / 517, 251 / 259, 167 / 173 ticks (32-seat first goals); repeat and reversed-arrival fingerprints identical | B = 12,288 advances |
| R4.4 | `8491b14b` | R3.3 + width-1 Dial + one workspace + B = 12,288 + steering | quality exactly R3.3 (0.313115 % / 0.829058 %); 18 scheduler rows pass; colossal does not fit 32 MiB in this shape (dense workspace 37,380,096 bytes; int32 weights 49,840,128 for 32 seats) | "Round-4 winner … not production code and the colossal representation exceeds the cap." |

### 5.6 Round 5: route-latency tail, gameplay cost of waiting, colossal fit, parallel workspaces

| Row | Commit | Tried | Result | Codex's stated verdict |
|---|---|---|---|---|
| R5.1a | `2db4f21a` | stable shortest-job-first admission (octile estimate, seat tie-break) on a mixed near/far burst | at B = 12,288: first-goal p50 23 -> 3 ticks (16 seats), 46 -> 5 (32); p95/max unchanged (46 / 46, 86 / 91) | "Optional add-on … p95/max remain" |
| R5.1b | `2db4f21a` | 1,024-pop arrival probes before FIFO | no near first-goal query completes inside 1,024 pops; tail +1 tick | "Reject" |
| R5.1c | `6ebff3a6` | staged legality-mask neighbour loop; separately B = 16,384 | loop, median case: accepted 184 / 229 vs staged 191 / 212 ns per settled pop p50/p95 (the scoreboard row states the same comparison as 183 -> 187); far case 189 / 241 vs 185 / 227; Codex: "noisy and not a consistent median improvement". B = 16,384 alone: 32-seat first-goal tail 167 / 173 -> 126 / 130 ticks, slice still under gate | loop change rejected; B = 16,384 noted |
| R5.1c-pf | `f35319ce` | explicit neighbour prefetch | median case worse (194 / 232 ns), far p95 better (208 ns) | "Reject" |
| R5.1d | `6ebff3a6` | warm-start replans with up to 128 previous-route cells | seeds accepted; queue pops, settled pops and route ticks identical in every row | "Reject: … queue and settled pops are unchanged" |
| R5.1e | `bf4bae4c` | SJF + B = 16,384 | first-goal p50/p95/max 2 / 35 / 35 ticks (16 seats), 4 / 65 / 69 (32); slice p95/max 2.53 / 2.58 and 2.44 / 2.68 ms | "Best measured tail row … B raise still needs canonical integrated qualification." |
| R5.2 | `e82d40f9` | idealised kinematic replay of steering while waiting vs a zero-latency route, remaining distance at ticks 24/48/96/172 | worst ratio 1.0064 (16 seats), 1.0193 (32); zero seats meet the eight-tick dead-end threshold; 48 and 102 aggregate no-progress seat-ticks | "Keep evidence". Note: "an idealized kinematic replay, not a full server episode". |
| R5.3 | `824d876d` | compact shape for colossal: int16 packed per-seat weights, fixed sparse open-address workspace | fits: 32,469,128 bytes on colossal (1,085,304 spare); pool 6,948,856; quality 0.383 % / 0.829 %; but 1,037-1,129 ns per pop (median 11.3 / 12.3 ms), 779-807 ns (far 34.4 / 35.6 ms) | "Memory feasibility passes … but reject throughput" |
| R5.4a-b | `4b477e27` | K = 2 / 4 independent workspaces, one thread, 1,024-pop round robin, same total B | tail unchanged or slightly worse (167 -> 172 / 173 ticks at 32 seats); workspace bytes x2 / x4 | "Reject" |

### 5.7 P10.0: the pop-budget ruling packet (`PHASE_10_REPORT.md`, commit `2906751b`, native, HEAD `e7cda62b`)

18 rows, each a separate process, 120 timing samples, identical-repeat and reversed-arrival determinism asserted, all routes legal and exact to their oracle cost within floating-point noise (max 8.9e-14 %).

| B | worst row | combined nav p95 / max (ms) | 16-seat first-goal ticks p50/p95/max | 32-seat first-goal | 32-seat stuck replans |
|---|---|---|---|---|---|
| 12,288 | 16-seat stuck replans | 2.626 / 3.164 | 3 / 46 / 46 | 5 / 86 / 91 | 18 / 53 / 57 |
| 16,384 | 32-seat stuck replans | 3.164 / 3.487 | 2 / 35 / 35 | 4 / 65 / 69 | 11 / 40 / 43 |
| 20,480 | 16-seat stuck replans | 3.665 / 4.368 | 2 / 28 / 28 | 3 / 52 / 55 | 8 / 32 / 34 |

Codex recommended B = 16,384 by the selection rule "largest … whose worst native combined search-plus-steering slice p95 stays at or below approximately 3.2 ms", noting that its maximum (3.487 ms) is above 3.2 ms and, more importantly, that an additive whole-body estimate (nav p95 plus the Phase 9 `worst_degree` whole-body row measured separately) exceeds the 4 / 5 ms gate on both the native series (6.95 / 7.25 ms at 16 seats, 11.05 / 11.40 at 32) and the cross-platform series (4.73 / 4.95 and 6.61 / 7.21). The report says explicitly: "Do not claim the whole-body gate from P10.0."

## 6. What was not tried, or only partially tried

- **Threads or any parallel search** were never tried; the task forbade threads and no experiment used them. R5.4's "parallel workspaces" is single-threaded round-robin.
- **ALT with a consistent potential** on the mixed 4 px / 8 px graph was not found; the measured variant used a 64 Q4-per-cell projection after the 128 Q4 potential proved inconsistent (reopening made it "pathologically slow" per Codex; no numbers for that variant were recorded).
- **Per-pop cost below about 180 ns** was not achieved; the best measured is 182 ns per pop (R4.2a). Claude's 60 ns and 100 ns targets had no evidential basis and were withdrawn (R3.2, R5.1c).
- **The inclusive whole-body slice** (navigation plus the rest of the body tick, integrated, on the winner) was never measured at the time of writing; only navigation-only slices and additive estimates exist. This is the open question that the Phase 10 plan makes a stop condition.
- **The canonical linux/amd64 run of the winning shape** (R3.3 / R4.4 / SJF + B = 16,384) was never done; every canonical run in the campaign exercised the unchanged production path. All winner numbers are native arm64.
- **Route-quality reruns during rounds 4 and 5** used the scheduler's two selected cases or the full corpus as stated per row; the 18-row scheduler harness itself checks only its own cases' costs, not the 3,072-case corpus (P10.0 says so explicitly).
- **The gameplay cost of waiting** (R5.2) is an idealised kinematic replay with the game's motion constants, not a full server episode; no live-episode measurement of the wait exists.
- **Colossal** was measured only in the compact shape (R5.3, slow) and by byte arithmetic for the dense shape (R4.4, PLAN_P10 section "Colossal decision": lower bounds 67.94 MiB with int16 weights, 91.70 MiB with int32, before final cold-chain, bucket, descriptor and allocator accounting). No dense-shape colossal run exists.
- **Hint accuracy** (Phase 5's safety hints, `zone_safe_ground` resolution) was tested by unit tests only; no oracle-style quality measurement of hints exists.
- **The cover-hold corpus row** remains a disabled TODO; the corpus was frozen before cover-hold landed on main, and no cold-transition-to-cover case is in it.
- **Fluffy tracing**: requested by Claude in the campaign brief; no trace artifact or Fluffy-based table appears in any report (see section 5).
- **The corpus's danger placement** puts sources around the middle third of each oracle route (PLAN.md section Phase 1), which is a deliberate stress on danger avoidance and not a claim about the in-game distribution. No experiment measured inflation under a different danger distribution.
- **Phase 9's in-phase fallback experiments** (section 4) are described in prose only, without commits or scoreboard rows.

## 7. James's rulings (2026-09-09) and the caveats in force when they were made

Recorded verbatim in `evidence/scratchpad-impl/PROCEED_P10.md` and Asana comment 1218332741875387.

1. **Contract change approved.** Production navigation becomes a pop-budgeted resumable weighted search over the precomputed legal graph (R3.3 mixed graph), exact width-1 Dial queue, one shared workspace, stable shortest-job-first admission, per-tick pop budget, production steering while a seat waits. This replaces "no full-board search on a play tick". James's words in chat: "I'm willing to try whole-map search and see if our improvements allow this to work well."
2. **Build at B = 16,384**; the integrated whole-body measurement decides whether B must drop (12,288 next) at 32 seats; never relabel a miss. James also asked whether this meshes with the earlier steering-while-waiting change (it is the same mechanism: R4.3 onwards uses the production steering primitive for waiting seats, and Phase 7's steering is what moves cogs on tick 1).
3. **Colossal**: raise the shared memory cap for the dense shape with exact int16 per-seat weights, set above the measured full total; James added that colossal must also be made efficient and asked for per-query cost and activation there with concrete follow-ups.

Caveats that were true at ruling time: the whole-body slice was unmeasured (section 6); the winner had no canonical run; the design document still described the superseded design; the Asana task still listed subtasks 09-11 open; the branch was 71 commits ahead of `origin/main` and unpushed.

## 8. Cross-cutting facts a future reader should know

- **Two containment-gate fix-ups** (Phases 3 and 4) came from Claude's practice of running the 32-seat containment test in isolation against a fresh `origin/main` worktree on the same machine and comparing per-wave maxima, rather than from Codex's full-suite runs (which do not exercise that gate in isolation). The local containment threshold is calibrated for the CI box; `origin/main` itself frequently misses it on this Mac, so only the baseline/HEAD delta was treated as signal.
- **The elapsed-clock bug** (Phase 8 fix-up) was predicted in the nav handoff Asana task's triage comment on 2026-09-04 and was still introduced in Phase 4; it was found only because James asked whether that task had been read. Its effect was bounded by `playing`-gated consumers, per Codex's analysis, but that analysis was not separately measured.
- **The Codex stream disconnected** on 2026-09-04 during Phase 2 and was not resumed until 2026-09-07; three calendar days of the timeline are that outage, not work.
- **Machine contention**: a second session's cover-hold work and other processes loaded the machine during Phases 7-9; several containment pairs were run under load averages of 9-14 and are labelled as such in the reports.
- **Commit hygiene notes from Codex's own reports**: `61590874` and `6ebff3a6` were each created while `origin/main` had advanced by one commit during a combined command; both were merged immediately afterwards (`93ce132b`, `825b3c3a`).

## 9. Branch commit list for the exploratory range

The branch-authored commits in the range, oldest last, as listed by `git log --oneline` in the worktree on 2026-09-09. Commits from `origin/main` that arrived through merges are interleaved in that range on the branch and are omitted here; so are the merge commits themselves (listed after the block).

```
2906751b experiment: measure Phase 10 navigation budgets
f35319ce experiment: measure navigation neighbor prefetch
bf4bae4c experiment: combine SJF with raised navigation budget
4b477e27 experiment: measure bounded navigation workspaces
824d876d experiment: make colossal navigation fit concrete
e82d40f9 experiment: measure pending-steering gameplay cost
6ebff3a6 experiment: measure navigation loop and warm starts
2db4f21a experiment: measure navigation tail admission
8491b14b experiment: qualify combined navigation throughput
197133f4 experiment: measure resumable navigation scheduling
9b6ca3be experiment: profile exact Dial navigation queue
93fada39 experiment: measure ALT navigation heuristics
bf77c710 experiment: measure per-tick route query budgets
2b38d427 experiment: combine danger and wall-band navigation
82db2590 experiment: profile dense four-pixel search
7a7a25d4 experiment: precompute four-pixel legality
5935030e experiment: measure danger-adaptive navigation resolution
61590874 experiment: profile weighted search pop cost
8541ac94 experiment: measure mixed wall-resolution search
fcc58a75 experiment: measure four-pixel navigation resolution
b7710621 build: refresh replay viewer after nav investigation
79c831ba experiment: attach global routes through endpoint rings
0c267361 experiment: measure bounded global weighted routes
f3f77693 experiment: measure corridor weighted route refinement
c43b97dd fix: preserve immutable route predecessors
0b1c495f test: instrument phase 9 route investigation
b24d8d8d fix: make navigation RSS probe portable
9dce21b6 test: add canonical body navigation qualification gate
dafe63a7 test: close bounded navigation regression matrix
635727c8 fix: keep shell zone time at zero in lobby
2c46b6ac test: follow produced masks in shell danger probe
2d6715da shell: move play seats on bounded routes
dba865de test: align semantic intent with shell encoder
73a60cc6 shell: coalesce semantic navigation targets
fc989898 shell: preserve legacy navigation code layout
c9823bce shell: reuse route scratch for safety hints
c008ec82 shell: keep dark safety scratch lazy
64be5b20 shell: publish bounded zone safety hints
eb3515e1 shell: restore zone hazard layer boundary
5e6b2159 shell: price route danger and zone arrival
9a9a77a7 shell: install immutable zone hazard overlay
eaa2046a shell: avoid unused route query activation
6b6e3b69 test: cover route query order independence
d39655b5 test: prove bounded route cap fallback
0722e0b8 test: wire hierarchical route suites into CI
fd224c2c shell: add bounded hierarchical route queries
71e2d2d1 shell: connect pixel-grid route pockets
db22311b shell: scope route coverage to validator components
ebb0c525 shell: derive portals from coarse room boundaries
585ea565 shell: qualify fine route-index coverage
e8a7b75a shell: add shared body route index
24b05e1d shell: centralize body navigation legality
7e1364c0 test: compact shared-navigation route corpus
7f589dc2 test: pin shared-navigation liveness failures
f289a8ee test: freeze shared-navigation route corpus
```

Merge commits in the range `f289a8ee~1..2906751b` (32, from `git log --merges`, newest first): `e7cda62b`, `825b3c3a`, `bb461344`, `0df8851a`, `e4f18ed6`, `106eaee3`, `93ce132b`, `9271407f`, `0820d764`, `8edec077`, `c3438887`, `9103c72e`, `2ab9238e`, `20a3d01b`, `bb6926cf`, `629e1c52`, `6dfcffda`, `dbd80a34`, `23c76d09`, `9bd029e8`, `2eb1f278`, `4a658fbb`, `3693f744`, `a3ca2fba`, `36ed3092`, `e50956e9`, `c837dc88`, `285b90e6`, `fbc7e47f`, `fed50fee`, `61cda30d`, `dcd14d13`. Some of these are merges that landed on `origin/main` itself and were pulled in; the record does not separate the two kinds. Commits after `2906751b` belong to Phase 10 and are outside this record.

## 10. Evidence index

- `docs/designs/nav-rework-evidence-2026-09-09/README.md` — provenance of every file below.
- `…/scratchpad-impl/LEDGER.md` — Codex's decision ledger D001-D054.
- `…/scratchpad-impl/PHASE_2_REPORT.md` … `PHASE_9_REPORT.md`, `PHASE_10_REPORT.md` — phase reports (copies).
- `…/reconstructed-from-transcript/PHASE_1_REPORT.md` — Phase 1 report (reconstructed).
- `…/reconstructed-from-transcript/PLAN.md` — Codex's implementation plan (verbatim from a persisted tool output).
- `…/reconstructed-from-transcript/{DRAFT_DESIGN,REVIEW,RESPONSE,VERDICT,RESPONSE2,VERDICT2}.md` — the design review rounds.
- `…/reconstructed-from-transcript/{nav_census,cell_probe,seg_probe}.tsv` — the 2026-09-04 measurements.
- `…/reconstructed-from-transcript/{BRIEF,VERDICT_PLAN,PROCEED_P2,RESOLVE_P2,RESOLVE2_P2,RESOLVE3_P2}.md` — Claude's brief and Phase 1-2 rulings; `…/scratchpad-impl/RESOLVE4_P2.md`, `PROCEED_P3..P10.md`, `FIXUP_P3.md`, `FIXUP_P4.md` — the rest of Claude's gate messages (copies).
- `…/scratchpad-impl/INVESTIGATE_P9.md`, `P9_INVESTIGATION.md` — the post-gate investigation.
- `…/scratchpad-impl/CAMPAIGN_P9B*.md` — the campaign briefs, including James's idea.
- `…/scratchpad-impl/P9B_SCOREBOARD.md`, `P9B_REPORT.md` — every experiment row and its method.
- `…/scratchpad-impl/PLAN_P10_REQUEST.md`, `PLAN_P10.md` — the Phase 10 plan.
- `…/scratchpad-impl/phase5-logs/`, `phase6-logs/`, `phase7-logs/`, `phase10-logs/` — raw logs and JSON rows.
- `…/claude-orchestrator-LEDGER.md` — Claude's running ledger with timestamps of each dispatch and ruling.
- `…/asana-task-1218165906459726-comments.md` — the Asana thread.
- `docs/designs/nav-rework-2026-09-04.html`, `docs/designs/.nav-rework-brief.md` — the approved design as of 2026-09-04.
