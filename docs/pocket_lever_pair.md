# pocketThreat + hpGate — build report (2026-08-07)

Branch `maxwell/paintbot-pocketthreat`, off `maxwell/paintbot-v45` (GV40).
Both levers ship **gated OFF** behind `POCKET=1` / `HPGATE=1`.

## Bottom line

| | result |
|---|---|
| Engine parity | ✅ live field = **GV40** (coworld 0.7.207); our checkout = GV40. Matched. |
| Premise A (widen 150→300) | ✅ **survives** GV40 — 68.6% of carrier-killers stand outside 150px (GV27 said 69.6%) |
| Premise B (HP-gate the touch) | ✅ **strengthens** — 1-HP steals convert 6.5% vs 43.0% at full HP |
| Premise C (solo fresh gun = defended) | ⚠️ **re-framed** — only valid *paired* with the widening; alone it is an anti-signal |
| pocketThreat fires? | ✅ **yes** — 623 flipped decisions / 3081 gate frames (20.2%) |
| hpGate fires? | ✅ **yes, but rare** — 25 fires; funnel below names why |
| Field gate | ❌ **BLOCKED** — league rounds paused, and we are disqualified |

The lever pair is built, wired, and verified to change real decisions. It is
**not** validated: the hosted asymmetric A/B that is the only valid gate for a
symmetric perception change cannot be run right now. See §5.

## 1. Engine parity (done first, and it moved)

The field bumped **0.7.174 → 0.7.207 at round r2582**, and with it
**GameVersion 35 → 40**. `coworld_name` flipped `ctf` → `paintbot` at the same
round and round size jumped 20 → 72 episodes.

Read off the replay headers, not assumed:

```
r2581  coworld 0.7.174  ->  GameVersion 35
r2583  coworld 0.7.207  ->  GameVersion 40
```

Our `v45` checkout is GV40, so we are at parity. Everything below is measured
on GV40 replays with an extractor built at GV40 — 144/144 extracted clean,
which also proves the recordings re-simulate deterministically under our engine.

Two things this exposed:

- **The GV40 corpus is exactly 2 rounds.** r2582 and r2583 are the only GV40
  rounds that exist (r2581 was four days earlier, on GV35). 144 episodes is
  therefore *100% of the available current-engine data*, not a sample of it —
  which bounds every confidence interval below and cannot be improved until
  the league resumes.
- **`scout.py`'s GV guard was silently dead.** `our_game_version()` reads
  `src/ctf/sim.nim`, but `GameVersion` moved to `sim_types.nim`, so it returned
  `None` and the version-skip check never fired — mismatched replays fell
  through to opaque subprocess failures instead of being reported up front.

Despite `coworld_name = paintbot`, the league's "CTF Default" variant still
runs the **fixed classic arena**: `flag_steal` lands on exactly two points,
(186,329) and (1049,329), across all 144 episodes. `pocket_diag.py` reads the
pedestal off the steal event rather than hard-coding it, and prints a warning
if that census ever exceeds a handful of points — so a future random-map bump
reports itself instead of quietly averaging over maps.

## 2. The diagnosis, re-measured (tools/ladder/pocket_diag.py)

144 episodes, 148 steals. Outcome: 48 captures (32.4%), 70 killed (47.3%),
30 unresolved.

**Premise A — carrier-killer distance from the pedestal (n=70).** Median
**201px**, p75 347px, p90 479px. 48/70 (**68.6%**) stood beyond the 150px
`GrabStackRange`. The GV27 diagnosis said 48/69 (69.6%) — the premise survived
the continuous-turret-aim change essentially unchanged.

The honest limit: **30% of killers stand beyond 300px too.** Widening to 300
covers 38.6% of what 150 misses, not all of it. This is a partial fix by
construction, and chasing the tail collapses the discrimination below.

**Premise B — HP at the steal.** `flag_steal.hp` is `-1` (never read), so HP is
reconstructed from each slot's damage/heal/respawn timeline.

