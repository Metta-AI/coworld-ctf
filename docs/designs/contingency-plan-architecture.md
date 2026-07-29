# Contingency-plan architecture — "chess, not checkers"

## The problem (measured)
Picasso plays reactive **mono-strategy checkers**: `scenarioToPlay` maps one scenario → one play,
executed even when it's losing. We lose the opening (first 1000 ticks vs h006: 14 kills to 6), then
the wipe economy (GV21: timeout = −1 both sides, 5000-tick clock, no spawn-protect) snowballs the
early lives deficit into a loss. 3 single-lever tweaks all regressed → the deficit is **architectural**.

## The fix: a shared-state contingency STATE MACHINE
The SEAL/CQC answer (cqc-video-game-lens §1): a caller pre-briefs a **default + if-then branches** so
the team flows A→(D|F) on a named trigger without re-deciding. The **"backstop the caller"** principle
says: make the plan a *pure function of shared state* so no unit must survive to hold it. We already
have that substrate — `selectPlay(elapsed, ownStolen)` is a shared-clock pure function every bot
computes identically. Extend it into a branching state machine.

### The three SHARED signals (every bot computes the plan identically, zero comms needed)
1. **`elapsed`** = tick − gameStart — shared exactly across all 8 bots.
2. **`ownStolen`** — our flag off its pedestal — globally legible (empty own pedestal).
3. **`enemyFlagState`** ∈ {OnPedestal, CarriedByUs, Dropped} — the "<enemy> heart" sprite is ALWAYS
   visible (bot header L27-29), so every bot knows it without comms.
Comms (the codeword bus) then ACCELERATES convergence for the local-read branches (pick/contact),
but the plan never DEPENDS on a heard call — a bot that hears nothing still flows the shared branches.

### The plan as a phase machine (each phase has a default + branch triggers)
```
PHASE          default posture            branch triggers (shared unless noted)          → next
─────────────────────────────────────────────────────────────────────────────────────────────
OPEN (t<T_open)  spread to lanes,          enemyFlag==CarriedByUs   → ESCORT              seamless
                 contest mid TOGETHER      ownStolen                → DEFEND              (no thrash:
                 (win the first clash as   pick-gained [local-approx]→ PRESS               the branch
                 a group, NOT trickle)     t≥T_open & no flag event → PROBE                is pre-
PROBE           default: pressure the      enemyFlag==CarriedByUs   → ESCORT               computed,
                 weaker flank (read),      ownStolen                → DEFEND                 executors
                 hold the finish           pick-gained              → PRESS                  already
                                           clock<T_force            → FORCE                  know it)
PRESS (up a body) group + hit the side     enemyFlag==CarriedByUs   → ESCORT
                 where we're up, FAST      lost the edge / even     → PROBE
                 before they respawn       ownStolen                → DEFEND
ESCORT (we carry) EVERYONE collapses to    carrier died/flag home   → OPEN
                 the carrier's home lane,  ownStolen (double-steal) → split: escort+DEFEND
                 clear its path, trade for it
DEFEND (ownStolen) full collapse to the    ownStolen cleared        → OPEN
                 thief / recapture race,   (never a half-team hedge — "never split-decide")
                 hunt the exposed carrier
FORCE (clock<T)  commit a grouped flag     — terminal push; the clock punishes stalling,
                 attempt / all-in          so a "good enough" committed hit beats a scoreless draw
```

### Why this beats the flat matrix
- **No thrash:** the branch is pre-computed from shared state, so when the enemy answers, all 8 bots
  transition to the SAME next phase on the SAME tick — no negotiation, no split, no wasted lives.
- **Plans ahead:** OPEN already "knows" it becomes ESCORT-on-steal or PRESS-on-pick or FORCE-on-clock;
  the executor holds the branch, doesn't re-derive it under fire.
- **Never-split-decide + cancel-needs-regroup:** phase transitions are unanimous (shared trigger) and
  ESCORT/DEFEND are full-team collapses, never half hedges.
- **Wins the opening:** OPEN's default is "contest mid TOGETHER" (grouped), directly attacking the
  14-6 opening-clash deficit (we currently spread to lane roles and get picked off individually).
