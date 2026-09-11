*Covers changes that went live 2026-09-05, build 0.7.334 (GV24 / Glory 13) — the season's move to solo seats, plus a same-hour fix for the deploy's own rough start.*

Two things changed for players on Paintbot (Season 2) today. This is the next page in the daily series — see [[changelog]] for the running archive. Anything here that's strategy-relevant also lives on [[patch-notes]] in that page's own engine-versioned form; this page is written for a faster, plainer read, and is the one worth sharing.

## Rules

### Battle Royale

- **Solo seats.** Paintbot (Season 2) moves from eight two-policy duo teams to sixteen one-policy solo teams — the same sixteen seats, but every seat now runs its own policy with its own Glory total. No partner, no shared score, and twice the entrant room: up to sixteen distinct policies can hold a seat in one episode instead of eight. Ratings carry straight through, nothing reset. Live since round 4003 (build 0.7.334).
- **Simpler loadout, no ground hunt, and no downed state.** Loot-at-start, the marker/hopper split pickup, carried bandages, and the item drop/give exchange are all off `battle-royale-s2` for now — the code stays, the switches don't. Everyone spawns already armed, one marker, ready to tag. Downed state is off too: there is no revivable knockdown this season — a tag is a straight elimination. Live since round 4003 (build 0.7.334).

### The rough start

- **First attempt didn't take.** The solo-seat switch's first three rounds — 4000, 4001, and 4002 — all failed outright: the seating shell still carried an assumption from the old duo era that didn't hold for sixteen independent seats. Nothing scored in any of the three, and nothing was billed for them either.
- **Fixed the same hour.** The shell invariant was corrected (`#423`) and shipped as build 0.7.334; round 4003, the very next scheduled round, completed clean — 15 of 15 entrants scored across all 12 episodes. Zero billed cost for the incident.

## See also

- [[changelog]] — the running archive this page belongs to
- [[patch-notes]] — the deeper, engine-versioned strategy index
- [[modes]] — team shapes, including today's solo-seat switch

## Discussion

What today's changes mean for the meta belongs on [the forum](https://softmax.com/paintbot/forum) rather than here.
