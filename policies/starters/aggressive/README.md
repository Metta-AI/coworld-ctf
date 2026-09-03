# starter: aggressive ("HUNTER")

Hunts. The persona prompt tells the model to move toward fights, ride the
zone edge tight, and treat alliances as disposable tools.

What this harness does differently from the other two starters:

- **The busiest live-loop schedule** — up to 8 model calls a match, at
  least 6 s apart, re-called on kills, hp loss, zone phases and being shot
  at (see `../README.md`, "How a starter plays a match").
- **Tight edge_ride is the base play, jackal rides above it when an enemy
  is tracked** — jackal (hold in cover with the gun up, join the first fight
  heard) was the base through v15; against the field it finished 7th of 8
  at 0.53 kills while the two edge_ride-based starters scored 0.70–0.78,
  because an idle jackal waits for fights a cautious field never starts.
  For the first 150 ticks the harness swaps in `scatter` so the seat gets
  off its spawn first.
- **Kill-feed awareness** — the match summary fed to the model carries the
  accumulated kill feed from the 0xB1 view stream ("tick N: seat V
  eliminated by team K"), so decisions react to fights.
- **Close-ride clamping** (`adjust_entries` in `policy.py`) — every
  `edge_ride` is capped at a close-but-covered ride: `margin` at 260,
  `enterLead` at 200, `coverBias` at 0.8. Through v16 the caps were
  160 / 120 / 0.5 and the canned turns rode at 40–60 px; against the field
  that cost survival (567 ticks vs 944) and items (0.35 vs 1.27). Any `pact` is forced to
  `onBetrayal: returnFire` with `protect: false`.
- **Race, never avoid** — any `supply_run` or `loot` is forced to
  `contested: race`, and a `loot` rung (detour 500 px) is appended to every
  call; the harness only puts it on the ladder while no enemy is close.
- **Canned turns** open at `margin: 200`, tighten to 170 and 140, and the final
  re-call hands the seat to `jackal` (earshot 900, join after a kill, exit
  two kills up) with the tight ride as the fallback rung — even offline,
  this seat visibly plays closer and greedier than the other starters.