| hp at steal | steals | share | captures | conversion | median life if killed |
|---|---|---|---|---|---|
| 1 | 31 | 20.9% | 2 | **6.5%** | 37t |
| 2 | 38 | 25.7% | 12 | 31.6% | 125t |
| 3 | 79 | 53.4% | 34 | **43.0%** | 162t |

A 6.6x conversion gap. Those 31 one-HP steals returned two captures for 23
deaths. This is the higher-confidence half of the pair: it needs no position
estimate at all, because a bot knows its own HP exactly.

**Premise C — does a body-count gate actually discriminate?** This is where the
task's framing had to change. Counting bodies at the *death* tick flatters every
threshold, because the bot gates its dive on what it sees **at the steal**.
Scored there, on the spread between a gate's flag-rate on steals that got the
carrier killed and on ones that captured:

| gate | fatal | capture | spread |
|---|---|---|---|
| ≥1 enemy within 150px | 21.4% | 25.0% | **−3.6pp** (anti-signal) |
| ≥2 enemy within 150px | 10.0% | 4.2% | +5.8pp (today; fires 7/70) |
| ≥2 enemy within 300px | 15.7% | 12.5% | +3.2pp |
| **≥1 enemy within 300px** | **52.9%** | **33.3%** | **+19.5pp** |

**Only the pair works.** Widening alone is +3.2pp; dropping the bar alone is
actively harmful. The proposed cell is the single combination in the 2×2 with
real discrimination — a confirmation of the design, and a warning that neither
half may ship on its own.

Two bounds stated rather than buried: the spread decays **+19.5pp → +10.1pp** as
the position-staleness window widens 20t → 60t, and even at its best the gate
suppresses **a third of the dives that would have captured**. Those are deferred
rather than cancelled (the gate holds a standoff and re-tries), but that is
exactly the thing a mirror cannot measure and the field can.

## 3. What was built

`pocketThreat` — in `holdGrab`, count fresh enemy guns within
`PocketThreatRange` (300) instead of `GrabStackRange` (150), and when **no mate
is covering** drop the bar to `PocketThreatSoloDefenders` (1). No new branch and
no new destination: making the sentry *count as a defender* is what re-aims the
existing standoff-suppress hold at it.

`hpGate` — refuse the disarmed touch at or below `HpGateTouchHp` (1) unless a
mate is covering or the pocket is genuinely clear. It deliberately outranks
`haveAdvantage`: the 6.6x conversion gap does not care whether we hold a local
numbers edge. The hold also un-blocks `medKitEcon` (already keyed to
`ownHp <= 1`), so the bot heals and returns at 3 HP.

Both sit inside `holdGrab`'s existing `> GrabCommitRing` floor, so they govern
the **approach** and leave the last 60px to `touchCommit` — they compose with
the touch latch rather than fighting it, exactly as specified.

## 4. Census — the levers actually fire

`-d:ptprobe`. Every counter is a **delta against the decision the shipped gate
would have made on the same frame**, because a lever that only fires where the
old logic already held is a no-op wearing a counter.

10 games, seed 23, `SHIPBASE=1 CONTROL_SHIPPED=1`, hunters on the 8 Red seats:

```
PT-PROBE armed?  hunter.pocketThreat=true hunter.hpGate=true  (control forced OFF by design)
PT-PROBE gate frames 3081  oldHold 78 -> newHold 701   ⭐ flip 623 (20.2% of gate frames)
PT-PROBE sentry-band (fresh gun 150-300px)  1387 frames    hpGate-only blocks 25
PT-PROBE hpGate funnel: gate 3081 -> lowHp 920 -> solo 148 -> pocket-armed 87 -> FIRED 25
```

Control cell (`POCKET`/`HPGATE` unset) reports `flip 0` on the same seed — the
arm is the only difference.

**hpGate is real but rare, and the funnel says why**: of 920 low-HP gate frames
only 148 are solo (a mate is usually near), 87 of those face an armed pocket,
and 25 flip a decision. At a smaller sample (4 games, seed 11) it fired **zero**
times — so a short mirror run can report hpGate as dead code when it is merely
infrequent. Do not score it on a small n.

### Two traps closed on the way

