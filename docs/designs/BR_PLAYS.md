# BR PLAYS — the Season 2 strategy vocabulary

This is the normative behavior and parameter reference for the seven Season 2
Battle Royale plays. Their core-WASM reference modules live in
`play_sdk/reference/`; policies upload those modules and submit ordered
`PlayCall` ladders over the Season 2 wire described in
`strategy-play-calling-shell-2026-08-29.md` §4.3 and §7.

The vocabulary began with Maxwell's direction (2026-08-29): the optimization loop should compose
strategies that are complex, reactive, and prioritized — do-not-kill lists,
ally-relative routing, negotiated alliances — and "that needs to be more
complex than a JSON file… but it doesn't need code interpretation yet. We
just need to come up with a handful of plays and the parameters they would
require, and hard code those in for now." The architecture has since moved from
that one-page prototype to uploaded WASM; the seven behavior contracts below
are the part that survived unchanged.

## The architecture move

A **play** is a named, uploaded WASM behavior module with a typed manifest.
The policy submits an **ordered ladder of play invocations** — stencil's
first-match-wins priority ladder, one level up:

```json
{ "plays": [
    {"play": "supply_run", "when": "self.hp < 40", "params": {"detourMax": 500}},
    {"play": "pact",       "params": {"partners": ["duo03"], "holdFire": {"aliveTeams": 2}, "protect": true}},
    {"play": "edge_ride",  "params": {"margin": 220, "coverBias": 0.8}}
] }
```

- **Determinism is replay-owned.** The canonical call carries module identity,
  entry ids, guards, and parameters under the 4096-byte call cap. Accepted
  calls are format-2 `0x10` replay records, while the engine records the body's
  resulting per-cog masks in the gameplay hash chain; playback does not
  re-execute policy WASM.
- **Stencil-compatible.** Each play expands to ladder rungs + weights;
  parameters are the per-Intent tunables James already chose to expose.
  Do-not-shoot lists live in BODY-side targeting — where stencil already
  put targeting.
- **The LLM's job** becomes choosing, ordering, and tuning plays — and
  NEGOTIATING them: the pre-round lobby chat (open, non-blocking) is where
  "Maxwell, let's not fight until the end" happens; the authoring loop
  reads chat and writes `pact(partners=[...])` into its next call. Callouts are
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
- The margin is clamped to a quarter of each span, so a late rectangle too
  narrow to carry it degrades to "hold the middle of the band" — every seat
  keeps its own place along the band instead of stacking on the centre.
- Needs: zone rect + phase perception (EXISTS), cover-aware routing
  (EXISTS in nav layers). The old ring-hugger page became this play.

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
- The old third-party-jackal page became this tunable play.

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

## Shipped engine surface

| primitive | status |
|---|---|
| seven core-WASM reference plays | SHIPPED in `play_sdk/reference/`; each has a manifest and focused shard-2 tests |
| body-side never/prefer targeting and pact protection | SHIPPED through the combat-policy overlay and body weapon path |
| attacker-of-ward detection and ward-relative routing | SHIPPED for `bodyguard` |
| zone rect/phase, alive-team count, cover navigation | SHIPPED through the binary play view and body map |
| upload, compile, bind, call, retune, and durable status lifecycle | SHIPPED through the episode's compile plane and ladder |
| replay identity and accepted-call records | SHIPPED in format 2; playback uses recorded masks and records rather than re-running WASM |

The retired one-page flash schema remains under `tools/flash/` only for
deprecated modes. It is not part of this Season 2 contract.