- **Force-on-clock:** FORCE prevents stalling into the −1 timeout — a decisive attempt every game.

### Executor mapping (reuse existing levers, just SELECT them by phase)
- OPEN/PROBE → selectPlay flank + group-up bias (new: opening cohesion)
- PRESS → regroupPush/tempo (the man-advantage push, already built)
- ESCORT → carrier-collapse: all free guns to the carrier lane, suppress chasers (threat-kill, since
  body-block is void); huntCarrier for the defensive mirror
- DEFEND → StackDefense + chaseThief/huntCarrier (already built)
- FORCE → all-in pocket rush (late-all-in already exists)

### Build plan (incremental, each A/B'd vs the FIELD)
1. Add `TeamPhase` enum + `teamPhase(elapsed, ownStolen, enemyFlagState, localPickHint)` pure fn.
2. Wire phase → existing executors (mostly re-selecting current levers; the NEW behavior is OPEN
   grouping + ESCORT full-collapse + FORCE).
3. Gate behind `planLayer` tune bool; A/B vs top_n field, seat-rotated.
4. Comms: broadcast the local-approx triggers (pick/contact) as codewords to accelerate convergence,
   but the shared-signal branches work with zero comms.
```
```

---

## ⭐ MEASURED phase occupancy (v29, 2026-07-29, GV23) — the guesses, checked

Everything above about *timing* was a first guess. The `-d:phprobe` phase-occupancy probe
(12 mirror games on the GV23 engine, champion-vs-champion, 266,279 plan-layer `decide()`
frames) measured what the machine actually does:

| phase  | frames  | share |
|--------|---------|-------|
| OPEN   |  44,123 | 16.6% |
| PROBE  |  80,123 | 30.1% |
| PRESS  | 131,024 | 49.2% |
| ESCORT |   6,551 |  2.5% |
| DEFEND |   4,458 |  1.7% |
| FORCE  |       0 |  0.0% |

Game length: **mean 2410 ticks, min 1541, max 4004** — only 1 of 12 games reached tick 3800.

**Two conclusions that change the design:**

- **FORCE never armed.** `ForceClockTick = 3800` ("~76% of the 5000 clock") is *past the end of
  a typical game*: on the wipe economy games are decided by attrition around tick ~2400, not by
  the clock. The FORCE branch — and the `haveAdvantage` pocket-commit it feeds — has been dead
  code in every shipped version since v21. GV23's action-clock floor (`ActionClockFloorTicks`
  500, banked into `overtimeTicks` on each kill/steal) does not rescue it: the floor only extends
  games that are still *active*, so it lengthens the tail without moving the mass.
  → `forceTiming` moves the trigger to a measured `ForceClockTickTuned = 2000` (~40% of nominal),
  sweepable via `FORCE_TICK` so the constant finally gets a real sweep.

- **DEFEND was aiming at the wrong entity.** v26 replaced the inert `discard` with an intercept,
  but pointed it at `mateCarryPos` — the position of **our own mate carrying the ENEMY heart**,
  which has nothing to do with the thief holding *ours*, and is `(0,0)` whenever no mate carries.
  The `> 0.5` guard therefore fell through to `me.y`, so the advertised "full-team collapse on the
  thief's intercept lane" resolved to *"walk to mid at whatever height I already am"* — a mid
  rally, not a recapture. The real thief fix is `bot.carrierPos` @ `bot.carrierSeen` (the own-flag
  banner is centered on its carrier), the read `huntCarrier` and the HomeDefender intercept already
  trust. → `defendTeeth` routes the 6 attacker seats at that fix in three freshness tiers
  (fresh → lead the predicted path; stale → guard the mid crossing on the last fix's lane; blind →
  the old mid-hold, which is only correct in that tier).

**Method note for the next loop:** DEFEND+ESCORT together are only ~4% of frames, so a lever
inside them cannot move the win column much on its own — judge it on its mechanism sub-metrics
(recapture-steer funnel counts, grab→cap, K−D) as well as the score. And always verify occupancy
BEFORE tuning a phase constant: a phase at 0% frames is a spec, not a behavior.
