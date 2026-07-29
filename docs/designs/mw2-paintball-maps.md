# MW2 Paintball Map Pack — design brief

Recreations of six crowd-favorite Call of Duty: Modern Warfare 2 (2009)
multiplayer maps as top-down paintball CTF arenas, plus per-episode map
rotation. Everything is re-themed paintball: buildings become plywood/inflatable
bunkers, wrecks become scenario-field set pieces; the game itself is unchanged.

## Grid conventions

Designs are authored on a normalized 100x53 grid (matches the default arena's
1235x659 aspect; scale by ~12.35x per unit). Long axis horizontal, y-center
26.5. Flag rings at (15, 26.5) and (85, 26.5). Layouts are LEFT-HALF
(x 0..50) + optional center-straddling shapes; the engine mirrors leftObstacles
across the vertical center line for team fairness. Every map keeps the same
3-lane grammar: north lane y~5-13, mid lane y~21-32, south lane y~40-48.
Corridors must stay >= 26px (>= ~2.2 grid units) for the 13px player footprint.
Protected floor (flag ring, spawn pockets, capture columns) is carved out of
any shape automatically.

## The six maps

Picked for icon status + top-down survivability: Rust, Terminal, Highrise are
the franchise's three most re-released maps; Afghan, Scrapyard, Favela all got
official remakes. Cut: Skidrow (identity is interior corridors — reads as grey
boxes top-down), Estate (identity is an asymmetric hillside assault; forcing
symmetry destroys it).

### 1. Rust — rusty oil-yard speedball field
Landmark: the central derrick tower (scaffold paint-bunker) DEAD CENTER,
horizontal pipe run, big round fuel tank, scattered barrels.
- Shack rect (8..16, 6..12); big tank disc (12,42) r5
- Pipe run thin rect (20..40, 31..33), gap at x 29..31
- Container rect (34..42, 5..9); dumpster rect (36..41, 44..47)
- Barrel discs r1.5: (24,12), (27,15), (33,40), (43,36)
- Ramp diagonal (41,18)->(46,23)
- CENTER: tower rect (46..54, 22..31) + corner barrel discs r1.5 (44,20),(44,33)
Lanes: N shack->container gap->tower north face; MID straight at the tower
(the single hard choke); S tank->pipe gap->dumpster.

### 2. Terminal — airport-concourse field, inflatable 747
Landmark: the 747 center-north (it IS the north lane), security-scanner comb
mid, Burger Town + luggage carts south.
- Lounge seating thin rects (8..18, 14..16), (8..18, 37..39)
- Burger Town rect (18..28, 38..46); duty-free island rect (24..32, 16..22)
- Pillar discs r1: (22,26), (30,31)
- Scanner comb rects (34..36, 22..24), (34..36, 25..27), (34..36, 28..30)
- Luggage carts rects (38..41, 43..45), (43..46, 40..42)
- Jet-bridge diagonal (38,14)->(44,9)
- CENTER: fuselage rect (40..60, 6..13), door gaps x 44..46 (+mirror);
  wing diagonal (46,13)->(39,20); engine disc (43,17) r2
Lanes: N through the fuselage doors; MID scanner comb grind; S open tarmac
past Burger Town (sniper lane).

### 3. Highrise — rooftop speedball court
Landmark: twin office cores (one per half — literally the real map), helipad
disc center-south, crane center-north, duct trench mid.
- Office core rect (2..12, 14..39) with exit gaps at y 17..20, 25..28, 34..37
- AC units rects (18..22, 10..13), (22..26, 40..43)
- Duct trench thin rect (26..38, 25..28), gap x 31..33
- Crates rects (30..33, 7..10), (33..36, 44..47)
- Scaffold diagonal (40,17)->(45,12)
- CENTER: helipad disc (50,44) r7; crane base rect (48..52, 2..7) + arm rect
  (48..52, 7..14)
Lanes: N crane-base squeeze; MID duct-trench gap; S across the open helipad
(high-risk flag route).

### 4. Favela — shantytown streetball village
Landmark: dense staggered pastel shanty blocks, water tanks, and the EMPTY
dirt soccer courtyard at center (negative space as landmark).
- Flag plaza open (10..20, 21..32); market stalls rects (18..21, 15..17),
  (18..21, 36..38)
- Blocks: A (4..14, 4..12), B (18..27, 6..14), C (29..37, 8..17),
  D (6..16, 40..48), E (20..30, 38..46), F (32..40, 31..39)
