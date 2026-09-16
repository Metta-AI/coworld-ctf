# starter: cautious ("WARDEN")

Survives. The persona prompt tells the model that placement is the score,
fights are mistakes, and health is the only resource that compounds.

What this harness does differently from the other two starters:

- **The sparsest live-loop schedule** — up to 4 model calls a match, at
  least 15 s apart; between calls the seat rides its standing ladder and the
  harness only re-sends it when a gate opens or closes (a medkit while
  wounded, a safe pickup within 300 px).
- **Hold fire, then fight** — `target_law` always carries a hold trigger
  that releases while the seat is alive: `{zonePhase: 2}` (about 25 s into
  play), and an `aliveTeams` trigger from the model is clamped to 7 or more.
  The original `aliveTeams: 6` never released before death: zero shots and
  zero Glory across nineteen hosted episodes.
- **Safe clamping** (`adjust_entries` in `policy.py`) — every `edge_ride`
  is floored toward the safe corner: `margin` at least 280, `enterLead` at
  least 220, `coverBias` at least 0.8; parameters the model omits are filled
  with conservative defaults (340/280/0.9) instead of the play's own.
- **Never trade** — any `pact` is softened to `onBetrayal: disengage`, and
  any `supply_run` is forced to `contested: avoid` with `whenHpBelow`
  floored at 4 (absolute hp units — heal at the first scratch).
- **Canned turns** open at `margin: 420` with `coverBias: 1.0` and the
  hold trigger, and the mid-match turn adds `supply_run` — which the harness
  keeps off the ladder until the seat is actually wounded with a medkit in
  view, so it can never pin a healthy seat in place.
