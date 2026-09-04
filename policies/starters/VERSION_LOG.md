# Starter policy version log

Platform version labels are per-policy counters (`coworld upload-policy` prints
the label it assigned). Uploading one persona without the others makes the
three counters diverge, so this log is the only reliable map from a label to
the change it carries. All uploads below were made with
`--use-bedrock --bedrock-model qwen/qwen3-30b-a3b-instruct-2507` unless noted.

| change | cautious | aggressive | collaborative | measured (pinned seats vs 10 random champions, 20 eps) |
| --- | --- | --- | --- | --- |
| v1 first hosted starters (harness read only local POC_* env; every filler pod exited 1) | v1 | v1 | v1 | — |
| v2 ws-contract fix (`COWORLD_PLAYER_WS_URL`) | v2 | v2 | v2 | — |
| v3 chat-window fix (missed 0xB2 echo no longer exits 1) | v3 | v3 | v3 | agg 0.95 kills / 5% survive, collab 0.87 / 3%, caut 0 / 5%; 46 of 114 hosted seats crashed or timed out |
| live loop (stay connected all match, event-triggered re-calls, call budget) + live-state summary | v4 | v4 | v4 | agg 1.07 / 15%, collab 0.62 / 2%, caut 0.03 / 0%; 1 crash in 95 seats |
| `when` guards on the wire + always-on edge_ride base + connect retry + ping_timeout=None | v5 | v5 | v5 | collab 0.97 / 5%, agg 0.68 / 8%, caut 0 / 5% (guards evaluate on zeros for play seats — see README) |
| cautious hold-fire trigger `{zonePhase: 2}`, aliveTeams clamped ≥ 7 | v6 | — | — | caut 0.40 / 0%, 1.6 shots (was 0.12), 0.45 Glory (was 0) |
| `loot` reference play added to every ladder (gated) | v7 | v6 | v6 | never run as an arm |
| harness-side gating + ladder maintenance (no wire guards) | v8 | v7 | v7 | agg 0.60 / 5%, caut 0.25 / 2%, collab 0.97 / 12% |
| same image, `POC_NO_BASE_PLAY=1` secret-env (no edge_ride base; engine default + reflex drive) | v9 | v8 | v8 | agg 0.78 / 2%, caut 0.35 / 2%, collab 0.97 / 2%; Glory up across the board |
| aggressive `base_play="jackal"` (jackal always-on above edge_ride) | — | v9 | — | 30 eps: agg 0.72 / 8%, caut 0.63 / 0%, collab 0.88 / 10% |
| loot gate relaxed to "no fresh enemy within 500 px"; loot notes in every prompt; docs | v10 | v10 | v9 | 60 eps pooled: agg 0.82 / 7% (Glory 1.07, spawn deaths 22%), caut 0.59 / 6% (Glory 0.75), collab 0.78 / 7% (Glory 1.05); pickups unchanged (~0.2, the view never carries items) |
| aggressive spawn-phase override: edge_ride base for the first 150 ticks, then jackal | — | v11 | — | 29 eps: agg 0.74 / 5%, spawn deaths 27% → 17%, survival ticks 594 → 727 |
| same images, `--bedrock-model anthropic/claude-haiku-4.5` (does the model matter?) | v11 | v12 | v10 | 30 eps: agg 0.72 / 2%, caut 0.27 / 3%, collab 0.85 / 7% — indistinguishable from qwen (arm K); the model is not the lever today |

| player swap: cautious re-uploaded as player **Games Bond** so it can hold its own champion seat (v12 was the same image accidentally bound to the default player — inert) | v12 (James Botts), v13 (Games Bond) | — | — | competitive seating |

| never shoot your own clone: harness pacts with the entrant's other seats and keeps them on target_law's never-list (44 of 51 early competitive aggressive deaths were clone-on-clone gun kills) | v14 (Games Bond) | v13 | v11 | competitive rounds from 3705+ |

