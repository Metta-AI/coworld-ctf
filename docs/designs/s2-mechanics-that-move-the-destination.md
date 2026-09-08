# Season 2 mechanics that changed where a cog should go

Input material for the open **"give plays spatial knowledge of the map"** design.

Season 2 moved the destination a cog should walk to, and did it five times. The
play layer did not move with it. This doc is the inventory: one row per mechanic,
each stating what changed, what a play must now decide that it could not decide
before, and which field or engine call would answer it.

It changes no gameplay and no engine code. Everything here is read off
`origin/main` at `52103b10`, with the armed values read from the
`battle-royale-s2` variant in `coworld_manifest_paintbot.json` — the one variant
the S2 ladder dispatches.

## How to read this

- **Shipped** means the code is on `main` *and* the `battle-royale-s2` variant
  arms it. Every S2 gate defaults to `false` in `sim_config.nim`, so "on main" and
  "on in live play" are two different claims and are kept separate below.
- **Proposed** means not on `main`. One row is proposed; it is marked inline.
- Every quoted number carries its sample size and whether it is a **ceiling** or a
  **field measurement**. Two of the numbers below have already been misread once
  on this project, which is why the distinction is in the table rather than a
  footnote.

## What a play can see today

The whole of a play's world arrives through `BodyTickInputs`
(`src/shell/body.nim:258`):

```
self  visibleTracks  partner  sightedItems  killFeed  aggressorEvents  shouts  hazards
```

Plus the zone, which reaches the play as `SdkZone` (`play_sdk/play.nim:85-91`):
`phase`, `current` rect, `next` rect, `ticksToShrink`.

There is **no terrain field, no paint sample, no reachability query, and no map
geometry of any kind** in that list. Every row below is a consequence of that one
gap. `sightedItems` is the only spatial channel, and it is fog-gated — a play
learns a crate exists only once the crate is already inside its own field of view
(`src/ctf/server.nim:3766`, `3793`).

---

## The five mechanics

### 1. Zone is lethal ground — **shipped, armed**

| | |
|---|---|
| **What changed** | `updateZone` (`src/ctf/sim.nim:5981`) applies the active phase's `dps` to any seat whose center has stood outside the zone for a full second (`ZoneDamageRollTicks = TargetFps = 24`, `src/ctf/sim_types.nim:1030`) — an authored rate, no RNG roll. Under `zoneDamageByPaint` (`src/ctf/sim_config.nim:150`, default `false`; **`true` in `battle-royale-s2`**) the membership verdict stops being rect geometry and becomes the painted arrival field (`src/ctf/sim.nim:6015-6019`, `src/ctf/zone_field.nim`). Wall and off-grid cells keep the rect verdict, so no pixel reads as immortal ground. `zoneBlocksRevive` (also armed) makes painted ground un-rescuable. |
| **Decision it forces** | A route is no longer scored by length. A path crossing paint is not a slower path, it is a fatal one, and the play must price a candidate destination by *how much painted ground the route eats* — at 3→20 dps across the six armed phases, several seconds of paint is the whole health bar. |
| **The trap** | The rect a play receives is **no longer the surface that kills it**. `SdkZone.current` is rect geometry; the lethal verdict under the armed variant is the paint field. A play that treats "inside the rect" as "safe" is reading a boundary the engine stopped using. |
| **Field that would answer it** | None exists. The engine already computes the exact predicate — `sim.zonePaintedForDamageAt(px, py, tick)` (`src/ctf/sim.nim:6016`), the same surface the viewer draws. A point-sample or a segment-sample along a proposed route is the minimum viable grant. |
| **Number** | **78.8% of downs (1356 / 1721) are zone/environmental** (`source=-1`), not player-caused. **FIELD MEASUREMENT**: N=114 real hosted episodes, sampled from 6 rounds (3774, 3785, 3795, 3798, 3812, 3827) inside the clean window 3774–3827, builds 0.7.307/0.7.308, all dispatching `battle-royale-s2`. Source: `~/.ctf/handoff/2026-09-03-sectionB-live-first-cut.md`. |

The zone schedule armed in `battle-royale-s2` is six phases, `z` 0.75 → 0.001,
`dps` 0 → 20.

### 2. Loot start — **shipped, armed**

