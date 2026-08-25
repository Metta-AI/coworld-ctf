# BR showmatch — real names, real policies, current mapgen

Recording: `br-showmatch.bitreplay` (root of this worktree, mirrored into
`static-replay-viewer/` for the hosted viewer, same convention as
`br-final-match.bitreplay`). Recorded via the new
`tools/record_br_showmatch.sh` — `record_br_match.sh`'s sibling, differing
only in that each of the 32 seats can run a DIFFERENT bot binary instead of
one binary for everyone — against a fresh draw from the current mapgen
(round 12 burrow requirement + round 13 all-items gradient, merged from
`origin/maxwell/br-mapgen` @ `3b7d74f`) and a roster of four real,
independently-built policies.

## Setup

- **Map**: fresh draw, `tools/brmapkit generate --seed 4242 --keystone
  zone-edge-holding`, `allPass=true` on the first draw (no hand-editing).
  3211×1713 (giant), 16 spawn groups, `gunRange` 331px (map-derived, same
  discipline as the final-match report: never config-overridden).
  `cover=123‰`, `masses=26`, `burrow: true` (round 12's connectivity gate),
  all four item types placed: `medkits=33 grenades=14 shields=7 sprays=36`.
  One informational metric (`interior conn`) reports 4/34 room centers
  outside the dominant walkable component — tracked by `brmapkit validate`
  but not one of the gates `allPass`/the tool's own final PASS/FAIL line
  requires; the draw is accepted as the tool defines "passing."
- **Items**: round 13 landed on `br-mapgen` after round 12, adding
  `shieldSpawns`/`spraySpawns` (neutral pools, same shape as the existing
  `medKitSpawns`) to the brmapkit draw's own JSON. The engine side had no
  ingest path for them at all before this lane: `CtfMap` had no
  `shieldSpawns`/`spraySpawns` fields, `tools/br_spec_to_ctf.nim` never
  forwarded them, and `resetShields`/`resetSprayPaints` (sim.nim) always
  used the per-team endzone formula, which a flagless BR board has no real
  endzone to anchor. Wired end to end this lane (`sim_types.nim`,
  `arena.nim`'s spec JSON (de)serialization, `br_spec_to_ctf.nim`,
  `resetShields`/`resetSprayPaints`) — same "map's own pool first, formula
  fallback" rule `resetMedKits` already used. Confirmed live in this
  recording: `yellow picked up a spray can` / `yellow sprayed paint` /
  `red picked up a spray can` all appear in the server log.
  **Grenades were NOT wired** — `CtfMap.grenadeSpawns` is a fixed
  `array[4, PickupSpawn]` everywhere it's touched (including the wire/replay
  format), not the `seq[MapPoint]` neutral-pool shape the other three item
  types share, so there is no ingest path for a drawn grenade pool without a
  real engine type change. Grenades still place via the classic 4-corner
  `grenadeSpawnPoints()` formula, same as before this lane. Flagged per the
  brief rather than attempted tonight.
- **Roster**: 32 seats, 16 duos, one life per seat, no respawns, the same
  five-phase closing zone as the final-match report
  (`z` 0.75→0.55→0.40→0.28→0.17, `dps` 0/2/4/8/12). Every seat runs a real,
  independently-built binary — no demo overrides, no scripted scaffolding —
  named honestly by what it actually is:

  | policy name | what it is | duos (00-15, both seats each) |
  |---|---|---|
  | `softmaxwell-br-integrate` | this branch's `players/baseline/baseline.nim` at the commit this showmatch was recorded from — `main` plus the BR-specific additions (ring safety, alive-readback, the hunt-override color-roster fix from this same lane) | 00, 04, 08, 12 |
  | `daveey-baseline` | `origin/main`'s `players/baseline/baseline.nim`, unmodified — the open-source league leader reference, built standalone in a throwaway worktree | 01, 05, 09, 13 |
  | `softmaxwell-picasso-v56` | `origin/maxwell/paintbot-v56` (`d6b2761`, "Picasso v56: awareness fixes") — a real, named, GameVersion-compatible (GV43) combat-tuning checkpoint from this repo's own history, built standalone | 02, 06, 10, 14 |
  | `softmaxwell-v59` | `maxwell/v59-integrate` @ `dd70503`, `players/baseline/baseline.nim`'s `shippedCombatTune()` proc (commit, aimLock, unstuckEngaged, dangerScore, twoSpeedScan, boundingOverwatch, pointOfDomination — the SHIPPED tune `runBot` actually plays, not `defaultCombatTune()`'s dev defaults) — the real deployed champion, built standalone, GV43 | 03, 07, 11, 15 |

  All four builds share this branch's GameVersion (43) and were verified to
  compile and connect cleanly. None of the three non-`br-integrate`
  policies know about BR's zone mechanic at all (ring safety / hunt
  override / alive-readback are additions this lane made on top of `main`,
  after `v59-integrate` and `paintbot-v56` branched) — they play combat and
  item pickups normally and are simply unaware of the shrinking rect beyond
  whatever general survival behavior they already have. **Skipped**: an
  exact "v58"/"v57" control-tune pair — `shippedCombatTune` does not exist
  on `main` or on this branch, only on `v59-integrate` and a handful of
  other `paintbot-vNN`/`picasso-*` branches; `v56` was the highest cleanly
  git-log-able "Picasso vNN" checkpoint found in the time available, used
  in its place rather than guess at an unverifiable "v58" label.
