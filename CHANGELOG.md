# Coworld CTF — patch notes

Player-facing changes: what actually plays differently, and the bugs fixed.

The authoritative wire-format log is the `GameVersion` doc block in
`src/ctf/sim_types.nim` — it records what breaks compatibility and why. This file
is the readable companion: what a player or a policy author would notice.

Newest first.

---

## GV38 — Weapon reach is pinned to the gun, not to the board

### ⚠️ IMPORTANT BUG FIX — the grenade out-ranged the gun on large boards

`GrenadeMaxRange` and `ShoutRange` were both `MapWidth div 5`, so they **grew with
the field**, while `GunRange` has been frozen at 1050 px since GV34. On a colossal
board the grenade therefore nominally **out-ranged the gun — 1284 px vs 1050 px**.
A thrown explosive reaching further than a hitscan rifle was never intended, and it
got worse the bigger the map got.

Both are now `GunRange div 4` = **262 px on every size class.**

| class | grenade & shout before | after |
|---|---|---|
| small | 210 | 262 |
| standard | 247 | **262** (+6%) |
| large | 321 | 262 (−18%) |
| huge | 444 | 262 (−41%) |
| giant | 642 | 262 (−59%) |
| **colossal** | **1284 — longer than the gun** | 262 (−80%) |

Small, standard and large play essentially as they always did (standard moves 6%).
Huge, giant and colossal lose board-scaled reach they were never meant to have.

**Why fixed reach is the point.** The frozen gun range is what gives each size class
its own *visibility regime*. One unoccluded vision cone covers 4.4x the small board,
3.2x standard, but only 0.12x colossal — so a big map is supposed to be a
navigation problem, not the standard map photocopied. Anything that scales with the
board erases that distinction and makes every class play the same.

### ⚠️ SECOND BUG FIX — the same size class shipped three different weapons

Because reach was derived from board *width*, the same nominal size class handed out
different weapons depending on team count:

- 2-team standard (1235 px board) → 247 px grenade
- 4-team square standard (960 px) → **192 px**
- 6-team hex standard (969 px) → **193 px**

All three are now 262 px.

### Compatibility

A grenade's target coordinates are hashed simulation state, so **pre-GV38 replays do
not re-simulate** and are rejected on load rather than silently mis-played. All
recorded fixtures were re-recorded.

### Known follow-up for policy authors

Bots that hard-code a throw distance and back-solve charge ticks from it are now
miscalibrated — they will plan a shorter throw than the sim allows and land long at
full charge. `players/baseline/baseline.nim` has been updated; any policy forked from
it before GV38 needs the same one-line change.

Known gap: `config.gunRange` overrides do **not** reach the grenade or the shout
(they pin to the compile-time `GunRange`), while `visionRange` does follow live
config. A league that shortens the gun gets a shorter cone but the same 262 px
grenade.

---

## GV37 — Vector (polygon) obstacles

Map obstacles and trenches may be `polygon` shapes (integer vertex rings), so curved
and organic terrain is authorable rather than being approximated with rectangles and
diamonds. Older viewers cannot parse the new spec kind.

---

## Map generator — measured defects (not yet fixed; recorded so they are not lost)

A 300-seed audit (`tools/mapgen_defect_probe.nim`, `tools/mapgen_defect_render.nim`)
measured features that are *placed but never validated to function*. These are real,
reproducible, and currently shipping:

- **Glass is placed blind.** Windows are chosen by shuffling column obstacles and
  flipping the first few — nothing checks that anything is visible through the pane.
  Only **27.8%** of generated 2-team windows are useful (≥200 px of clear sight on
  both sides) against **71.4%** on the hand-authored arena. **87%** of maps carry at
  least one dead, inert or decorative pane; **41.7%** have no useful window at all.
- **The column lattice is too tight for glass to work.** Adjacent columns sit
  51–76 px apart on a standard board, so a sightline hits the next picket almost
  immediately. Even a perfect window-picker could not reach the control on
  small/standard boards — there are only 2.0–2.4 usable spots against a draw of 2–4.
- **The centre feature is silently deleted on giant boards.** The centre offset is a
  hard-coded 138 px while the flag ring *is* scaled (182 px on giant), so the whole
  feature lands inside protected floor and is erased: **100% of giant centre panes
  are dead.** Combined with the "ring" draw, **52% of 2-team maps have no centre
  architecture at all.**
- **Sightline-repair plugs are a large share of the map.** The repair pass drops
  diamonds until no open row survives; those plugs are **14–16% of interior wall
  pixels** on a standard board at the median (up to 41%), and **26.8% median / 50%
  at p90** on 4-team maps. The hand-authored arena needs zero.
- **Grenade spawns are never checked.** Unlike every other pickup family (whose nudge
  distances measure 0 px), grenade spawns use fixed corner insets: **5.0% land inside
  stone and 15.5% are unreachable on 4-team maps.**

---

## Map generation — best-of-K selection

The generator previously shipped the **first** map that passed validation. With a
96% first-attempt pass rate on 2-team boards, that validator was selecting nothing —
every map was a coin flip from the generator's own quality range.

It now generates several candidates, scores each against a calibrated static rubric,
and ships the best. Measured over 150 held-out seeds: median quality score
**0.840 → 0.901**, with **123 seeds improved, 27 unchanged, 0 regressed**. Every
non-degenerate structural metric moved toward the hand-authored arena, none away.

Also fixed: a rejected seed used to re-roll into a **different size class** (the
retry walked `seed + 1`, and the first random draw was the board size), so
"map 1002" was not "map 1002 fixed up" — it was map 1003, possibly a different size
of board entirely.