| `scatter` spawn-phase base (walk away from the nearest enemy for the opening ticks, then yield) | v15 (Games Bond) | v14 | v12 | competitive rounds 3705-3706 (30 eps, vs 8 real entrants): aggressive 0.52 → 0.69 kills, survival 4 → 12%, survival ticks 685 → 1164 (longest in the field), pickups 0.15 → 1.08 (most in the field), Glory 0.63 → 0.88, spawn deaths 20 → 10%; cautious debut 0.48 kills / 1.25 pickups / 42% moving / 0 spawn deaths. Field leaders (co-gas) ~1.1 kills. |
| model-free **pre-call** ladder right after the playbook upload (clone pact/never-list, scatter base, hold law land before the model answers); cautious hold-fire trigger zonePhase 2 → 1 (which, it turned out, releases at the drop — the zone reports phase 1 from the first tick — so no hold at all) | v16 (Games Bond) | v15 | v13 | XP `xreq_619f6a5f` (20 eps, 6 starter seats vs 5 field champion duos: nancy, co-gas ×2, Monet, huddle): cautious 0.78 kills / 2% surv / 1004 survT / 1.68 items / 1.02 Glory (4th of 8, leaders 0.82-0.88); collaborative 0.70 / 10% / 1349 survT (field-best) / 1.57 items / 0.97; aggressive 0.53 / 12% / 944 / 1.27 / 0.60 (7th of 8). 0 spawn deaths, 0 crashes in 120 seats. |
| aggressive base play `jackal` → tight `edge_ride` (jackal stays as the gated rung above it while an enemy is tracked) | v16 | v16 | v13 | XP `xreq_7c93d73e` (20 eps, same 5 field duos): aggressive 0.50 kills / 5% surv / **567 survT** / **0.35 items** / 0.55 Glory vs 0.53 / 12% / 944 / 1.27 / 0.60 on the jackal base — no better on kills, clearly worse on survival and items. REVERTED in v17. (cautious 0.88 / collab 0.70 this batch; field noise ±0.3 kills at n=40: nancy went 0.88 → 0.42.) |
| aggressive edge margins: caps 160/120/0.5 → 260/200/0.8, canned rides 40-60 px → 140-200 px, prompt "ride close from cover" (edge_ride base kept) | v17 | v16 | v13 | XP `xreq` field20_aggr17 (20 eps, same 5 field duos): aggressive 0.45 kills / 2% surv / 941 survT / 1.07 items / 0.47 Glory — survival and items back to jackal-base levels, kills unchanged (0.53 → 0.50 → 0.45 across the three arms is inside the ±0.3 noise). cautious 0.88, collab 0.80 this batch. Three batches now agree: aggressive ≈ 0.5 kills, cautious ≈ 0.85, collab ≈ 0.75. |
| spawn phase: no gated controller above `scatter` (a jackal whose gate opened at spawn held the seat on the spawn point, on top of its duo partner — the engine seats both duo members on one authored point — where the two shoot each other; 32% of aggressive seats were still on the spawn point 150 ticks in vs 0% cautious/collab) | v18 | v16 | v13 | XP `xreq_b9328e65` (20 eps, same 5 field duos): aggressive 0.60 kills / 12% surv / 1138 survT / 0.75 Glory — its best batch (v15 0.53, v16 0.50, v17 0.45; survT 941 → 1138), still inside the ±0.3 noise on kills. collab 0.90 (2nd of 8), cautious 0.53 this batch (its four batches: 0.78 / 0.88 / 0.88 / 0.53). The mechanism is confirmed outside the noise: aggressive seats still on the spawn pixel 150 ticks in went from 11/40 (v17) to 0/40 (v18). |
| (engine) paintbot 0.7.298 = GameVersion 52: duo partners no longer spawn on one pixel (`SpawnShareStagger` 24 px) | v16 | v18 | v13 | XP `xreq_8c32fcc1` (20 eps, same 5 field duos, on 0.7.298): 0/160 duo pairs on one pixel at play start (GV51: 160/160). cautious **1.00 kills / 1.45 Glory (1st of 8)**, collab 0.78 / 1407 survT (2nd), aggressive 0.60 / 0.78 Glory (5th). Same batch shape on 0.7.297 (still GV51): cautious 0.68, collab 0.72, aggressive 0.38. |
| aggressive scatters until the first shrink (`spawn_phase_ticks` 340, new Persona knob; others stay at 150) | v16 | v19 | v13 | XP `xreq_fd33acb3` (20 eps, 0.7.298, ROTATED roster): aggressive **1.35 kills / 20% surv / 1568 survT / 1.75 Glory — 1st of 8**, ahead of every field champion (richard 0.97, cautious 0.78). Two things changed at once (scatter window and roster order), so a replicate and a v18-on-rotated-roster counterfactual followed: v19 replicate 1.23 kills (1st of 8), **v18 on the rotated roster 1.20 (1st of 8)**. The jump was the roster, not the scatter window: with the fixed roster the aggressive seats spawned next to the cautious starter's group every episode and lost 13 of 37 lives to it. v19 stays (indistinguishable from v18, and the longer scatter is the safer opening on GV52's death timing). Pooled over the three rotated batches (n=120): aggressive 1.26 kills / 1.62 Glory, ahead of every field champion. |
| (measurement) five 20-episode batches with rotated/shuffled rosters on GV52, pooled | v16 | v19 | v13 | n=200 seat-rows per policy: **aggressive 1.04 kills / 14% surv / 1212 survT / 1.38 Glory (1st of 8)**, cautious 0.81 / 1.33 items / 1.07 Glory (3rd), collaborative 0.54 / 1056 survT / 0.76 Glory (6th); field: richard 0.86, nancy 0.70, Monet 0.60, relhalpha 0.51, huddle 0.23. |

