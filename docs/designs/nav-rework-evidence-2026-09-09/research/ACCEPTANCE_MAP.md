# Acceptance map: what Phase 10/11 actually requires, and where the evidence stands

Written 2026-09-09 by Claude (peer) for `ACCEPTANCE_AUDIT_BRIEF.md`. Audit only: no source
edits, no threshold changes, nothing omitted. Sources: the handoff
(`docs/designs/nav-throughput-research-handoff-2026-09-09.md`), `impl-latest/PLAN_P10.md`,
`impl-latest/PROCEED_P10.md`, `impl-latest/PHASE_10_REPORT.md` (stand-down), the Asana
contract text in `../asana-task-1218165906459726-comments.md`, the Phase 1 laws
(`7f589dc2`, now `tests/test_shell_body_nav_rework.nim`), `AGENTS.md`, the harness at HEAD,
and the research reports and raw JSON in this directory (read from disk, including the L1 c6a
latency rows that landed during this audit).

## 1. The inherited contract, clause by clause

### 1.1 Gates (pass/fail, ratified)
| Gate | Ratified value | Where ratified | Enforced by | Status |
|---|---|---|---|---|
| Route quality | per stratum, p95 <= 0.5 percent, max <= 3.0 percent inflation vs the 4 px float oracle; zero missing; zero illegal; all 3,072 cases, all roster x profile x dynamic x distance strata | PLAN_P10 lines 24-26 ("remains exact"); harness constants set by James in 937ea830. The handoff and the Asana comment still say 3.0/10.0; the stricter value is in force | `--quality` (native) and the canonical Docker `--all` | Passes at B0 and M0: 0 missing/illegal, hash 5a1340213fe3... (QUALITY/, M0). L0 and L1 not yet run through the full corpus (L1 quality-activation pending on c6a) |
| Whole-body tick | p95 <= 4.0 ms and max <= 5.0 ms, 16 and 32 seats, first/moving/stuck, inclusive body slice, on native or real amd64 hardware, never emulated | PROCEED_P10 item 2; RULING_TICK_GATE; Asana line 167 | `--tick` | Passes at B = 1,024 and 2,048 on c6a and m6i; fails on m5a at every budget including B = 0 (floor 4.24 ms p95) |
| Budget selection headroom | p95 <= 3.6 ms and max <= 4.5 ms in every row and repeat | FIXUP_P10_BUDGET step 3; RULING_TICK_GATE item 4; BASELINE_PREREG | worst-of-repeats reading of `--tick` | 1,024 on m6i; 2,048 on c6a; none on m5a |
| Retained memory, pool | shared retained nav data <= 16 MiB | Asana line 168; handoff section 5; James's ruling 3 raised only colossal | activation row `shared_retained_upper_bound_bytes` <= 16 MiB (added in M0) | Passes after M0 on all 64 pool maps (largest 15,938,095 B); the L1 scratch adds 85,466 B and is ledgered; pending the L1 activation row |
| Retained memory, colossal | total <= 256 MiB (`BodyNavigationRetainedCap`), set above the measured full total per ruling 3 | PROCEED_P10 item 3 | constructor cap and activation row | Passes (261,140,828 B at M0) |
| Cross-architecture determinism | identical route hashes arm64 vs amd64 | handoff section 5 | canonical Docker `--all` vs native | Passed at B0 (Xeon hash equals Mac); the canonical Docker rerun after M0/L0/L1 is pending |
| Activation time | map + index within 2x the BodyMap baseline on pool maps, 3x on colossal, "same image, same run" | Asana line 168; design review line 44; PROCEED_P9 line 5 ("<= 2x pool, <= 3x colossal") | Not enforced since 937ea830 (James's commit removed `PoolActivationLimit`/`ColossalActivationLimit` and the ratio sampling). The old row (9dce21b6) timed map + route index + query scratch + hazard overlay + safe-cache refresh against map alone and passed at 1.90x/1.85x in Phase 9. The current row times map + route index + mixed nav graph (which did not exist when 2x was ratified) against map alone and only emits the times | FINDING, with Codex's L1 numbers: (map + index + mixed nav) / map reaches 2.563 on pool 48 and 2.420 on colossal. Colossal is within 3x; pool 48 exceeds 2x. No ruling text I can find supersedes 2x/3x; PROCEED_P10 item 3 asks for colossal activation time to be reported, not re-capped. The mixed graph is new work outside the original 2x scope, so whether 2x applies to it is a question for James; until he rules, report both ratios (with and without the mixed graph) and do not silently exclude the mixed graph |

### 1.2 Liveness laws (ratified, tested)
The Asana description: "A living cog with a valid navigation goal must begin safe progress
immediately rather than standing still while a route is prepared." The Phase 1 red laws
(`7f589dc2`, James's commit) were: "a new valid goal moves on its acceptance tick"; "an
exhausted old endpoint does not stall a replacement goal"; "active action ticks perform no
full-board route search". The third was superseded by James's contract change (PROCEED_P10
item 1) and retargeted; the file now carries "a living valid goal moves on its acceptance
tick while route waits" plus the scheduler laws (pop budget exactness, one pending slot,
stable SJF tie-break, danger-generation cancel, fixed per-seat layout, arrived endpoints).
It is imported by `tests/shard_4.nim`. These laws are about movement while waiting and
scheduler invariants. None of them states a deadline for route completion. Status: green at
HEAD (12 of 12 on this Mac with L1; Codex reports green on c6a with Nim 2.2.10).

