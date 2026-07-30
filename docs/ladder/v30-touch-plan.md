# Picasso:v30 — the touch-first candidate (plan of record, 2026-07-29)

## Where we are
Rank **10 of 12**, Elo **1366** and drifting (1382 → 1366 within one session). Leader
`ctf-focusfire:v63` sits at **2063** on an 0.848 winrate. Elo is zero-sum, so a flat
policy loses rating even when its own play is unchanged.

## Two findings, from ground truth (123 GV26 league episodes, re-simulated free)

**1. The GV24 crater was the ENGINE, not us — and it is already mostly refunded.**
Winrate cut by exact `coworld_version`:

| build | GV | winrate |
|---|---|---|
| 0.7.102 | GV23 | 0.517 (246/476) |
| 0.7.103 | **GV24 aim-fuzz** | **0.215** (68/316) |
| 0.7.107-111 | GV26 | 0.431 (53/123) |

It hit **10 of 12 opponents in the same round**, so it cannot be a rival shipping. GV24
fuzzed every soldier sprite's rendered gun angle ±20°; it is render-only, yet BOTH sides'
accuracy fell (ours .576→.310, theirs .572→.384) — the whole field had been reading aim off
sprites. GV26 exempted the self marker and we recovered. **No code change is owed here.**

**2. The durable lever is the TOUCH.** On the current engine our accuracy (48-61%) matches
or beats every opponent, K/D ≈ 1.0, and we WIN the wipe count 38-31. We lose captures 15-26.

- Steal once → win **66.7%**. Never steal → **26.4%**. We never steal in **58.5%** of episodes.
- We reach within 40px of the enemy heart about as often as the field (71 vs 79 episodes)
  but convert that to a steal **71.8%** vs their **94.9%**.
- 20 episodes had a bot sitting **5-39px** from the heart — pickup radius is **12px** — and
  never taking it. Only **41 of our shots (0.3%)** were fired inside 60px of it; zero sprays.
- Deaths in the 60-260px standoff ring: **445 ours vs 90 theirs**.

Closing just the touch gap is worth **+5.4pp** (16 episodes × the 40pp swing a steal carries).

## Root cause: `armedRush` has no range floor
Its sibling `holdGrab` IS floored at `> GrabCommitRing` (60px), so it correctly refuses to
ENTER a stacked pocket — that is the approach decision and it stays. But `armedRush` had no
floor, so a body **already inside** the ring got re-armed (gun up, duck/dodge branches back
on) at arm's length from the heart. Three more LIVE branches also outrank the 12px touch
once inside: the grenade charge (sets `holdStill`, gated on `iCarry` but not `pocketRush`),
the engage branch (an armedPocket advances on the ENEMY), and duck/peek (guarded on
`rushing`, which is Mid-only, while `wantPocketRush` includes the FLANKERS — that is the
5-39px cohort).

## The change (arm 1, built)
`touchCommit` — a latch that arms only INSIDE `GrabCommitRing` and gives `armedRush` the same
range floor `holdGrab` already has. Deliberately NOT a rollback of `smartGrab`: that fixed
the approach and works. Two steps from the heart the touch ends the episode and no amount of
covering fire does, so the touch outranks everything there. Env knob `TOUCHOFF=1` yields the
control from the SAME binary, so the A/B has no build variable.

## Later arms, kept separate so a regression can be bisected
2. `tempoPress = false` (`TEMPO=1` restores). Its premise is unobservable — "their reload is
   dead time" needs to see an enemy mid-cooldown, but firing is silent, bullets invisible,
   muzzle bloom spectator-only. It actually tests "wounded OR turned away" where turned-away
   is the GV24-fuzzed facing bit, then crosses 150px (~55 ticks) into a 12-tick cooldown.
3. De-weight OTHERS' `aimBrads`. `aimRotRead` decodes enemy aim from soldier sprite IDs —
   exactly what GV24 fuzzed. 8.7-13.5% phantom "gun is on us" feeds `holdVsGun`/`dangerScore`/
   `boundHold`. No label-only fix exists; widen tolerances, never gate on it. NOTE the SELF
   read is TRUE again in GV26 and must be LEFT ALONE — two auditors proposed deleting a
   working resync.
4. Read the `"fog"` label. `addFogRuns` streams one object per unseen 8px run INTO the player
   view and the fov cache keys on TRUE `aimBrads`; inverting it recovers exact own aim AND
   real visibility through glass, label-only, no pixel decode. Never read by our policy.
5. Give `pushOut` a reachable trigger — both arms are dead in practice, so 2 of 8 seats camp
   home posts all game with no stalemate-breaker on lose-lose timeout scoring.

## Method rules this pass must honor
- **Filter on `gameVersion`.** 1035 cached episodes are only **123** GV26; the rest are two
  superseded engines and lack `heading_brads`.
- **Rebuild the scout extractor on every GV bump** and cherry-pick the roster commit, or
  attribution silently returns "no attributable episodes".
- **Verify event x,y semantics** against `action_id` families: `shot_impact` is the LANDING
  point, `damage`/`hit`/`kill` carry the VICTIM's position.
- **`hp == 0` means "never read"**, not zero health.
- **Diff engine claims against `origin/main:`** — this checkout trails the live engine, which
  cost three peer findings.
- A 60-game win delta is AT the noise floor (±10 wins on a null). Judge on mechanism metrics
  (grabs, caps, the preemption census) plus seat rotation, not a bare win count.
