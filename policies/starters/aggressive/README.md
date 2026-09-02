# starter: aggressive ("HUNTER")

Hunts. The persona prompt tells the model to move toward fights, ride the
zone edge tight, and treat alliances as disposable tools.

What this harness does differently from the other two starters:

- **The busiest live-loop schedule** — up to 8 model calls a match, at
  least 6 s apart, re-called on kills, hp loss, zone phases and being shot
  at (see `../README.md`, "How a starter plays a match").
- **Jackal is the base play** — the always-on rung above any `edge_ride`:
  idle jackal holds in cover with the gun up and joins the first fight it
  hears, the zone reflex handles rotations. For the first 150 ticks the
  harness swaps in `edge_ride` so the seat gets off its spawn first.
- **Kill-feed awareness** — the match summary fed to the model carries the
  accumulated kill feed from the 0xB1 view stream ("tick N: seat V
  eliminated by team K"), so decisions react to fights.
- **Tight clamping** (`adjust_entries` in `policy.py`) — every `edge_ride`
  is clamped toward the aggressive corner: `margin` capped at 160,
  `enterLead` at 120, `coverBias` at 0.5. Any `pact` is forced to
  `onBetrayal: returnFire` with `protect: false`.
- **Race, never avoid** — any `supply_run` or `loot` is forced to
  `contested: race`, and a `loot` rung (detour 500 px) is appended to every
  call; the harness only puts it on the ladder while no enemy is close.
- **Canned turns** open at `margin: 60`, tighten to 50, and the final
  re-call hands the seat to `jackal` (earshot 900, join after a kill, exit
  two kills up) with the tight ride as the fallback rung — even offline,
  this seat visibly plays closer and greedier than the other starters.
