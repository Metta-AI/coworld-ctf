# Rust layout v2 — measured rebuild plan

Status: layout plan for the integrating session. Supersedes the current
in-game `rustCtfMap()` (1235x659). The old map kept the derrick idea but
squashed the square yard 1.9x into the landscape field and improvised most
footprints; this plan rebuilds every structure from the official minimap at
uniform scale.

Provenance: every number below is MEASURED from the official 2009 minimap
(`docs/designs/mw2-reference/rust.png`, 512x512). The playable frame is the
walled derrick yard — PLATES fractions (0.275, 0.225, 0.845, 0.795), origin
(140, 115), 292x292 px, **rot = 0** (no plate rotation). The frame crop was
percentile-stretched, thresholded (T = 185), component-labelled and read off
at ref-pixel precision. The transform from frame pixels (rx, ry) to THIS
canvas is:

```
canvas.x = 3*rx + 147
canvas.y = 3*ry + 73
```

(3.0 = chosen scale; +147/+73 place the measured derrick-complex center,
ref (124.5, 137.5), on the engine's forced center `(width/2, height/2)` =
(520, 486) — see section 1 for why that is load-bearing.) Items marked
[CHOICE] are creative decisions where the reference is ambiguous; [ADJ] are
deliberate small departures from the measured footprint (to clear an engine
carve zone, to reach playable width, or to satisfy a map invariant).

**Raster masks are the authoritative geometry** (Afghan lesson: re-traced
polygons fragment). Canvas-scale single-channel PNGs, wall = white:

- `docs/designs/mw2-reference/rust-v2-masks/terrain.png` — dune band + yard
  perimeter (343,902 white px)
- `docs/designs/mw2-reference/rust-v2-masks/structures.png` — all interior
  structures, doors pre-carved (70,087 white px)

OR them together for the wall layer. The tables below are the same shape
list in Nim-transcribable form, plus everything masks cannot carry (homes,
spawns, trenches, medkits, props).

---

## 1. CANVAS

**`width = 1040, height = 972`** [CHOICE]

