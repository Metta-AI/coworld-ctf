# BR PLAYS — the hard-coded strategy vocabulary (v1 menu)

Maxwell's direction (2026-08-29): the optimization loop should compose
strategies that are complex, reactive, and prioritized — do-not-kill lists,
ally-relative routing, negotiated alliances — and "that needs to be more
complex than a JSON file… but it doesn't need code interpretation yet. We
just need to come up with a handful of plays and the parameters they would
require, and hard code those in for now."

## The architecture move

A **play** is a hard-coded, named behavior bundle with typed parameters.
The one-page policy stops being raw scored rules and becomes an **ordered
ladder of play invocations** — which is exactly stencil's first-match-wins
priority ladder, one level up:

```json
{ "plays": [
    {"play": "supply_run", "when": "self.hp < 40", "params": {"detourMax": 500}},
    {"play": "pact",       "params": {"partners": ["duo03"], "holdFire": {"aliveTeams": 2}, "protect": true}},
    {"play": "edge_ride",  "params": {"margin": 220, "coverBias": 0.8}}
] }
```

- **Determinism unchanged.** The page carries only names + params (well
  under the ~4KB cap), is flashed on the wire, and lands in the replay as
  a chat record — the entire episode-verify contract survives verbatim.
  Play BODIES are engine-versioned code; changing one is a GameVersion
  event, same as any sim change.
- **Stencil-compatible.** Each play expands to ladder rungs + weights;
  parameters are the per-Intent tunables James already chose to expose.
  Do-not-shoot lists live in BODY-side targeting — where stencil already
  put targeting.
- **The LLM's job** becomes choosing, ordering, and tuning plays — and
  NEGOTIATING them: the pre-round lobby chat (open, non-blocking) is where
  "Maxwell, let's not fight until the end" happens; the authoring loop
  reads chat and writes `pact(partners=[...])` into its page. Callouts are
  the human→AI channel; this is the AI→AI half of the same idea.

## The v1 menu (seven plays)

Every play is evidence-backed by S1/BR measurement, not invented.

### 1. `pact` — the negotiated alliance (Maxwell's example)
Never target pact members; optionally defend them; dissolve at an agreed
endgame and duel clean.
- `partners: [duoId | seatRef]` — cross-team allies (do-not-kill list)
- `holdFire: {aliveTeams: N} | {zonePhase: k} | {tick: t}` — when the pact ends
- `protect: bool` — treat an attack on a partner as an attack on self
  (engage the attacker, move to cover the partner)
- `onBetrayal: "returnFire" | "disengage"` — if a partner shoots us first
- Needs: body-side never-target filter (NEW); attacker-of-ally perception
  (partial: killer tracking exists; aimed-at detection is the Alex-peel
  `aimedAtUs` concept); pact-end trigger on alive-team count (EXISTS —
  BR alive-team readback).
- Evidence: even trade is negative-EV; a kill is only 16% banked; our
  episode's winner (wide-intel) was the LEAST engaged strategy. Avoiding
  conflict is the measured-correct BR doctrine, now speakable.

### 2. `edge_ride` — stay outside, keep to cover
Route along the inside margin of the safe rect, biased through cover;
enter the next ring as late as safety allows.
- `margin: px` inside the safe edge · `coverBias: 0..1` ·
  `enterLead: ticks` before zone dps arrives
- Needs: zone rect + phase perception (EXISTS), cover-aware routing
  (EXISTS in nav layers). ring-hugger page is this play, promoted.

### 3. `bodyguard` — cover each other
Ward-relative movement: hold a leash to the ward, optionally interpose
between ward and nearest threat, peel attackers off a wounded ward.
- `ward: seatRef` (default: duo partner) · `leash: [minPx, maxPx]` ·
  `interpose: bool` · `peelHp: int`
- This is the "adapt routes to what your ally does" primitive: the route
  is a function of the ward's route.
- Evidence: fight SIZE (not count) is the winning axis; a life saved =
  5.6 kills; we historically ACQUIRE and fail to CONVERT — protection is
  conversion.

### 4. `jackal` — third-party the fight
Loiter at earshot of an active fight, join only when it's cheap, leave
with the profit.
- `earshot: px` · `joinWhen: "afterKill" | "bothWeakened"` ·
  `exitAfter: {kills: n} | {hpFloor: h}`
- third-party-jackal page promoted; parameters make it tunable.

### 5. `target_law` — who to shoot, who never to shoot, when to start
The standing targeting filter under every other play.
- `never: [duoId|seatRef]` · `prefer: ["weakened","isolated","revenge","bounty"]` ·
  `holdTrigger: condition` — BR's engagement gate is ONE team-summed
  trigger pull, so the first shot is a strategic commitment, not a tactic
- Evidence: friendly fire was the single biggest S1 loss (63% of the
  death gap); dTeamKill is priced NEGATIVE; the engagement gate makes
  hold-fire discipline the cheapest big lever in BR.

### 6. `supply_run` — take the medkit
Detour to reachable medkits/items when wounded; avoid or race contested ones.
- `whenHpBelow: int` · `detourMax: px` · `contested: "avoid" | "race"`
- Evidence: 0.62 vs 1.84+ medkit take-rate vs the field; we never STEER
  to them; healing conversion is 5.9x worse — this play is that fix, said
  in one line.

### 7. `crossfire` — duo spacing and angles
Keep the pair inside a spacing band and off a shared axis so both guns
bear without friendly-fire geometry.
- `spacing: [minPx, maxPx]` · `minAngle: brads` of separation on the
  shared target
- Evidence: point-blank accuracy inversion + friendly-fire geometry;
  opening concentration is the surviving lever.

## What v1 needs from the engine/runner (delta list)

| primitive | status |
|---|---|
| body-side never-target / prefer-target filter | NEW — aligns with stencil's body-side targeting |
| attacker-of-ward detection | PARTIAL — killer track exists; aimed-at needs the aimedAtUs read |
| ward-relative routing (leash/interpose) | NEW routing mode on existing nav |
| zone rect/phase, alive-team count, cover nav | EXISTS |
| play-ladder page schema + flash record | EXISTS (schema rev of tools/flash SCHEMA.md) |

Cut from v1 deliberately: code interpretation (Maxwell: "not yet"),
mid-life reflash of plays (spawn-boundary flash is canon), any play whose
body would need the 3 open stencil blockers resolved first.