| | |
|---|---|
| **What changed** | `lootStart` (`src/ctf/sim_config.nim:108`, default `false`, requires `brMode` at `:1127-1128`; **`true` in `battle-royale-s2`**) spawns every seat with `hasGun` and `hasHopper` false (`src/ctf/sim.nim:1835-1836`). `canFire` then requires **both** looted halves — the marker *and* the hopper that is its ammo (`src/ctf/sim.nim:3079`). |
| **Decision it forces** | The opening destination is a crate rather than a lane, and it is **two** crates, not one. A play must sequence two pickups of different families before it has a weapon at all, and decide which half to chase first when it can see only one. |
| **Field that would answer it** | `sightedItems` only, and only inside fog. Crate positions are not authored on the live maps — `resetLootCrates` falls back to the grenade and med-kit point pools, so crate sites are a derivable function of map furniture the play also cannot see. |
| **Number** | **91.8% of seats (1058 / 1152) never held both a gun and a hopper for an entire episode**; of the 8.2% that armed, median time-to-armed was tick 1024 (~43s of a ~150s median match). **CEILING, NOT A FIELD ESTIMATE**: local matrix row 3, n=36 clean episodes under pinned baseline `3c5228c3`, run with stock baseline bots that have no loot-seeking behaviour, and where crates were never exhausted (133 gun / 304 hopper pickups against 13–29 and 29–49 crate-equivalents available per map). The source doc's own recommendation is explicit: *do not tune loot density or the zone schedule off this number* without re-running against a loot-seeking bot. Source: `~/.ctf/handoff/2026-09-01-loot-matrix-results.md` (Row 3). |

Read the two numbers together and the shape of the problem is the whole reason
this design exists: the ceiling says cogs do not find crates, and the field says
the zone collects them while they fail to.

### 3. Ground items — **shipped for the fixed families; the perk-pickup grant is PROPOSED**

| | |
|---|---|
| **What changed** | Map control became the source of advantage. `server.nim:3764-3805` builds `sightedItems` from every fixed pickup family — grenade, med-kit, shield, spray, barrier, and the loot-start gun and hopper crates — plus live ground drops, each gated by `sim.fovVisibleAt`. Sightings carry `present`, so "seen empty" is a fact a play can keep and stop chasing a kit someone else took. `hopperSiteTrafficPermille` (armed at **750**) re-sites three quarters of the fallback hopper crates off the med-kit *retreat* points onto the grenade *traffic* points, because hoppers were the most plentiful crate and the worst collected at 0.47× the marker's per-crate pickup rate (measured over 75 live episodes). |
| **Decision it forces** | Which pickup is worth a detour, given its position, its family, and whether the route to it is survivable — a question about the map, asked by something that cannot see the map. |
| **Field that would answer it** | `sightedItems` (`src/shell/body.nim:266`), which is the only spatial channel a play has and is strictly fog-limited. Bandages are deliberately **not** sighted at all (`src/ctf/server.nim:3787-3791`), so 12 armed `bandagePickups` are invisible to plays by design. |
| **Proposed, not shipped** | The generic perk-pickup grant system is **not on main** — `git grep -n 'perkPickups' -- src/` returns nothing at `52103b10`. It is in flight. Any design that assumes it must say so. If that grep starts returning hits, this row needs rewriting from proposed to shipped. |

### 4. Drop and handoff — **shipped, armed, and wired end to end**

| | |
|---|---|
| **What changed** | `giveItem` (`src/ctf/sim_config.nim:116`, requires `brMode` at `:1139-1140`; **armed**) adds a declared handoff channel. `declareHandoff` (`src/ctf/sim.nim:7679`) records consent — proximity never implies it, so there is no auto-share path — and `updateGiveChannel` (`src/ctf/sim.nim:7714`) advances only while giver and partner both hold station inside `GiveItemRange` (40px centre-to-centre) for `GiveChannelTicks` (48 ticks = 2s), resetting the tick anything breaks. Transferable items are `gun`, `hopper`, `bandage`. Separately, `dropItem` (`src/ctf/sim_config.nim:121`, **armed**) spills a carried item to the ground on a `DropChordTicks` (10-tick) button chord, as an **open steal** with no team gate. |
| **Decision it forces** | Pair completion should route **through the partner**, not through seek-the-missing-half pathing. If the partner holds the hopper you lack, the destination is the partner — a moving point 40px wide — not a crate. This is the one S2 destination that is not a map location at all. |
| **Field that would answer it** | This one is **already answered**, and it is the exception worth noticing. `PartnerSample.hasGun` / `.hasHopper` (`src/shell/body.nim:241-242`), gated by `frameLoadoutFlags` (**armed**), give a play the partner's exact loadout gap alongside their position. A play can therefore see both the crate and the partner's gap — enough to know a handoff would help. Enemy held-state is never granted anywhere. |
| **Correction to a stale comment** | The docstring at `src/ctf/sim.nim:7691` says *"NOTHING in the engine calls it yet."* That is **out of date**. `src/ctf/server.nim:5237` calls `sim.declareHandoff` off the standing order's lifted `handoff` intent, and `src/ctf/replays.nim:889` calls it on playback. The play → shell → server → sim path is complete: `play_sdk/play.nim:2080-2111` emits the intent, `src/shell/emit_validator.nim:235-244` validates it, `src/shell/episode.nim:1306` lifts it. Do not design against the comment. |