- Real Rust's playable frame is a 292x292 square — the smallest map in the
  pack by far. Scale **3.0 canvas px per ref px** matches the linear scale
  chosen for Afghan (and the ~2.84 of the landscape plates), so structure
  footprints and engagement ranges feel like the rest of the pack while the
  map stays genuinely tiny (yard interior 801x831 vs Afghan's 1460x1400).
- **The canvas is centered on the derrick, not the yard.** The engine
  force-carves the flag ring r70 at `(width/2, height/2)`, and on Rust the
  hero structure — THE TOWER — *is* the map's center of gravity. This plan
  puts the flag ring inside the derrick's undercroft, between its legs
  (exactly the shipped map's trick, now at measured scale). The measured
  complex center ref (124.5, 137.5) therefore lands on (520, 486), and the
  yard sits asymmetric on the canvas: interior floor spans (204, 106) to
  (1005, 937); dune band 204 px wide on the west, 106 north, 35 east,
  35 south.
- Verified `chew = 0`: neither the r70 ring nor either spawn pocket
  intersects a single wall pixel (audit in section 6).
- Keep `gunRange = 1300`, `captureRadius = 64`, `captureClear = 210`,
  `flagRing = 70`.

---

## 2. ORIENTATION DECISION

**Plate rotation: NONE (rot = 0).** Game space is reference space; north on
the 2009 minimap is up on the canvas. CTF's spawn diagonal is handled by the
homes (section 5), not by rotating the plate.

**The hero — THE TOWER — verified in game space:** the derrick chain reads
unambiguously on the plate and must stay on this axis:

> **The derrick complex runs NORTH-SOUTH through the yard center. The pump
> house is the NORTH piece (with the drum tank at its SW corner and the west
> feed pipe arriving from the WEST wall); the tower undercroft is the middle;
> the gallery hall extends SOUTH from the tower's SE corner. The big pipe
> leaves the tower's east face heading EAST.**

Any prop/renderer pass must keep the derrick sprite's long catwalk axis N-S
and the gallery hall N-S — this is the exact class of error that shipped
Afghan's plane 90 degrees off (there the plate was rotated and the trace was
not; here rot=0 means image orientation is already correct, so the check is
simply that nothing gets "landscaped" onto the E-W axis again).

Compass mapping (identical, listed for the integrator's sanity):

| 2009 minimap (north up) | game space |
|---|---|
| west edge (road + pipeline) | **west — RED flank** |
| north-east (vat battery) | **north-east — BLUE corner** |
| south-west (warehouse) | **south-west — RED corner** |
| south-east (big tank, garage) | **south-east flank** |

---

## 3. THE BOUNDARY (terrain)

Real Rust has **no enclosing mountain ring** — it is a walled oil yard in an
open dune bowl. [CHOICE] The boundary reads as **the yard's own wall/berm**:
the measured perimeter wall is the playable edge on all four sides, and
everything beyond it out to the canvas edge is solid, painted as open sand
dunes (out-of-bounds art band, like Afghan's mountain band but flat). The
minimap draws the north/west/east walls solid and the south edge faint —
shipped here as a wall band all round.

**Fill the whole canvas solid, then carve the yard floor:**

```
YARD_FLOOR = MapRect(x: 204, y: 106, w: 801, h: 831)
```

Wall thickness inside the yard is normalized to 9 px (minimap lines are
1-2 ref px; 9 px survives disc-fitted collision and reads on screen) [ADJ].

Boundary furniture:

| feature | rect | notes |
|---|---|---|
| west-wall guard box | `MapRect(x: 204, y: 469, w: 12, h: 21)` | measured box on the west wall (ref 15..23, 132..139), solid |

The three **elevated pipes** are walk-unders: tubes are art, only trestle
piers collide (section 4, S17). Pipe routes (canvas polylines, art layer):

- **Road pipeline** (west lane, the S-curve): (270,223) -> (261,493) ->
  (255,568) -> (222,643) -> (195,718) -> (189,940) — south of y~718 it rides
  the boundary wall band.
- **West feed pipe**: (261,376) -> (551,376), terminating at the drum tank.
- **Big pipe**: (597,551) -> (846,551), from the tower's east face to the
  east court.

### Callout -> coordinate index

| callout | canvas anchor |
|---|---|
| The Tower (derrick) | undercroft center (520, 486) — the flag ring |
| Pump house | (615, 337) |
| Drum tank | (567, 373) |
| The Gallery (conveyor hall) | (594, 628) |
| Hopper / conveyor works | (381, 470) |
| Canopy shed | (556, 136) |
| NW shed | (390, 247) |
| Long container | (726, 148) |
| Vat battery | (895, 235) |
| Workshop | (706, 488) |
| Garage | (955, 500) |
| Warehouse | (318, 808) |
| South room | (555, 900) |
| SE shed court | (705, 650) |
| Big tank | (933, 828) |
| The Road (west lane) | (228, 106..940) |
| Big pipe crossing | (720, 551) |

---

## 4. STRUCTURES

All rects `MapRect(x, y, w, h)` canvas px, measured via the section-0
transform unless marked. "walls 9" = hollow room, 9 px walls, listed doors
carved out of them (all doors >= 24 px). Solid = filled footprint.

### S15 THE TOWER (the hero) [ADJ stylization]

The minimap draws the derrick's top platform (31x37 ref px). A top-down
engine wants the GROUND plan: a derrick's legs splay wider than its crown,
so the tower ships as **four lattice legs around an open undercroft** — the
map's power position, holding the engine's center flag ring. Footprint
widened from the measured platform so the forced r70 ring carve chews
nothing (verified chew = 0):

| piece | rect | notes |
|---|---|---|
| legs (4) | `MapRect(x: 436, y: 402, w: 28, h: 28)`, `(576, 402, 28, 28)`, `(436, 542, 28, 28)`, `(576, 542, 28, 28)` | solid; leg centers +-70 px from (520, 486); inner corners r79 from center |
| north porch wall | `MapRect(x: 464, y: 402, w: 112, h: 9)` minus door `(504, 402, 36, 9)` | the measured north room (ref 109..143, 119..127) reduced to the undercroft's north face; door re-centered [ADJ] |
| south band | `MapRect(x: 519, y: 558, w: 60, h: 15)` | measured south wall (ref 124..144, 156..161), pushed to r72 [ADJ] |
| east wall | `MapRect(x: 621, y: 430, w: 9, h: 147)` minus door `(621, 512, 9, 30)` | measured complex east wall (ref 158..159, 119..168) |
| pump skid | `MapRect(x: 594, y: 430, w: 36, h: 78)` | solid; the measured NE room (ref 138..159, 119..145) — after the ring push its interior fell under 24 px, so it ships solid [ADJ] |

**Undercroft mouths** (all >= 24): N door 36; W upper gap 33 (y 430..463)
and W lower gap 58 (y 484..542), split by the conveyor chute; S gap 55
(x 464..519); E door 30. Platform shadow + lattice = art over the legs.

### The derrick chain (attached, N to S)

| structure | rect | notes |
|---|---|---|
| pump house | walls 9 on `MapRect(x: 588, y: 286, w: 54, h: 102)`; doors S `(603, 379, 24, 9)`, W `(588, 320, 9, 30)` | roofed building N of the tower; east wall trimmed 9 px [ADJ] so the windbreak dogleg works |
| drum tank | disc center (567, 373) r 16 | solid; the measured circle (ref (140,100) r~5.5); feed pipe terminates here |
| gallery hall | walls 9 on `MapRect(x: 564, y: 541, w: 60, h: 174)`; doors W `(564, 580, 9, 30)`, E `(615, 640, 9, 30)`, S `(585, 706, 24, 9)`; N end solid | the long conveyor hall S of the tower (ref 139..159, 156..214); 42 px interior; 3-door fight corridor |
| conveyor works: hopper | `MapRect(x: 354, y: 445, w: 54, h: 51)` | solid (ref 69..87, 124..141) |
| conveyor works: chute | `MapRect(x: 408, y: 463, w: 40, h: 21)` | solid; measured chute ran to the tower's west face, trimmed at x 448 to clear the ring [ADJ]; splits the west mouth |
| conveyor works: slab | `MapRect(x: 408, y: 484, w: 12, h: 72)` | measured freestanding wall (ref 109..113, 140..161) sat inside the widened ring — relocated flush against the chute's west end as an L [ADJ] |

### North side

| structure | rect | notes |
|---|---|---|
| canopy shed | hangs from the north boundary; walls: W `MapRect(x: 507, y: 97, w: 9, h: 78)`, E `(597, 97, 9, 78)`, S `(507, 166, 99, 9)` minus door `(537, 166, 39, 9)` | open-sided shed (ref 120..153, 8..34); interior catwalk dots are art |
| canopy SE stub | `MapRect(x: 603, y: 172, w: 24, h: 9)` | measured stub (ref 152..160, 33..35) |
| canopy annex | `MapRect(x: 516, y: 178, w: 24, h: 21)` | solid (ref 123..131, 35..42) |
| NW shed | walls 9 on `MapRect(x: 345, y: 199, w: 93, h: 96)`; door E `(429, 232, 9, 30)` [CHOICE: faces the yard] | roofed shack (ref 66..97, 42..74) |
| NW shed annex | `MapRect(x: 321, y: 277, w: 24, h: 18)` | solid SW annex (ref 58..66, 68..74) |
| long container | `MapRect(x: 675, y: 133, w: 102, h: 30)` | solid (ref 176..210, 20..30) |
| container annex | `MapRect(x: 750, y: 163, w: 24, h: 24)` | solid (ref 201..209, 30..38) |
| vat battery | solid H: `MapRect(x: 834, y: 166, w: 123, h: 54)` + `(858, 220, 75, 30)` + `(834, 250, 123, 54)` | the NE four-vat plinth (ref 229..270, 31..77). [CHOICE] ships SOLID — the real plinth is not enterable at ground level; an enterable version left un-passable slivers around the vat pillars. Vat circles are art at (865,193) (924,193) (865,277) (924,277) r~20; the H waist notches remain as exterior alcoves |

### East side

| structure | rect | notes |
|---|---|---|
| workshop | walls 9 on `MapRect(x: 666, y: 439, w: 81, h: 99)`; doors W `(666, 475, 9, 30)`, S `(696, 529, 30, 9)` | roofed (ref 173..200, 122..155) |
| workshop yard east wall | `MapRect(x: 738, y: 391, w: 9, h: 57)` | the yard N of the workshop (ref x 199..200, y 106..122); yard opens west |
| windbreak wall | `MapRect(x: 642, y: 394, w: 72, h: 9)` | measured freestanding wall (ref 173..189, 105..106), extended to the pump-house corner [ADJ] — turns the Slot into a dogleg (section 6) with a 24 px door at its east end (x 714..738) |
| garage | attached to the east boundary; walls: wing N `MapRect(x: 960, y: 370, w: 45, h: 9)`, wing W `(960, 370, 9, 81)`, hall W `(900, 451, 9, 99)` minus door `(900, 490, 9, 30)`, hall N `(900, 451, 69, 9)`, hall S `(900, 541, 75, 9)`; south face x 975..1005 stays OPEN | roofed L (ref 251..289, 99..159); the open south face is the measured vehicle door (ref x 274..285) |
| small container | `MapRect(x: 924, y: 568, w: 48, h: 30)` | solid (ref 259..275, 165..175) |

### South side

| structure | rect | notes |
|---|---|---|
| SE shed | walls 6 [ADJ: 9 px walls left a 21 px interior no disc can enter] on `MapRect(x: 669, y: 610, w: 39, h: 45)`; interior `(675, 616, 27, 33)`; door S `(678, 649, 24, 6)` | (ref 174..187, 179..194); inner crate = art |
| SE L wall | `MapRect(x: 744, y: 610, w: 9, h: 81)` + `MapRect(x: 669, y: 688, w: 75, h: 9)` | the walled court (ref 199..200/174..199, 179..206) |
| big tank | rotated rect: center (933, 828), 123 x 33, long axis 116 deg (NNE-SSW, i.e. from (960, 772) to (906, 883)); + head skid `MapRect(x: 942, y: 757, w: 36, h: 30)` | solid; the diagonal fuel cylinder (ref 249..278, 227..272); nozzle art poking NE to (978, 739) |
| south container | rotated rect: center (711, 868), 69 x 24, long axis 146 deg | solid (ref ~181..199, 253..276) |
| south room | attached to the south boundary; walls: N `MapRect(x: 504, y: 865, w: 102, h: 9)` minus door `(540, 865, 30, 9)`, W `(504, 865, 9, 72)` minus door `(504, 890, 9, 24)` [CHOICE second door], E `(597, 865, 9, 72)` | walled yard (ref 119..153, 264..291); measured footprint pierced the south wall — clipped to the boundary [ADJ] |
| warehouse | L building, walls 9: main `MapRect(x: 252, y: 715, w: 132, h: 111)` + leg `(252, 826, 60, 75)`; wall runs: N `(252, 715, 132, 9)` minus door `(300, 715, 30, 9)`, E `(375, 715, 9, 111)` minus door `(375, 754, 9, 30)`, inner S `(312, 817, 72, 9)`, leg E `(303, 826, 9, 75)`, leg S `(252, 892, 60, 9)` minus door `(273, 892, 24, 9)`, W `(252, 715, 9, 186)` | the pitched-roof SW building (ref 35..79, 214..276) |
| warehouse nook annex | `MapRect(x: 312, y: 829, w: 24, h: 21)` | solid (ref 55..63, 252..259) |

### Scatter (S16-S18)

| piece | placement |
|---|---|
| plank NW | rotated wall: center (507, 265), 30 x 6, 63 deg (ref (118,60)-(122,68)) |
| plank SE | rotated wall: center (889, 658), 54 x 6, 146 deg (ref (255,190)-(240,200)) |
| pipe trestle piers | 9x9 solid at — big pipe: (684,547) (744,547) (804,547) (840,547); feed pipe: (290,372) (350,372) (410,372) (470,372) (515,372); road pipeline: (267,280) (264,400) (258,520) (240,610) (210,690) + stagger set [ADJ] (216,340) (246,450) (222,540) (231,760) |
| barrel clusters [CHOICE] | solid discs r14 at (795,620) (817,644) — SE court; (822,352) (791,325) — east avenue. Justified by the yard's barrel scatter + the shipped map's precedent; placed to kill the two full-height sightline columns (section 6) |

Art-only props (NO collision — listed so nobody re-adds them as walls): the
three pipe tubes, the truck at center (267, 198) ~30x81 on the road, three
crates at (270, 684) (291, 684) (312, 684), vat cylinders, derrick platform
shadow + lattice, drum piping, tank nozzle, oil stains. Full exclusion list
in `rust-v2-masks/README.md`.

Trenches (walkable, existing trench mechanic — kept from the shipped map's
idea, refitted to the measured yard):

```
result.trenches = @[
  MapRect(x: 430, y: 305, w: 110, h: 50),   # north face run (north field)
  MapRect(x: 446, y: 600, w: 110, h: 50),   # south face run (SW field)
  MapRect(x: 392, y: 560, w: 56, h: 56),    # red approach foxhole
  MapRect(x: 760, y: 430, w: 56, h: 56),    # blue approach foxhole (east court)
]
```

---

## 5. OBJECTIVES

Real Rust's spawns are DIAGONAL (the map is loosely rot180-symmetric): one
team musters at the south-west by the warehouse and road, the other at the
north-east under the vat battery — the shipped map's reading, kept.

| field | value | rationale |
|---|---|---|
| `redHome` | `MapPoint(x: 452, y: 720)` | SW field between warehouse and south room; capture circle r64 clears the warehouse east wall by 4 px |
| `blueHome` | `MapPoint(x: 710, y: 296)` | NE field between pump house, long container and vat battery; circle clears the (trimmed) pump-house east wall by 4 px |
| `redSpawn` | `MapRect(x: 390, y: 790, w: 100, h: 110)` | respawn wave zone OFFSET from the stand: nearest zone point is 70 px from `redHome` — fully outside the r64 capture circle (the Afghan-era respawn-on-the-circle conversion killer) |
| `blueSpawn` | `MapRect(x: 775, y: 185, w: 65, h: 75)` | same rule: nearest point 74 px from `blueHome`, outside r64; clears the container annex by 1 px and the vat battery by 4 |
| `spawnClearW` / `spawnClearH` | **55 / 90** | pockets: red (397..507, 630..810), blue (655..765, 206..386). The yard is tight — Afghan's 80/96 pockets cannot fit between the measured buildings. Verified: neither pocket contains a single wall pixel |
| `carveClear` | **-1** | **load-bearing.** The map's edges are solid dune from every canvas edge to the yard wall; forced home columns would punch floor corridors through the 204 px west dune band and the boundary. -1 (now legal) = NO forced home columns; the spawn pockets alone guarantee spawnable floor |
| `captureRadius` | 64 | MW2-model capture at the stand |
| `medKitSpawns` [CHOICE] | `MapPoint(x: 654, y: 585)`, `MapPoint(x: 380, y: 412)` | one under the big-pipe crossing in the Slot's south mouth (every east-side lane crosses it), one in the west field by the feed pipe (road/north-lane junction); both >= 28 px from any wall, neither owned by a team |

Fairness: straight-line home->center distances are 244 (red) vs 269 (blue),
a 10% gap — but red's line is near-open while blue's is blocked by the pump
house, so blue's BFS walk runs ~1.4-1.5x red's via the Slot dogleg or the
porch door. **Integrator: run the walk-to-midfield BFS check (asymmetric-map
fairness suite). Levers, in order: (1) deepen red to `redHome = (452, 770)`
(pocket stays clean, adds ~50 walk); (2) widen the porch door `(504, 402,
36, 9)` up to 48 px toward blue's approach; (3) as a last resort shift
`blueHome` south-west to (700, 310) — re-verify its pocket if so. Do not
move the stands onto the mid-line: the diagonal IS the map.** Also assert
the asymmetry test actually fires (this layout is NOT a mirror).

---

## 6. LANES

Four genuinely distinct ways between the stands, all forced through the
yard's furniture. Polylines are lane centerlines in canvas px.

**Lane 1 — the Road (west flank):**
```
(452,720) -> (390,760) -> (300,700)          # warehouse north door mouth
          -> (228,640) -> (228,340)          # the road, under the pipeline
          -> (300,250) -> (440,240)          # NW shed front
          -> (540,220) -> (660,240)          # north field, canopy east gate
          -> (710,296)                        # blue stand
```
(Trestle piers stagger the road into >= 26 px slaloms; the lane never sees
mid.)

**Lane 2 — the Tower (center, the map's argument):**
```
(452,720) -> (480,620) -> (492,560)          # between slab and SW leg
          -> (520,486)                        # UNDERCROFT + flag ring
          -> (522,406)                        # porch door
          -> (560,340) -> (640,300) -> (710,296)   # past drum & pump house
```
Sub-route 2b: gallery hall — enter W door (568, 595), run the hall, exit E
door (620, 655) or S door (597, 710); the covered N-S connector between
mid and the south field.

**Lane 3 — the Slot + east court (blue's main press):**
```
(452,720) -> (560,740) -> (620,700)          # hall south door mouth
          -> (648,600) -> (648,470)          # THE SLOT (tower east wall vs workshop)
          -> (700,420) -> (726,398)          # dogleg door over the windbreak
          -> (710,296)                        # blue stand
```

**Lane 4 — the South road + east avenue (crossover):**
```
(452,720) -> (520,820) -> (620,780)          # south field, past south room
          -> (760,700) -> (800,640)          # SE court, barrels
          -> (820,500) -> (790,420)          # east avenue (workshop vs garage)
          -> (800,340) -> (775,300)          # vat west alcove
          -> (710,296)
```

Chokepoint schedule ([ADJ] values already reflected in section 4):

| chokepoint | measured gap | shipped gap | how |
|---|---|---|---|
| the Slot (tower E wall/pump skid vs workshop W wall) | 15 ref-scaled (NB vs workshop) | **36** | pump-house E wall trimmed 9 |
| Slot dogleg door (windbreak E end vs yard E wall) | — (new) | **24** | windbreak spans 642..714, yard wall at 738 |
| undercroft mouths | n/a | **36 / 33 / 58 / 55 / 30** | N door / W upper / W lower / S gap / E door |
| SE shed interior | 21 (9 px walls) | **27** | walls thinned to 6 [ADJ] |
| big tank vs east wall | 27 | **27** | kept — the real pinch behind the tank |
| small container vs east wall | 33 | **33** | kept |
| vat battery vs long container | 57 | **57** | kept (blue's front door) |
| vat battery vs garage wing | 66 | **66** | kept |
| road at trestle piers | 48 lane | **>= 26** | piers offset toward the wall side |
| chute/slab vs SW leg | — | 16 (dead notch, not a route) | documented; non-sealed |

Invariant compliance (audited on the emitted masks, not by eye):

- **No full-width open row: 0.** Scan of all 831 interior rows found none
  (the derrick chain + warehouse/canopy columns interrupt every east-west
  line; longest open row segment ~430 px in the north field).
- **No full-height open column: 0.** This needed four [ADJ] plugs, all
  in-theme: the road stagger piers, the re-centered porch door (a 1 px
  slit at x 496 ran wall-to-wall through the old door position), the
  windbreak extension (killed the 15 px slit beside the Slot), and barrel
  (791, 325) (closed x 777..780 between container and vat battery).
- **No sealed pockets: 0** floor components > 60 px besides the main field.
  Every interior (workshop, garage, both sheds, warehouse, south room,
  canopy, pump house, gallery, undercroft) is reachable — verified by flood
  fill AND by disc-fit reachability (floor eroded by r=11: player 13 px +
  4 px collision overreach per side) from `redHome` to 18 probe points.
- **Doorways >= 24 px:** every carved door is 24-39 px (listed per
  structure); undercroft mouths 30-58.
- **Engine carve safety:** flag ring r70 and both spawn pockets intersect
  0 wall pixels; nearest tower piece to center is r72 (south band), legs'
  inner corners r79.
- **Pickups on occupiable floor:** both medkits and all four trenches sit
  on carved floor >= 28 px from any wall.
- Run the 1-px flood from `redHome` asserting it reaches `blueHome`, both
  medkits, and all nine interiors; assert the asymmetry test fires; run
  walk-to-midfield BFS parity per section 5.

Verification render used for this plan: `/tmp/rust_plan_view.jpg`
(canvas-scale render of both masks + objectives + pipes + lanes overlay,
judged side-by-side against the stretched reference plate). Regenerate by
rasterizing the section-4 tables at canvas scale if the reference or the
scale changes.
