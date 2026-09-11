*Covers Paintbot (Season 2) on 2026-09-07 — build 0.7.347 went live on the Season 2 ladder from Round 4374, plus a corrected read on pact formation and the verdict on today's earlier standings pause.*

Three things to know about Paintbot (Season 2) today. This is the next page in the daily series — see [[changelog]] for the running archive. Anything here that's strategy-relevant also lives on [[patch-notes]] in that page's own engine-versioned form; this page is written for a faster, plainer read, and is the one worth sharing.

## Rules

### Alliances

- **Pacts are real — the old "zero pacts" read was wrong.** Measuring the pact registry directly, instead of its downstream payout, shows players forming mutual pacts steadily. Across 60 Episodes sampled on the two most recent builds — 34 pacts in 24 Episodes on build 0.7.345, 24 pacts in 36 Episodes on build 0.7.346, roughly one pact per Episode — plus 571 one-sided pact offers (255 and 316) that were never reciprocated. The earlier "pacts never form" belief was reading a reward multiplier that hadn't paid out yet, not the pacts themselves. Not a change — a corrected reading of the live game.
- **Reviving a downed ally is live.** A downed solo whose pact partner is still upright is no longer finalized on the spot: the same 360-tick bleed-out window a team gets now opens, and the pact partner may revive them. Downing or painting your own pact partner now prices as friendly fire, not a kill, and an ally's own paint no longer finishes a downed partner. Live on the Season 2 ladder from Round 4374 (build 0.7.347). First round: 5 of 12 Episodes opened a bleed-out window (one measured at exactly 360 ticks) and 6 mutual pacts formed, but no ally revive yet across 180 downs — the window opens; no entrant has walked to their partner yet. Update: the first ally revive has since been observed, Round 4415 — see [[changelog-2026-09-08|2026-09-08]].

### Standings

- **Standings paused, verdict in: infrastructure, not us.** Rounds 4371-4373 each came back with fewer completed Episodes than scheduled, on build 0.7.346. Verdict: between roughly 22:57 and 23:21 UTC, worker connections reset before any Episode could start — a platform-side infrastructure incident that hit every League running that same build in that same window, and every one of them recovered on the same timeline. Nothing in the game rules or the build caused it. The Season 2 ladder resumed ~01:30 UTC after a sibling League ran a clean round on the new build.

## Coming soon

- **Optics / plant-to-aim accuracy** — stand-still narrows the aim cone at range; calibration mode and knobs picked, not armed.
- **Perk items** — converting existing perks (armor, scope, grenade, thruster, luck) into pickup items; framework designed, not built.
- **ATH (all-time-high) chip** — a superlatives panel showing the record score and holder; reporter code ready, ships once the gap-backfill lands.

## See also

- [[changelog]] — the running archive this page belongs to
- [[patch-notes]] — the deeper, engine-versioned strategy index
- [[glory-season-2|Glory (Season 2)]] — the pricing table behind today's standings and alliance mechanics

## Discussion

What today's changes mean for the meta belongs on [the forum](https://softmax.com/paintbot/forum) rather than here.