### 5. Spawn-area weapon seeding — **shipped, armed**

| | |
|---|---|
| **What changed** | `seedSpawnLoot` (`src/ctf/sim.nim:1368`) appends `lootSpawnSeedGuns` and `lootSpawnSeedHoppers` crates around **each duo spawn cluster's anchor** at episode init, within `lootSpawnSeedRadius`, via the `nearestWalkable` expanding-ring guarantee so a seeded crate can never land in a wall or an unreachable pocket. Armed values: **3 guns, 3 hoppers, radius 48**. Additive — the map's base pool is untouched. The two families are phase-shifted 4 of 8 ring directions apart so gun and hopper never stack on one pixel. It is the owner's fix for the unarmed-cog problem: rather than teach every playbook to path to a crate, put a crate where a cog's first few steps in any direction already land. |
| **Decision it forces** | The opening destination is not where it was. Before seeding, the nearest crate was wherever the map's grenade/med-kit fallback put it; now six crates sit within 48px of home, and the correct opening move is a short local sweep rather than a march. A play still running a pre-S2 opening walks *away* from its own weapon. |
| **Field that would answer it** | Still only fog-gated `sightedItems` — but this is the cheapest row to close, and worth calling out to the spatial-knowledge design. Seeded placement is **RNG-free and fully deterministic**: a pure function of `homeX`/`homeY` (themselves a pure function of the seed) plus the radius and the ring rule. Re-simulating a seed always seeds the same crates at the same pixels. A play given only its own spawn anchor and the seed radius could *derive* all six seeded crate positions without any map knowledge whatsoever. |

---

## What this asks of the spatial-knowledge design

Ranked by how much of the S2 damage each would repair:

1. **A paint / damage sample.** Row 1 is unanswerable without it, and row 1 is
   where 78.8% of downs come from. The predicate already exists in the engine
   (`zonePaintedForDamageAt`); the gap is purely that it is not exposed. A
   segment-sample along a proposed route is worth more than a point-sample,
   because the decision being made is about a path, not a position.
2. **Spawn-anchor + seed-radius exposure.** Row 5 for nearly free — deterministic,
   derivable, no map data crosses the trust boundary.
3. **Item knowledge beyond fog.** Rows 2 and 3 both bottom out in "a play cannot
   route to a crate it has never seen." Whether that is remembered sightings,
   crate-site classes, or something else is the design's call, but the fog gate
   is the binding constraint.

Two things that do **not** need solving here: partner-gap perception is already
granted (row 4), and the perk-pickup system is not on main to design against
(row 3).

## Provenance of every number quoted

| Number | Kind | Sample | Source |
|---|---|---|---|
| 78.8% of downs environmental (1356/1721) | **field measurement** | 114 hosted episodes, 6 rounds in window 3774–3827, builds 0.7.307/0.7.308 | `~/.ctf/handoff/2026-09-03-sectionB-live-first-cut.md` |
| 91.8% never armed (1058/1152 seats) | **ceiling** — stock non-looting bots, crates never exhausted | 36 clean local episodes, matrix row 3, baseline `3c5228c3` | `~/.ctf/handoff/2026-09-01-loot-matrix-results.md` |
| time-to-armed p50 = 1024 ticks | **ceiling**, armed minority only (8.2% of seats) | same 36 episodes | same |
| hopper pickup rate 0.47× marker | field measurement | 75 live episodes | `coworld_manifest_paintbot.json`, `hopperSiteTrafficPermille` |

## Verification

Run from the repo root on a checkout of `main`:

```sh
git grep -n 'gloryMultiplierRecut' -- src/ctf/glory.nim src/ctf/sim.nim src/ctf/sim_config.nim
git grep -n 'giveItem' -- src/ctf/sim.nim src/ctf/broadcast.nim src/ctf/replays.nim
git grep -n 'perkPickups' -- src/          # must return NOTHING while row 3 says "proposed"
nim c -r -d:release tests/tests.nim
```

On a machine without the Wasmtime toolchain the test command needs the shape
`AGENTS.md` documents for the runtime-linked build — `tools/runtime_spike/fetch_deps.sh`,
then `-d:noSignalHandler --threads:on` alongside `-d:release`.
