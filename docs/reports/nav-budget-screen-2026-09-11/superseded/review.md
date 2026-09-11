# Review: nav budget screen (`tools/bench_nav_budget.nim` + `PROTOCOL.md`)

The harness does drive the real ShellEpisode path, and the stuck scenario is a fair worst case. Five things need fixing before any native timings, because the protocol freezes thresholds once timings are observed. I made no edits, ran no builds, and didn't write a plan file, since this was a review-only request.

## What is sound
- **Real path.** Tick 1 activates each seat and puts it in hold. The BR rotate rule then fires every tick (`ticksToNextShrink = BrRotateLeadTicks`, `default_play.nim:85`), so every seat navigates to `target`. Zone-escape can't take over (120 > `ReflexZoneTriggerTicks` 72), and the frames carry no hazards, so the other reflexes stay idle. The empty `contextRoster` is handled safely (`episode.nim:688-694`).
- **Stuck scenario.** Setting `stuckTicks = 8` before each step forces a replan whenever no plan is pending (`body_nav.nim:765`). Planning then uses the full budget every tick, so planning time grows with the budget. That is the right worst case.
- **Moving scenario.** A new target changes the intent bytes. `setStandingIntent` cancels the plan in flight (`body.nim:588`) and `goalMoved` starts a new one, so a burst repeats every 12 ticks.
- **Counters.** `published` is counted correctly (a seat can install at most one path per tick). `pending` is read after the planning stage, so it can report plans still pending at tick 128. The p95 is nearest-rank (sample 122 of 128).

## Defects to fix before native runs

1. **Route progress is not measured.** The only outputs are the mask fingerprint, the pending count and the success count.
   - Nothing records seat position, distance to goal, or arrival.
   - The bench ignores `output.nav.noPathSeats` / `stalePathSeats` (`episode.nim:1160`) and `output.planBudget` suspended/completed/failed events (`:1450`), even though `step` already computes them.
   - `published` only counts successful installs (`body_nav.nim:616`), so a seat whose plan failed looks the same as an idle seat.
   - So "identical fingerprints/progress" can only be checked on masks, and there is no way to show what a higher budget actually buys.

2. **The pass gate isn't the "existing body timing envelope" and doesn't support the protocol's conclusion.**
   - The existing gates are `BodyGateUs = 5 ms` and `RuntimeGateUs = 4 ms` (`containment.nim:74-75`). They cover separate intervals, use `cpuTime`, and take the minimum of 3 samples.
   - The planning pass is explicitly outside the body gate (`body_nav.nim:20-21`).
   - `tools/first_light_probe.nim`, which the docs cite for these gates, no longer exists.
   - A p95/max over the whole wall-clock `step` is a new composite gate that includes ladder, danger and planning. So "a failure rules out adoption under the current body envelope" doesn't follow.
   - Fix: register it as a new screen with a stated rationale, and say what happens if the 256 baseline itself fails. Baseline tick-1 cold cost (lazy ladder creation, activation) makes that plausible.

3. **The p95 isn't like-for-like across budgets in the `first` scenario.**
   - Higher budgets finish the single initial burst in fewer ticks. Once fewer than about 7 ticks of the 128 are saturated, the p95 stops measuring burst cost, and a bigger budget can look cheaper per tick than it is.
   - Only the single max still sees the burst.
   - The per-tick units spent can't be recovered: the `runPlanningTick` return value is discarded (`episode.nim:1449`) and `traceCapacity` is 0.
   - Fix: record units spent or suspension events per tick, and report latency on saturated ticks separately.

4. **Nothing proves the runtime path was measured.**
   - `ShellRuntimeAvailable` requires threads plus `WASMTIME_C_API` at compile time (`episode.nim:25`). Without it, the build silently times the stub `stepShellDefault` path, which has no reflex, context, guard or ladder stages.
   - Fix: add a static assert, or emit `shellInventory()` in the output.
   - Relatedly, only 4 of the 14 stage timings are kept, so a whole-step miss can't be attributed. Keep all of `stageNanoseconds`.

5. **The frozen self state can stop navigation for fixture reasons.**
   - Every tick, `fireCooldown` and `fireWindup` are 0 and `aimBrads` is `seat mod 256`.
   - A seat whose fixed aim happens to line up with the fixed threat cluster, with a clear ray and in range, fires every other tick. Each shot sets `fireHoldTicks = 5` (`body.nim:1237`) and strips movement (`:1374-1377`), and the fire freeze skips `navigationWaypoint` (`:1333`). Such a seat can stay frozen permanently in the 1050/1300 rows.
   - Seats that aren't aligned never turn toward the target.
   - I haven't confirmed that any seat actually lines up, but it is plausible for the BR geometry, and `output.combat` isn't recorded, so it can't be detected.
   - Fix: record combat counts, and preferably apply aim rotation and a cooldown in the motion step.

## Lesser issues
- **Motion model.** 4 px/tick is about 45% above the real top speed (`MaxSpeed/MotionScale` = 704/256 ≈ 2.75 px/tick). Blocked diagonal moves are all-or-nothing with no wall slide, which causes extra stuck replans in `first`/`moving`. The frame's `motionScale: 1, velocity: 1` contradicts both.
- **"Moving" means retargeting.** The rotate intent has `movingGoal = false`, so the moving-goal replan path (`PlanMovingReplanTicks`) is never exercised.
- **Ranges 1050 and 1300.** Danger falloff is capped at 1050 px (`body_nav.nim:161`), so these two rows give identical danger fields and plans. They differ only in danger-rebuild and weapon cost.
- **Process order.** Row order is the same in every process, so arena/16/331/first always absorbs process start-up cost. It hits every budget equally, but its max may fail regardless of budget.
- **Small gaps.**
  - `paramStr(1)` is used without checking it exists.
  - The protocol says "published path revisions", but the bench records counts, not revisions.
  - Seats have no danger field until their first scheduled rebuild. This matches production.

VERDICT: NOT JUST NITS