### 1.3 Reports required (not gates)
- PLAN_P10 P10.0 rows: per-seat request-to-install ticks p50/p95/max; oldest request age and
  maximum consecutive waiting ticks; completion order and repeat equality; completed, failed,
  restarted, cancelled request counts. The handoff step 3: "report the first-goal
  route-latency tail (p50/p95/max ticks at 16/32 seats) for that exact B". No numeric
  completion deadline appears in any ratified text. The `--latency` harness supplies the
  first four items; "oldest request age" is derivable from `first_wait_tick` of unpublished
  seats but is not summarised as a field yet.
- Colossal per-query cost and activation time with the new shape, plus follow-ups (ruling 3).
- Every experiment: preregistered card, scoreboard row, "what it does not establish".

### 1.4 Frequencies, sentinels and who gates
PROCEED_P10, verbatim in substance: focused suites and touched shards during the work;
`tests/tests.nim` once at the end of Phase 10 and once in Phase 11; one isolated containment
pair (paired with a same-host `origin/main` run, never read as a nav pass/fail on x86);
both server compile shapes (runtime-linked and runtime-stub `nim check` of `src/ctf.nim`);
merge `origin/main` at the boundary and say what conflicted; phase reports as before; end
Phase 10 with `PHASE 10 DONE` on its own line, continue into Phase 11 without waiting, end
with `PHASE 11 DONE`. Claude gates Phase 10 by re-running the corpus gate, the liveness laws,
the suites, both compile shapes, the containment pair, and by reading the fixture and viewer
evidence. Handoff step 5 adds the canonical Docker gate (quality, activation, memory,
determinism only) before Phase 11, and Phase 11 is docs audit (design doc plus HTML twin,
BR_PLAYS.md, FIRST_LIGHT_DEMO.md, AGENTS.md), final verification, Asana update (Asana and
publishing remain unauthorised for this session per the peer brief).

### 1.5 Version, fixtures, viewer, docs
- GameVersion: this branch claims 63 (`sim_types.nim:141`). Correction (Codex): the
  `GV_CLAIMS_BEFORE_L0.json` snapshot shows `origin/maxwell/wire-over-identity` also claiming
  63 while `origin/main` and every other branch are at 62, so 64 is the next free number in
  that snapshot and 63 is contested; rescan at the boundary. Run
  `tools/ci/check_gameversion.sh origin/main` at the boundary; the changelog headline must
  name the rule. Masks change with M0? No (M0 is byte-identical routes and pops). Masks
  change with L0 and L1 (seats follow instead of steer), so if either ships, GV63's headline
  must describe the shipped behaviour and the fixtures must be cut after it.
- Fixtures: all nine, every time (`AGENTS.md` "Replay fixtures" table: capture-seed1,
  wipe-lives1, draw-nokill, seats-numagents16, tests/replays/ctf, gen-small-pits,
  gen-colossal-4team, br-golden-16team, br-zonepaint-smoke), on an idle machine, at the final
  B and final code, once. Status: not re-recorded since the wip checkpoint (deliberately).
