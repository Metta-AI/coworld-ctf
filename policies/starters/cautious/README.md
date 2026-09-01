# starter: cautious ("WARDEN")

Survives. The persona prompt tells the model that placement is the score,
fights are mistakes, and health is the only resource that compounds.

What this harness does differently from the other two starters:

- **Two model turns only** — one opening call and one late re-call (~14s
  hold), the fewest model calls of the three; between calls the seat simply
  rides its standing ladder.
- **Safe clamping** (`adjust_entries` in `policy.py`) — every `edge_ride`
  is floored toward the safe corner: `margin` at least 280, `enterLead` at
  least 220, `coverBias` at least 0.8; parameters the model omits are filled
  with conservative defaults (340/280/0.9) instead of the play's own.
- **Never trade** — any `pact` is softened to `onBetrayal: disengage`.
- **Canned turns** open at `margin: 420` with `coverBias: 1.0` — even
  offline, this seat visibly rides far wider than the other starters.
