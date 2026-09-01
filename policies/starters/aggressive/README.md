# starter: aggressive ("HUNTER")

Hunts. The persona prompt tells the model to move toward fights, ride the
zone edge tight, and treat alliances as disposable tools.

What this harness does differently from the other two starters:

- **Three model turns** — the shortest re-call interval (two re-calls at
  ~4s), so the ladder is retuned eagerly as the match moves.
- **Kill-feed awareness** — the match summary fed to the model carries the
  accumulated kill feed from the 0xB1 view stream ("tick N: seat V
  eliminated by team K"), so decisions react to fights.
- **Tight clamping** (`adjust_entries` in `policy.py`) — every `edge_ride`
  is clamped toward the aggressive corner: `margin` capped at 160,
  `enterLead` at 120, `coverBias` at 0.5. Any `pact` is forced to
  `onBetrayal: returnFire` with `protect: false`.
- **Race, never avoid** — any `supply_run` is forced to `contested: race`.
- **Canned turns** open at `margin: 60`, tighten to 50, and the final
  re-call hands the seat to `jackal` (earshot 900, join after a kill, exit
  two kills up) with the tight ride as the fallback rung — even offline,
  this seat visibly plays closer and greedier than the other starters.
