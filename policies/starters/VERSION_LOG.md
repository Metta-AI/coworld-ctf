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
| model-free **pre-call** ladder right after the playbook upload (clone pact/never-list, scatter base, hold law land before the model answers); cautious hold-fire trigger zonePhase 2 → 1 | v16 (Games Bond) | v15 | v13 | XP `xreq_619f6a5f` (20 eps, 6 starter seats vs 5 field champion duos: nancy, co-gas ×2, Monet, huddle): cautious 0.78 kills / 2% surv / 1004 survT / 1.68 items / 1.02 Glory (4th of 8, leaders 0.82-0.88); collaborative 0.70 / 10% / 1349 survT (field-best) / 1.57 items / 0.97; aggressive 0.53 / 12% / 944 / 1.27 / 0.60 (7th of 8). 0 spawn deaths, 0 crashes in 120 seats. |
| aggressive base play `jackal` → tight `edge_ride` (jackal stays as the gated rung above it while an enemy is tracked) | v16 | v16 | v13 | XP `xreq_7c93d73e` (20 eps, same 5 field duos): aggressive 0.50 kills / 5% surv / **567 survT** / **0.35 items** / 0.55 Glory vs 0.53 / 12% / 944 / 1.27 / 0.60 on the jackal base — no better on kills, clearly worse on survival and items. REVERTED in v17. (cautious 0.88 / collab 0.70 this batch; field noise ±0.3 kills at n=40: nancy went 0.88 → 0.42.) |
| aggressive edge margins: caps 160/120/0.5 → 260/200/0.8, canned rides 40-60 px → 140-200 px, prompt "ride close from cover" (edge_ride base kept) | v17 | v16 | v13 | XP 20 eps vs the same 5 field duos (pending) |

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

**Current recommended build:** `starter-cautious:v16` (Games Bond), `starter-aggressive:v15`,
`starter-collaborative:v13` — the league filler list points at these. The starters enter the league ONLY as fillers (display names `Starter: …`); never submit them under James's players. Items now work: since paintbot 0.7.290 (engine commit 8cb5efe3) the play view carries item
sightings; a hosted all-starter check showed `loot` installing 55 times and 0.7 pickups per
seat (was ~0.2). Still open: no aggressive variant beats the engine default on kills.

Noise floor: the same collaborative build scored 0.97 and 0.65 kills in two
20-episode arms. Treat differences under ±0.3 kills per seat as noise.
