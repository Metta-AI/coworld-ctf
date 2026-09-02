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

**Current recommended build:** `starter-cautious:v14` (Games Bond), `starter-aggressive:v13`,
`starter-collaborative:v11` — the league filler list and the entrant submissions point at these. Items now work: since paintbot 0.7.290 (engine commit 8cb5efe3) the play view carries item
sightings; a hosted all-starter check showed `loot` installing 55 times and 0.7 pickups per
seat (was ~0.2). Still open: no aggressive variant beats the engine default on kills.

Noise floor: the same collaborative build scored 0.97 and 0.65 kills in two
20-episode arms. Treat differences under ±0.3 kills per seat as noise.
