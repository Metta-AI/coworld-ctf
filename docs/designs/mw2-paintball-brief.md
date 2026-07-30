# Brief: design a PAINTBALL FIELD that plays like an MW2 map

Read this before authoring. It replaces the earlier "trace the minimap" brief,
which produced blocky wall soup and was rejected in review.

## What we are actually building

Not a floorplan tracing. A **genuine paintball field** — the kind a scenario
park would build — whose bunker layout reproduces the **function** of a Call of
Duty: Modern Warfare 2 map: the same lanes, the same chokepoints, the same
zones, the same fights.

Two things must both be true:

1. **It plays like the map.** Three routes with the same character (one tight
   flank, one contested mid, one exposed fast lane), chokepoints in the same
   relative places, the same signature fight (Rust = everyone funnels under the
   tower; Terminal = the security pinch and the plane).
2. **It reads like the map.** One or two hero set pieces make it nameable at a
   glance — the 747, the C-130, the derrick tower, the crane and helipad.

A player who knows MW2 should say "this is Terminal" *and* "this plays like
Terminal." A paintball player should say "this is a good field."

## The polarity rule (this was the top review failure)

Measured off the real reference plates: **~54% of an MW2 map is open playable
space; only ~28% is structure.** Fields are OPEN with cover placed in them.

- Target **18-30% wall coverage.** Above ~35% it stops being a field and
  becomes a maze.
- Author the **negative space first**: decide where players run, then place
  bunkers to shape those runs. Do not fill a region and carve holes.
- Every lane needs to be **60-110px wide** (the player is 13px). Chokepoints
  narrow to 30-45px — tight, never impassable.

## Paintball bunker vocabulary — USE ALL THE SHAPES

The engine has four primitives and the last three were barely used. Blocky
rectangles everywhere is exactly what got rejected.

```nim
ArenaShape(kind: shapeDisc, cx: X, cy: Y, radius: R)       # CAN / barrel / tank
ArenaShape(kind: shapeDiamond, cx: X, cy: Y, radius: R)    # DORITO (the classic)
ArenaShape(kind: shapeDiagonal, x0:_, y0:_, x1:_, y1:_, thickness: 12..20)
                        # BEAM / snake wall / wing / ramp. MUST be exactly 45°:
                        # |x1-x0| == |y1-y0|.
ArenaShape(kind: shapeRect, rect: MapRect(x:_, y:_, w:_, h:_))
ArenaShape(kind: shapeRect, window: true, rect: ...)       # GLASS: blocks paint
                        # and movement, transparent to fog — shopfronts, office
                        # curtain wall, terminal glazing. Use it; it is great.
```

Real speedball bunker types to lean on, by engine shape:
- **Dorito** (`shapeDiamond`, r 22-34) — the signature angled bunker. Use many.
- **Can / Tank** (`shapeDisc`, r 18-40) — round cover, fights wrap around it.
- **Snake** (a run of low `shapeDiagonal` + small rects) — a winding low line
  down one flank that players leapfrog along. Every good field has one.
- **Beam / Wedge** (`shapeDiagonal`, thickness 14-20) — angled walls that break
  sightlines diagonally instead of squarely. These do the most work visually.
- **Temple / Tombstone** (medium `shapeRect`, 40-90px) — solid anchors.
- **Bunker cluster** — 2-3 shapes of DIFFERENT kinds grouped, with a gap
  between them. Mixed clusters read far better than lone blocks.

**Rule of thumb: no more than half your shapes should be plain rectangles.**
Diamonds and diagonals are what make it look like a field instead of a floorplan.

## Required: annotate the function, then verify it

Before placing geometry, write the map's functional skeleton down, and put it in
your report:

- **ZONES** — named areas with a role: `RED_BASE`, `MID`, `NORTH_FLANK`,
  `TOWER`, `APRON`, `SHOPS`, ... For each: what happens there, roughly which
  rectangle of the board.
- **TRAVEL PATHS** — the routes from red pedestal (185, 329) to blue (1049,
  329). Give at least 3, each with its centerline waypoints and its character
  (tight/contested/exposed).
- **CHOKEPOINTS** — where paths pinch or cross. Give (x, y) and the intended
  gap width. These are where the fights happen; place them deliberately.
- **SIGHTLINES** — which long lines exist and what breaks them.

Then make the geometry realize that skeleton, and check it: walk each path on
the rendered mask and confirm it is open end-to-end at your stated width, and
that each chokepoint is actually as narrow as you claimed.