- **Seed**: map draw seed 4242; match/sim seed 90210 (`tools/record_br_showmatch.sh
  br-showmatch.bitreplay br-match-showmatch-4242.json 90210 /tmp/br-showmatch/roster.json`).

## What happened

**Winner: `orange` (duo10, `softmaxwell-picasso-v56`)** — survived to the
end with **zero shots fired the entire match** (`slot_shots_fired[10]` and
`[26]` are both 0 in the recorded summary). This is a pure-survival,
zone-timing win, not a combat win — the same flavor of outcome the
final-match report already found ("the zone did the eliminating").

**Elimination order** (tick both of a duo's seats were dead):

| tick | duo (callsign) | policy |
|---|---|---|
| 1279 | `blue` | `daveey-baseline` |
| 1279 | `umber` | `softmaxwell-br-integrate` |
| 1286 | `black` | `softmaxwell-br-integrate` |
| 1366 | `yellow` | `softmaxwell-v59` |
| 1803 | `lime` | `softmaxwell-br-integrate` |
| 1820 | `navy` | `daveey-baseline` |
| 1830 | `silver` | `daveey-baseline` |
| 1893 | `green` | `softmaxwell-picasso-v56` |
| 1924 | `azure` | `softmaxwell-picasso-v56` |
| 2013 | `pink` | `softmaxwell-v59` |
| 2062 | `plum` | `softmaxwell-v59` |
| 2118 | `rust` | `daveey-baseline` |
| 2647 | `peach` | `softmaxwell-v59` |
| 2668 | `ivory` | `softmaxwell-picasso-v56` |
| 3474 | `red` (final tick) | `softmaxwell-br-integrate` |
| — | `orange` (winner, never eliminated) | `softmaxwell-picasso-v56` |

Early combat (ticks ~800-2100) was concentrated among `red`/`blue`/`green`/
`yellow` — duos 00-03, which by construction already cover all four
policies once each (`softmaxwell-br-integrate` vs `daveey-baseline` vs
`softmaxwell-picasso-v56` vs `softmaxwell-v59`), so the shots that were
fired were real cross-policy fights, not a repeat of the "only the same 4
colors ever fight" defect this lane's other commit fixed — that defect was
in the ENEMY-PERCEPTION color list, not the color-slot assignment, and is
independent of which four colors happen to be in slots 0-3 on a given
seating.

**The endgame closed, not stalled.** From tick 2668 (`ivory` eliminated) to
3474 (match end), exactly two teams were alive: `red`
(`softmaxwell-br-integrate`, one seat already dead, one seat — slot 0 —
alive) and `orange` (`softmaxwell-picasso-v56`, both seats alive, slot 10
active). Position trace (`tools/extract_events --frames`) over that entire
806-tick stretch shows `red`'s surviving seat moving **continuously and
monotonically toward `orange`** — from `(1410, 934)` at tick 2680 to
`(1762, 934)` at tick 3440, versus `orange`'s own slow drift from `(1764,
934)` to `(1789, 934)` over the same window — both holding the same y-row
the whole time while `red` closes the x-gap from ~354px down to under 30px.
`red`'s last seat died to **zone** damage at `(1765, 934)` at tick 3474 —
essentially on top of where `orange` was standing — not to combat, but
after an unambiguous, sustained chase, not a freeze. This is independent,
second confirmation of the hunt-override fix (the dedicated verification
in that commit used a different map/seed/roster entirely): `red` is one of
the four TeamColorNames-primary colors, `orange` is not, and the finale
still closed.

## Where things are

- Report: `/private/tmp/br-integrate/BR_SHOWMATCH_REPORT.md` (this file).
- Recording: `/private/tmp/br-integrate/br-showmatch.bitreplay`, mirrored
  at `/private/tmp/br-integrate/static-replay-viewer/br-showmatch.bitreplay`
  for the hosted viewer at
  `http://127.0.0.1:21404/index.html?replay=br-showmatch.bitreplay`.
  `br-final-match.bitreplay` stays alongside it, unchanged and still
  reachable at its own `?replay=` URL.
- Map draw: `/tmp/br-showmatch/draw-4242.json` (brmapkit's own grammar,
  ephemeral scratch, not tracked — matches the round-9 draw's own
  precedent); converted spec tracked at `br-match-showmatch-4242.json`.
- Roster: `/tmp/br-showmatch/roster.json` (ephemeral scratch — the four
  binaries it points at live under `/tmp/bots/`, also not tracked; anyone
  re-running this needs to rebuild them from the branches/commits named in
  the roster table above).
- New tool: `tools/record_br_showmatch.sh` (tracked) — `record_br_match.sh`'s
  mixed-roster sibling, taking a `roster.json` of `{slot, bin, name}` instead
  of always launching `players/baseline/baseline.out`.