Seating rule learned the hard way: the scheduler seats **one champion per player**, an
account is capped at **2 active players**, and a policy version is bound to the player
that uploaded it. So at most two starters can compete as entrants at once
(aggressive under James Botts, cautious under Games Bond); collaborative stays in the
filler list, which is only consulted when fewer than 8 entrants are active.

**Pooled before/after, pinned seats vs 10 random champions.** v3 (50 episodes): 0.57 kills and 0.75
Glory per starter seat, 5% end-survivors. Final (60 episodes): 0.73 kills (+28%) and 0.96 Glory (+28%),
6.4% end-survivors. Calibration: a seat with NO policy (engine default rotate + zone reflex + the body's
auto-aim) scores ~0.95 kills / 0.92 Glory, so the play-calling layer is at best level with the engine
today; the gains were cautious and collaborative catching up, plus robustness.

**Current recommended build:** `starter-cautious:v16`, `starter-aggressive:v19`,
`starter-collaborative:v13` — the league filler list points at these. The starters enter the league ONLY as fillers (display names `Starter: …`); never submit them under James's players. Items now work: since paintbot 0.7.290 (engine commit 8cb5efe3) the play view carries item
sightings; a hosted all-starter check showed `loot` installing 55 times and 0.7 pickups per
seat (was ~0.2). Still open: no aggressive variant beats the engine default on kills.

Noise floor: the same collaborative build scored 0.97 and 0.65 kills in two
20-episode arms. Treat differences under ±0.3 kills per seat as noise.

## Fork 2026-09-04: SDK 27c4a368 rebuild, own account, own names

Owner-directed fork, not a lineage accident. `coworld upload-policy` refused a same-name
upload under a different account outright (HTTP 409, "Policy name 'starter-cautious' is
already taken by user ..." — James's account owns the three names above), which is the
correct behavior: it is what stopped this from becoming a silent lineage corruption. The
owner's call, given that wall: fork cleanly under our own account and our own names rather
than route the upload through James's credentials.

James's `starter-cautious` / `starter-aggressive` / `starter-collaborative` are FROZEN in
place at their last builds — `v16` / `v19` / `v13`, still exactly what the league's
`filler_policy_version_ids` pointed at as of this fork (read back 2026-09-04, unchanged
since the "final pooled standings" entry above). Nothing about his line was touched,
reuploaded, or retired; it stays his to pick back up.

This repo's starters are adapted to the post-27c4a368 perception SDK (frame loadout flags,
gun/hopper crate perception, partner held-state — commit `4470067e` on branch
`maxwell/su-starters-sdk27c4a368`) and re-uploaded under the `softmaxwell` platform account
with new names so the two accounts' policies never collide: **`starter-cautious-s2`**,
**`starter-aggressive-s2`**, **`starter-collaborative-s2`**. All three forked together in
one sitting, in step, honoring the divergence warning at the top of this file. The s2-*
line is the one going live in the league's filler list (a separate action, owner-executed,
not part of this upload); James's line is not superseded, only no longer the filler pin.

| change | cautious-s2 | aggressive-s2 | collaborative-s2 | measured |
| --- | --- | --- | --- | --- |
| v1 fork: rebuilt from `starter-cautious:v16` / `starter-aggressive:v19` / `starter-collaborative:v13` against the post-perception-increment SDK (glory-2 §17: frame loadout flags, gun/hopper crate item kinds, partner held-state). `loot`'s existing `case kind ... else: true` routing already picks up crates for free — no new conditioning added anywhere. New `_loadout_text` helper surfaces partner `has_gun`/`has_hopper` in the live-state summary (silent when dark, matching the wire's emit-only-when-true contract). Each persona's `loot` play_notes mention the new crates in its own voice; no mechanism or personality redesign. | v1 | v1 | v1 | — (not yet run; forked and read-back verified only) |

Real IDs, for correlating with the league's `filler_policy_version_ids`: `starter-cautious-s2:v1`
= `e7c421ab-0aae-46f7-9c7d-bd702de2b97b`; `starter-aggressive-s2:v1` =
`9526ab30-1a1f-4d73-a279-53f6ee322078`; `starter-collaborative-s2:v1` =
`4793acbc-8f4f-45f0-b6d1-6c6a13dcf27f`. Frozen pre-fork pins (James's line, untouched):
`7e720dc1-ef74-41e5-ab31-a3f75a026b81` (cautious v16), `6fc62efc-bb04-4ca4-a734-939986d09f7d`
(aggressive v19), `fc151e14-77e0-4ad2-a895-3d7f24b09301` (collaborative v13).