- Alleys 3-4 units wide, staggered (never straight >15 units)
- Water tank discs r1.5: (23,10), (34,35), (11,44)
- Stair-alley diagonal (38,23)->(43,18)
- CENTER: courtyard (43..57, 19..34) kept EMPTY; scaffold rect (46..54, 4..10);
  kiosk rect (47..53, 42..46)
Lanes: N alley seam A/B/C->scaffold; MID plaza->alley mouths->courtyard sprint;
S gully D->E->F->kiosk.

### 5. Afghan — desert crash-site scenario field
Landmark: the crashed C-130 dead center, ridge wall with cave mouth north,
burnt tank, sandbag diagonals.
- Bunker rect (4..12, 21..32), mouth facing center
- Ridge rects (0..14, 0..5), (18..42, 0..5); cave mouth gap x 14..18
- Rock discs (22,14) r2.5, (30,35) r3, (26,45) r2
- Burnt tank rect (32..38, 20..23)
- Sandbag diagonals (20,30)->(24,34), (36,38)->(40,42)
- CENTER: fuselage rect (43..57, 22..31), entry gaps x 45..47 (+mirror);
  tail rect (38..44, 32..36); wing diagonal (44,22)->(37,15) + engine disc
  (40,18) r2
Lanes: N cave lane along the ridge; MID bunker->tank->fuselage doors;
S riverbed (open sand, rock/sandbag hops).

### 6. Scrapyard — aircraft-boneyard speedball field
Landmark: the gutted fuselage row down the midline (one per half + one center
= a broken spine), brick office/warehouse, engine stacks.
- Office rect (4..12, 7..17); warehouse rect (4..12, 36..46)
- Fuselage rect (24..36, 24..29) + nose disc (22, 26.5) r2.5, body gap x 29..31
- Engine stack discs (19,8) r2, (38,45) r2
- Crates rects (30..33, 9..12), (33..36, 39..42)
- Wing diagonal (36,22)->(41,17)
- Scrap-wall dressing thin rects (16..30, 0..2), (20..34, 51..53)
- CENTER: fuselage rect (44..56, 24..29), gaps x 48..50 (+mirror), tail-fin
  diamond (50,31) r~3
Lanes: N street office->crates->engine stack; MID threading three consecutive
fuselage-gap micro-chokes; S street warehouse->crates->engine stack.

## Rotation / vote UX (authentic MW2 flavor)

MW2 (2009) had NO pick-between-two vote (that was Black Ops 1). It ran a fixed
playlist rotation; the lobby showed the next map's name + splash with the
countdown, and players could Vote Skip (majority skips to the next map in
rotation; can't skip twice in a row). Adaptation here: per-episode rotation
through the pack, with the map name announced on the pre-game/intro banner
("MAP: RUST" splash flavor) in the replay viewer.

## League wiring

Decision: **rotation, not agent-voting.** The league runs the pack via a
rotation alias — mapPath `"mw2"`, resolved by the server at startup to
`Mw2Rotation[abs(seed) mod 6]`. Each league episode is a fresh process with a
distinct seed, so the alias rotates per episode; the replay header records the
resolved concrete map, never the alias. Exposed as the `mw2-rotation` manifest
variant (identical 8v8 rules, `"mapPath": "mw2"`).

Why not let agents vote on the map:

- **Bloc voting degenerates.** 8v8 head-to-head means 8 copies of each policy
  per side: any per-agent vote collapses into a 2-party bloc and every
  contested vote is an 8-8 tie needing an arbitrary tiebreak — the "vote" is
  theater.
- **Protocol break.** A vote phase needs new inputs/observations, i.e. a
  protocol/GameVersion break that invalidates every existing league policy for
  a feature with no gameplay depth.
- **Determinism.** Seed-keyed resolution keeps episodes fully deterministic
  and replay re-simulation exact — the map is a pure function of the recorded
  config.
- **Authenticity.** MW2 (2009) itself ran playlist rotation with a majority
  Vote Skip; pick-between-maps voting was Black Ops 1. Rotation IS the
  authentic flavor.
- **No platform changes.** Strict one-map-per-round cycling would need a
  platform-provided episode index; seed-keying gives the same long-run
  coverage distribution (seeds are effectively uniform mod 6) with zero
  platform changes.

Optional future spectacle: a cosmetic viewer-side **"Vote Skip" splash** on
the pre-game banner (announce the rotation's next map, flash a mock skip
tally) — pure replay-viewer theater, no protocol surface.