1. **The control was arming itself.** Both levers read their env knob *inside*
   `shippedCombatTune()` (the touchCommit idiom), so under `CONTROL_SHIPPED=1`
   the control tune picked the same env up and **both teams ran the lever** —
   an A/B comparing a policy against itself, reporting a clean and meaningless
   null. `harness.nim` now forces `baseTune.pocketThreat/hpGate = false`.
2. **The census printed nothing.** baseline.nim flushes probe counters in
   `runBot`'s shutdown path, which the eval driver never executes (it calls
   `decide()` directly), and the pocket gate is hit far too rarely to cross the
   periodic mod-2000 boundary. The counters existed and emitted silence, which
   is indistinguishable from "never fired". The census now reports from the
   harness summary — and states whether the arm was on at all, since `flip=0`
   from an unarmed run is a wiring bug, not a null.

A third, environmental: a stale background harness from a timed-out invocation
was interleaving its output into the same file and made the armed cell read
`flip 0`. Renaming the binary and re-running clean gave `flip 25`. Any A/B in
this repo that writes to a shared path needs a unique filename per run.

## 5. The field gate — BLOCKED, and why

The correct gate is a **hosted asymmetric A/B**; a mirror cannot score either
lever, because both are symmetric changes to how a pocket is read and self-play
hands both sides the same caution. It cannot be run today:

- **League rounds are paused.** `rounds_paused_at = 2026-08-07T03:51:46Z`. The
  last round, r2583, completed at 03:56Z. No rounds have landed since.
- **We are disqualified.** Our newest league membership (created 2026-07-30) is
  `status=disqualified`; every older one is `competing/benched`. **0 of the 224
  most recent league episodes involve `softmaxwell`** — we have fielded nothing
  for eight days. The division carries
  `disqualify_after_consecutive_failures: 3`.

Both must be cleared before the gate can run, and the DQ is the actionable one
(per the standing note, a DQ never self-heals; the fix is rebuild-on-main +
resubmit). That is out of scope for this task but it blocks the epic's last
mile, and no amount of local work substitutes for it.

### The A/B to run when the league returns

**Three arms, not two.** Both levers hold more often, for independent reasons.
Stacked, they could cross from caution into simply not grabbing — the failure
mode of this whole gate family — so the combined arm needs its own cell:

| arm | env |
|---|---|
| control | `SHIPBASE=1 CONTROL_SHIPPED=1` |
| pocketThreat | `SHIPBASE=1 CONTROL_SHIPPED=1 POCKET=1` |
| hpGate | `SHIPBASE=1 CONTROL_SHIPPED=1 HPGATE=1` |
| both | `SHIPBASE=1 CONTROL_SHIPPED=1 POCKET=1 HPGATE=1` |

Both seatings, and **both** `SHIPBASE=1` and `CONTROL_SHIPPED=1` on every arm —
without them the null floor is fake and inflates every effect size. Judge on the
mechanism metrics (`tools/ladder/touch_metrics.py`: approach → conversion →
steals/caps), not the win count; a ~100-episode arm's win delta sits at the
noise floor.

**Pre-registered prediction, so this cannot be rationalised after the fact:**
pocketThreat should *lower* steal count and *raise* steal→capture conversion. If
steals fall and conversion does not rise, the gate is not discriminating in play
the way it does in the corpus — that is a refutation, and it belongs in the
never-retry ledger rather than a re-tune of the radius.

## Reproduce

```sh
# extractor must match the replays' GameVersion (GV40 here)
nim c -d:release --hints:off -o:bin/extract_events tools/extract_events.nim
python tools/ladder/pocket_diag.py --events '/tmp/pt_ev/*.jsonl' --max-stale 20

# census
nim c -d:release -d:ptprobe --opt:speed -o:/tmp/pocketcensus players/baseline/eval/harness.nim
POCKET=1 HPGATE=1 SHIPBASE=1 CONTROL_SHIPPED=1 HUNTER_SLOTS="0,2,4,6,8,10,12,14" \
  /tmp/pocketcensus --games 10 --seed 23 --ticks 4000
```