## The hero set piece

Each map gets one or two unmistakable scenario props, built from mixed shapes:
- **Terminal** — a 747 at the gate: fuselage, swept wings (`shapeDiagonal`),
  engine pods (`shapeDisc`), tail. Big: ~450px long.
- **Afghan** — the crashed C-130, broken-backed, wings + four engine discs.
- **Rust** — the derrick tower: four legs with diagonal bracing around an OPEN
  pad (the fight happens under it).
- **Highrise** — the crane (base + long jib) and the helipad ring.
- **Scrapyard** — a row of gutted airframes, staggered, not a wall.
- **Favela** — the dense stacked blocks themselves are the landmark; give it a
  strong alley grammar plus the open courtyard.

A hero prop is allowed to be visually elaborate — it is what makes the map
nameable. Build it from 8-20 mixed shapes, not one rectangle.

## Hard constraints (tested; a violation fails the suite)

Board **1235 x 659**, center (617, 329). Red pedestal (185, 329), blue (1049,
329), each in a 70px auto-cleared ring. Player footprint 13px.

1. Red pedestal must reach blue pedestal.
2. No horizontal row may run clear from x=215 to x=1020 (guns are map-wide).
3. No stranded floor — every standable cell reachable; any enclosure needs a door.
4. Pickup/spawn seats standable: near (50,60), (50,599), (1185,60), (1185,599);
   (617,220), (617,439); (50,164), (50,494), (1185,164), (1185,494).
5. Corridors and gaps >= 27px. Nothing off-map (0..1234, 0..658).
6. Wall coverage 18-30%.
7. **Asymmetric**: the layout is used verbatim (`fullObstacles`), and a test
   asserts >10% of comparable cells differ across the center line. Do not
   mirror. Fairness is asserted separately by area/cover/midfield parity, so
   keep the two halves comparable in AMOUNT of cover while differing in KIND.

## How to build and see it

Author into `tools/mw2_author.py`'s `LAYOUTS` (helpers: `room()` with doors,
`hbar`/`vbar` with gaps, `plane()`, `blocks()`) — but note those emit rects
only. For discs/diamonds/diagonals, emit the shape lines directly; see
`tools/mw2_shapes.py` if present, or extend the emitter.

    python3 tools/mw2_author.py <map>     # builds, repairs, verifies, emits
    python3 tools/mw2_integrate.py        # splices into src/ctf/sim.nim
    python3 tools/mw2_gallery_regen.py    # renders the gallery

Then **LOOK at the render** (`sips -Z 900 ... --out /tmp/x.jpg`, then Read it)
and judge it as both a fan and a paintball player. Iterate until it passes.

## Trenches — use them

`origin/main` added a terrain feature that is perfect for these fields, and
every map should place a few BY HAND (generated maps dig them procedurally;
ours are authored):

    result.trenches = @[
      MapRect(x: cx - 28, y: cy - 28, w: 56, h: 56),   # one 56x56 dug pit
      ...
    ]

A trench is a **56x56 walkable dug pit**. It is NOT a wall: it never blocks
movement, bullets, or vision. Its rules:

- **Fast in, slow out.** Dropping in and moving inside run at full speed, but
  moving AWAY from the pit center has speed and acceleration divided by 5.
  Easy to take, costly to abandon.
- **Occupants fire at 1/3 rate** (gun cooldown x3).
- **70% of gun shots that would hit an occupant fly over** — and carry on down
  the ray, so they can hit someone standing behind the pit. Shots between two
  players in the SAME trench are never ducked.
- Gun only: grenades and spray cones are unaffected. No concealment — fog
  visibility is normal.

So a trench is **cover you stand IN**: strong protection from ranged fire, at
the cost of your own rate of fire and your mobility. Design with that:

- Put one in the middle of an **exposed crossing** so the fast lane has a
  survivable waypoint (a foxhole halfway across the open).
- Put them at **chokepoints** you want contested slowly rather than sprinted.
- Put one or two **near a pedestal approach** so a defender has a holding spot
  that is hard to shoot but slow to leave — an interesting trade, not a
  free turret.
- Do NOT line a whole lane with them; they are punctuation, not paving.
- **3-8 per map** is the right budget. Place them in team-comparable positions
  (the fairness parity test still applies) without mirroring the layout.

Trench squares must sit on floor the player can actually reach, and they do not
count as cover for the coverage budget (they are walkable).