- Viewer: Docker rebuild plus source-stamp and replay smokes after any `src/*.nim` change.
  Status: rebuilt and stamp-verified at M0 (8265f53a) and at the L0 checkpoint (c5f39376);
  will need another after L1 and again after the final B.
- Docs: budget text in the design doc and HTML twin, BR_PLAYS.md, FIRST_LIGHT_DEMO.md,
  AGENTS.md (M0's DOC_AUDIT covered AGENTS.md; the rest is Phase 11).

## 2. Did we invent an extra inherited gate?

Yes, in one specific sense, and no in another.

- The `--latency` row's own `pass` (all seat-waves published within 2,000 ticks, deterministic)
  was registered by us (`PEER_CARDS.md` section 5, `LATENCY_BRIEF.md`, `L0_PREREG.md`,
  `L1_PREREG.md`) as the success criterion for the L0 and L1 experiments. That is a
  preregistered experiment criterion and it stands as written; its failures are recorded and
  must stay recorded (`LATENCY_XEON_REPORT.md`, `L0_REPORT.md`, the L1 rows below).
- It is not an inherited Phase 10 gate. No ratified clause sets a completion deadline; the
  inherited requirement is to report the tail. Treating a `--latency` failure as an automatic
  Phase 10 rejection would add a gate James did not set. The correct inherited action is to
  report the tail honestly, which here means reporting censoring: at B = 1,024 the far tail
  is not a finite number, because most seats never receive a route within 2,000 ticks.
- Whether a censored far tail is acceptable for production is James's decision under
  PROCEED_P10 item 2 ("if 32 seats miss ... lower B or reduce other measured body work;
  never relabel"). The ruling anticipated that the tick gate would push B down; it did not
  anticipate that the chosen B would leave far routes unreachable. That is a finding to put
  in front of him with the numbers, not a gate we get to pass or fail ourselves.

Censoring versus measured tails: the near tails are measured and finite (16 seats 18/48/51
ticks, 32 seats 54/135/141, identical on Mac, Xeon and c6a). Every far figure produced so
far is censored: B0 and Xeon published nothing; L0 and L1 published exactly three seats per
far wave (ticks 41, 82, 1108 on c6a under L1) and the observed p95 of 1,129 describes those
three, not the 13 or 29 seats that never got a route. Any table must carry the published
count and the cap next to the percentile.

## 3. What the L1 rows say (read during this audit; Codex has not yet reported them)

`L1-c6a/latency-r1.json` and `r2` (identical non-timing content, deterministic in-process):
every measured far wave hits the 2,000-tick cap with 3 of 16 or 3 of 32 seats published; the
near waves complete every seat. Per far wave: 2,048,000 pops, 81 admissions, 80 completions,
0 scheduler restarts, 118 or 150 weight refreshes. The three published seats carry request
revisions 37, 30 and 14 at wave end; every unpublished seat is `brlPending` with request
revision 1, zero replacements, no failure, and `first_wait_tick` equal to the wave's first
tick: they were never admitted.

Reading: L1 removed the restart problem completely (0 restarts), and a different mechanism
now binds. The installed-route expiry on every cadence makes each routed seat re-request
every 32 ticks; SJF ranks by the octile estimate from the seat's current position, and the
three seats that have a route have moved closer to the goal, so their re-requests always
outrank the never-admitted seats, whose estimate is the full distance. With about 25k pops per
re-planned far route and B = 1,024, three seats' expiry-driven replans consume the entire
budget (80 completions in 2,000 ticks), and admission never reaches seat 3. This is
starvation by policy (no aging in stable SJF plus unconditional expiry), not by the danger
rule. It follows from two ratified clauses acting together: "stable shortest-job-first
admission" (PROCEED_P10 item 1) and the expiry Codex chose to preserve (zone-price refresh).
Changing either is a contract-level decision for James. In real play the same combination
applies whenever the budget is saturated: seats near their goals keep replanning, seats far
from theirs never start. This is the single most important finding of the latency work and it
should be reported ahead of any budget number.

## 4. Evidence map: required item, current evidence, missing work

| Required | Evidence on disk | Missing |
|---|---|---|
| Baseline B on real hardware (handoff steps 1-3) | B0 m6i (1,024), B0-c6a (2,048), B0-m5a (none; floor fails at B = 0), all 3 repeats, raw JSON, prereg | A ruling on which hosts define the fleet gate (m5a fails at any budget; c8i/m8i not measured: quota and credential rotation) |
| Corrected moving rows and request overhead <= 100 us (step 2) | request overhead 2-30 us p95 on m6i and c6a | none |
| First-goal latency tail at the chosen B (step 3) | `--latency` rows on Mac, Xeon, c6a for B0, L0, L1 | Cannot be reported as finite; report censoring and the starvation mechanism (section 3); add an "oldest request age" summary field if the P10.0 row format is to be honoured literally |
| Quality gate at final code | B0, M0, L1 full corpus (L1: 3,072 cases, 0 missing/illegal, same hash, `L1_REPORT.md`) | rerun at whatever ships last |
| Pool 16 MiB shared and 256 MiB total | M0 all 64 maps; L1 all 65 rows pass: largest pool shared 16,023,601 B, colossal 261,919,620 B including the 778,752 B scratch | canonical Docker rerun |
| Activation time 2x/3x | ratios computed by Codex from the L1 rows: 2.563 (pool 48), 2.420 (colossal) | James's ruling on whether 2x covers the mixed-graph build; report both ratios meanwhile |
| Tick gate and headroom at final B on the gate host | B0, M0, L0, L1 timing rows on c6a; m5a fails | decision on m5a; final B |
| Determinism arm64 vs amd64 | B0 hash identical Mac/Xeon | canonical Docker `--all` after final code |
| Liveness laws, focused suites, both compile shapes | green at HEAD (Mac, c6a) | rerun at final code |
| `tests/tests.nim` once end of P10, once in P11; containment pair | not run since the wip checkpoint | both |
| GameVersion check, nine fixtures, viewer, docs | GV63 free; viewer rebuilt at M0 and L0; AGENTS.md audited at M0 | check at boundary; fixtures once at final code; viewer after L1 and final; design doc, HTML twin, BR_PLAYS, FIRST_LIGHT_DEMO |
| Colossal per-query cost and activation with follow-ups (ruling 3) | activation rows carry far-query pops and ns for colossal | the follow-up list in the Phase 10 report |
| Sentinels and phase reports | scoreboard, ledger, per-unit reports | `PHASE 10 DONE`, `PHASE 11 DONE`, the Phase 10 report's budget-correction section |

## 5. Findings that need a decision, stated once

1. Far-route starvation at B = 1,024 under stable SJF plus per-cadence expiry (section 3):
   contract-level; James.
2. m5a cannot pass the tick gate at any budget (floor 4.24 ms p95 at B = 0). Performance
   work on the floor is already authorised by the handoff and needs no new approval; only a
   fleet exclusion or a new stale-cost policy would be a distinct decision
   (`QUALIFICATION_FLOOR_OPTIONS.md` sections 4 and 6, `COMPILER_REVIEW.md`).
3. Activation-time ratio is ratified but unenforced since 937ea830, and the current
   map + index + mixed-nav ratio exceeds 2x on pool 48 (2.563) while colossal is within 3x
   (2.420). Whether 2x applies to the mixed graph, which postdates the clause, is James's
   call; report both ratios until then. Not a threshold change.
4. The handoff and Asana quality text (3.0/10.0) lags the in-force 0.5/3.0: fix in Phase 11
   docs.
5. The `--latency` pass rule is our experiment criterion, not an inherited gate; keep it for
   experiments, do not present it as Phase 10 acceptance, and report far tails as censored
   with counts.
6. Workload scope (found during `RASTER_REVIEW.md`, verified at HEAD): the shipped
   `battle-royale-s2` variant in `coworld_manifest_paintbot.json` sets `gunRange: 1300`
   explicitly and `mapPath: brpool16`, which resolves to the 11 giant maps in
   `data/br_map_pool.json`; the corpus, the tick and latency rows and the memory ledgers use
   the 64-map `brpool` file at its 331 px metadata. The 331 px corpus stays the frozen
   quality reference. Whether the deployed manifest matches the repo one must be confirmed;
   if it does, the tick, latency and memory qualification rows need a paired diagnostic at the
   configured range and pool before any host floor is called production-representative.
