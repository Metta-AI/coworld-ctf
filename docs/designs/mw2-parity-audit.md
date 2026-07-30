# Deep audit: making paintball-CTF play like CoD MW2

Everything is on the table — this is a new game built on the engine, not a mod
of the base arena. Each gap is tagged [engine] / [map-data] / [art] and marked
DONE where this branch already landed it.

## 1. Objective model

- DONE [engine] **Capture AT the flag stand** (`captureRadius`), not by
  crossing a full-height home-edge column. The column was the single most
  un-CoD mechanic in the game.
- DONE [engine] **Off-edge, off-centerline home points** (`redHome/blueHome`).
  Real MW2 flags sit inside the map's architecture, not on a side edge.
- DONE [engine] **Real spawn zones** (`redSpawn/blueSpawn` rects + seat grid).
- OPEN [engine] **Return-your-own-flag**: MW2 CTF auto-returns a dropped flag
  after a timer; carrier drop rules here differ. Worth matching the timer feel.
- OPEN [engine] **Score-limit round shape**: MW2 CTF plays capture-limit 3 /
  timed halves with side swap. The league plays one episode to time/wipe.
  A `captureLimit` config + halftime side swap would complete the mode.

## 2. Map geometry

- DONE [engine] Asymmetric layouts used verbatim (`fullObstacles`).
- DONE [engine] Narrow carve column (`carveClear`) so architecture reaches
  the spawns.
- DONE [map-data] Terminal rebuilt as a paintball field (mixed bunker
  vocabulary, hero 747, pillar-row concourse, glass shopfronts).
- OPEN [map-data] The other five need the Terminal treatment (epic task
  f8769f79): hero set piece, 3-lane grammar, chokepoints at the real spots,
  orientation matched to the reference plate (Terminal needed 180°).
- OPEN [engine, cheap] **Non-rect trenches / trench sizes**: MW2's "cover you
  stand in" spots (Afghan's wadi, Rust's pit) vary in size; `TrenchSize` is a
  single constant.

## 3. Movement & combat feel (the biggest remaining gap class)

- OPEN [engine] **Sprint**: MW2's rhythm is sprint-then-ADS. The sim has one
  move speed. A sprint (faster, gun-down, wider turn radius) would change
  lane-running and make the exposed fast lanes actually fast.
- OPEN [engine] **Mounted/head-glitch spots**: MW2 power positions are about
  shooting over cover. Trenches give "in" cover; low-wall "over" cover
  (blocks bullets only when the shooter is adjacent) would complete it.
- OPEN [engine] **Grenade bounce**: MW2 grenades bank off walls; ours fly
  over. Favela/Terminal interiors would play very differently.
- PARTIAL [map-data] **Sightline discipline**: the no-open-row invariant is
  enforced, but MW2 also has deliberate LONG lanes (Afghan's ridge line,
  Highrise balcony-to-balcony). The glass-window shape gives fog-transparent
  sight without a firing lane — use it deliberately for "sniper" lanes.

## 4. Presentation

- DONE [art] Per-map floor + wall materials, chroma-blended; distinct palette
  per map.
- DONE [engine/art] MAP banner chip + persistent label in the viewer.
- OPEN [art] **Designed architecture sprites** over the material layer
  (epic task 67a7c263): roof detail, parapets, the 747's actual livery,
  helipad H, runway/soccer markings. Blender top-down renders composited to
  the exact collision footprints (`blitCover` exists; the old failure was
  square sprites on non-square shapes — author sprites TO the shapes).
- OPEN [art] **Killcam-style capture replay / MW2 announcer flavor** in the
  broadcast shell ("Enemy has taken your flag" moments). All strings live in
  client/replay_broadcast.html.
- OPEN [art] **Map-specific lighting mood**: Rust noon-orange, Terminal
  interior-cool, Afghan dusk. The endzone tint pass already proves per-map
  color grading is possible.

## 5. Meta / league

- DONE [league] `mw2` rotation alias, seed-keyed per episode; resolved name
  recorded in the replay.
- OPEN [league] **Vote-skip flavor**: cosmetic next-map splash + skip tally in
  the lobby shell (authentic MW2 UX; low value until maps ship).
- OPEN [policy] The baseline bots hard-code default-arena coordinates: they
  stole but never capped on zoned Terminal. Fine for engine testing; any
  league run on the pack needs at least a bot that reads flag/zone positions
  from the sim (they are all in the wire protocol already).

## Priority order (play-feel per unit work)

1. Finish the five map rebuilds (map-data — the pack IS the product).
2. Sprint + over-cover (engine — MW2's feel lives here).
3. Designed architecture sprites (art — MW2's look lives here).
4. captureLimit + side swap (engine — completes the mode).
5. Grenade bounce, announcer moments, vote-skip splash.
