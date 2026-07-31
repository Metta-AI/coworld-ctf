# Terminal layout v2 — measured rebuild plan

Status: layout plan for the integrating session. Supersedes the current
in-game `terminalCtfMap()` (1235x659). Fixes the three standing defects: the
57,100px² never-entered apron (the pack's largest dead region, per
docs/designs/mw2-playtest-loop.md), the invented full-length north tarmac
band with a horizontal 747 (the measured plane is diagonal, at the aircraft
stand), and the 1.27x vertical aspect squash the old canvas imposed on the
whole interior.

Provenance: every number below is MEASURED from the official 2009 overhead
(`docs/designs/mw2-reference/terminal.png`, 512x512), classified on luminance
(the distribution is cleanly trimodal: wall > 222, floor < 110, out-of-bounds
between), cropped to the true playable frame (0, 70, 512, 430) of the
original, rotated 180 degrees into game space, component-labelled and
contour-traced (Douglas-Peucker eps 8 canvas px). The transform from original
minimap pixels (ox, oy) to THIS canvas is:

```
canvas.x = 1279 - 2.5 * ox
canvas.y =  899 - 2.5 * (oy - 70)
```

(2.5 = uniform chosen scale; the 180-degree rotation is baked into the two
subtractions.) Items marked [CHOICE] are creative decisions where the
reference is ambiguous or illegible; [ADJ] are deliberate departures from the
measured footprint (to clear an engine-forced region or to widen a chokepoint
to playable width).

**The rasters are the source of truth.** Canvas-scale wall masks live in
`docs/designs/mw2-reference/terminal-v2-masks/` (see its README for semantics,
compose order, and white-pixel counts). Polygons in this document are
transcriptions of those masks; where they disagree, the masks govern.

---

## 1. CANVAS

**`width = 1310, height = 900`** [CHOICE]

- Real Terminal's playable frame measures 512x360 original px (playable floor
  bbox x 9..504, y 87..421 plus breathing margin), aspect **1.42**. The
  current 1235x659 canvas is aspect 1.87 — a 1.27x vertical squash that is
  exactly what crushed the apron into a 100px strip and flattened every room.
- Scale 2.5 px-canvas per px-reference, **uniform in x and y** (the old
  prepped plate stretched x by 2.51 and y by 1.98 — non-uniform). Content
  spans x 19..1257, y 21..857; the extra band to each edge is out-of-bounds
  tarmac/roof art. Nothing playable touches the canvas edge.
- Width is 1310, not 1280, so the two flag homes sit symmetric about the
  engine's forced center: `131 + 1180 = 1311 = width + 1`. The 30px x 900
  band at x 1280..1309 is out-of-bounds art (sea in `shell.png`).
- Engine center is **(655, 450)** — it lands in the concourse corridor
  between the newsstand block and the bookstore. No open r70 disc exists
  anywhere in the measured mid-field (this is a furnished airport, not a
  valley), so the forced flag ring is DESIGNED IN as **Center Court**: a
  deliberate mid plaza, with the four structure trims it requires documented
  in section 4. The r70 ring is not a per-map knob; the layout was shifted to
  meet it, not vice versa.
- Keep `gunRange = 1300`, `captureRadius = 64`, `captureClear = 210` (room
  bookkeeping only — see next line).
- **`carveClear = -1`** — load-bearing. The 96px always-floor home columns of
  the current map would punch floor through the west out-of-bounds tarmac
  band AND through the 747's hull (the hull crosses x < 96). With -1, only
  the r70 center ring and the two spawn pockets are engine-forced; both are
  audited clean below. (Same reasoning and precedent as Afghan v2.)
- **`spawnClearW = 55, spawnClearH = 48`** [ADJ] — pockets sized to the
  measured halls. Red's pocket (76..186, 382..478) sits in the natural 100px
  clearing between the ticket-office block (south wall face y 379) and the
  Burger Town counter island (north face y 482) and force-carves **zero**
  measured structure. Blue's pocket (1125..1235, 382..478) needs exactly one
  [ADJ]: the security x-ray capsule's east 28px (see section 4). Larger
  pockets (the old 70/130) cannot fit any real room at either end without
  demolishing it.

---

## 2. ORIENTATION DECISION

**Plate rotation.** `tools/mw2_ref_prep.py` declares terminal `rot=0`, but the
map was INTEGRATED after a 180-degree correction ("orientation matched to the
reference plate (Terminal needed 180°)" — docs/designs/mw2-parity-audit.md),
and the current in-game map follows it. **v2 keeps the 180.** Game space =
original minimap rotated 180 degrees. Compass mapping:

| original (2009 minimap, north up) | game space |
|---|---|
| west (security comb, offices, escalators) | **east — BLUE end** |
| east (great hall, gates, the 747 at its stand) | **west — RED end** |
| south (tarmac apron, baggage track) | **north flank (the apron)** |
| north (back rooms, medical room) | **south rooms** |

**The 747 — position and heading, verified explicitly.** The minimap does
not draw the cabin interior as floor — covered playable areas are the one
class the trace loses (same as Afghan's dotted cave). What it DOES draw is
the **aircraft stand**: the playable boundary's canted face, measured at rim
points `(166,146) -> (49,216) -> (19,274)` (canvas px, game space), a
fuselage-length diagonal with the jet-bridge structure (measured block at
(44..72, 392..477)) touching the boundary at its south-west end, and the
swept wing shapes visible in the out-of-bounds wash beyond it.

> **The 747 parks along the NORTH-WEST canted face — the WEST END of the
> concourse. The hull runs SW-NE on axis u = (0.754, -0.657): nose cone at
> canvas (51, 238), tail cone at (284, 34). The aircraft faces WSW (heading
> ~229). Its SE flank is the PORT side and faces the concourse — which is
> why the jet bridge docks there, at the forward door, aviation-correct.**

The current in-game placement (horizontal hull at y 96..150, x 300..710,
nose west) got the END right (west) and the heading 41 degrees wrong, and
invented a full-length north tarmac to park it on. The measured apron is a
WEDGE at the plane end, not a band (section 3).

Why the old error happened: the plane is not literally drawn on the minimap,
so the tracer had nothing to rotate; the v1 author placed it by eye on the
squashed plate, where the canted stand face reads as nearly horizontal.

---

## 3. THE SHELL

The terminal is fully enclosed. **Fill the entire canvas with wall, then
carve the playable floor as the polygon below**, which is the measured outer
face of the playable region (154 pts, canvas px, eps 8; transcription of
`shell.png` — the mask governs):

```
SHELL_RIM = [
  (1256,506),(1256,416),(1242,414),(1242,399),(1256,396),(1256,294),
  (1244,294),(1242,279),(1114,279),(1114,314),(1132,314),(1132,332),
  (1019,332),(1019,314),(1094,314),(1094,279),(1036,276),(1094,272),
  (1094,179),(1024,179),(1029,279),(956,279),(954,256),(966,254),
  (966,132),(936,102),(929,106),(854,22),(774,22),(772,76),
  (766,66),(604,66),(604,139),(662,166),(639,169),(616,146),
  (594,146),(594,189),(562,192),(559,219),(554,186),(586,184),
  (582,146),(452,146),(449,172),(444,146),(286,146),(284,169),
  (246,169),(244,146),(166,146),(49,216),(19,274),(19,529),
  (42,532),(42,586),(19,589),(19,652),(49,682),(116,684),
  (52,689),(52,702),(94,696),(92,719),(52,726),(52,844),
  (74,844),(74,806),(84,804),(52,802),(54,764),(94,766),
  (92,804),(112,806),(112,844),(154,844),(152,802),(174,804),
  (184,844),(184,692),(169,689),(169,669),(184,664),(186,596),
  (249,596),(252,579),(276,579),(279,596),(332,599),(329,609),
  (286,609),(276,632),(284,639),(232,689),(199,699),(199,784),
  (256,784),(259,799),(284,799),(286,856),(326,856),(329,796),
  (444,796),(446,856),(482,856),(484,844),(499,844),(499,776),
  (444,769),(506,772),(502,856),(659,856),(662,796),(692,796),
  (709,826),(792,826),(812,796),(829,796),(832,812),(884,812),
  (884,659),(926,662),(924,674),(899,674),(899,732),(934,732),
  (934,716),(946,714),(949,744),(914,746),(962,746),(962,679),
  (949,679),(946,704),(934,702),(934,662),(962,659),(949,524),
  (1002,524),(1004,506),(1016,506),(1022,524),(1094,524),(1094,502),
  (1019,502),(1016,486),(1132,484),(1134,499),(1114,502),(1114,524),
  (1134,526),(1134,549),(1219,549),(1219,524)
]
```

Named wall segments (real callouts, referenced by canvas coordinates):

| segment | where | what it is |
|---|---|---|
| **The aircraft stand** | (166,146)-(49,216)-(19,274) | the canted NW face the 747 parks on; v2 replaces this stretch of shell with the hull itself (section 4) |
| **North face + apron edge** | y=146 run, x 166..594 | the terminal's face onto the tarmac; the two small notches at (244..284) and (444..452) are measured door alcoves |
| **The baggage feed** | (554..594, 146..219) | measured housing where the belt exits to the tarmac; abuts the rim |
| **Gates B1/B2 block** | (604..766, 66..146) | the north-east lounge rooms, entered from the carousel hall through the (616..662, 146..169) tongue |
| **NE rim** | (766,66)..(966,132)..(956,279) | the angled north-east boundary behind the gates |
| **The queue walls** | (1019..1132, 272..332) | security's weaving queue against the north-east rim |
| **East offices face** | x=1256 run, y 294..506; tabs at (1242,399..414) | the office back wall; the 14px tabs are measured desk alcoves |
| **Offices south tongue** | (1134..1219, 524..549) | the offices' south doorway band |
| **SE rooms rim** | (884..962, 659..746) | arrivals offices pocket, with measured desk notches |
| **South face** | y≈796..856 runs, x 199..884 | the concourse's south wall; lounge bays protrude |
| **SW escalator pocket** | (19..184, 589..844) | the escalator-lobby bays at the south-west corner |
| **West gate face** | x=19 run, y 274..589 | the gate A2 pocket's west wall, behind the jet bridge |

**The apron is a wedge, not a band.** Playable tarmac exists only from the
stand face east to the baggage feed (x ~96..554, y ~146..274, ~57,000px²)
plus the v2 tail-apron carve behind the hull (section 4). The rest of the
old north band was invented ground and is out-of-bounds art here.

Stray floor slivers disconnected in the trace (two, < 35 refpx) are absorbed
into wall by construction — only the main floor component is carved.

---

## 4. STRUCTURES

All rects are `MapRect(x, y, w, h)` canvas px; diagonals are
`shapeDiagonal(x0, y0, x1, y1, thickness)`; discs are `shapeDisc(cx, cy, r)`.
Measured unless marked.

### The 747 — a cabin you fight through [ADJ: authored on the measured stand]

The owner's walkable-747 is kept and re-founded on the measured stand: hull
axis u = (0.754, -0.657) from nose (51,238) to tail (284,34), i.e. exactly
along the traced canted face, 353px ≈ a 747-400 at this scale (content width
1237px ≈ the real ~250m concourse → 4.95 px/m → 70.6m = 350px). The cabin
straddles the old boundary: NW flank in what was out-of-bounds, SE flank on
the apron. **Aisle 26px, all three doors 26-27px** (hard requirements: disc
overreach + 13px player).

Collision (also emitted as `hero-747.png`):

| piece | literal | notes |
|---|---|---|
| SE (port) flank, nose stub | `shapeDiagonal(80,237, 91,228, 12)` | |
| SE flank, fwd-mid | `shapeDiagonal(112,209, 174,155, 12)` | |
| SE flank, mid-aft | `shapeDiagonal(195,137, 257,83, 12)` | |
| SE flank, aft stub | `shapeDiagonal(278,64, 284,59, 12)` | |
| NW (starboard) flank, solid | `shapeDiagonal(52,225, 261,43, 12)` | faces out-of-bounds |
| nose cone | `shapeDisc(51, 238, 26)` | seals the fwd end |
| tail cone | `shapeDisc(284, 34, 20)` | seals the aft end |
| inner nacelle | `shapeDisc(188, 200, 15)` | on the apron, under the art wing — apron cover |
| outer nacelle | `shapeDisc(252, 190, 13)` | apron cover |
| air-stair unit | `shapeDisc(284, 93, 11)` | at the aft door |

The three doors are the GAPS between SE-flank segments, centered at
**(102,218)** (fwd door — the jet bridge docks here), **(184,146)** (mid
door, onto the apron), **(267,74)** (aft door, air-stairs down to the tail
apron). If rasterizing shell-first, punch r13 discs at those centers
(`v2-carve.png` already has them).

Forced-floor carves that found the plane (capsule = centerline + width):

| carve | spec | why |
|---|---|---|
| cabin aisle | capsule (63,227) -> (277,40), width 26 | the fighting corridor |
| tail apron | capsule (221,120) -> (342,15), width 60 | the tarmac wedge behind the SE flank; the aft door and air-stairs land here — this was unreachable out-of-bounds in the measured rim |
| jet bridge, south leg | capsule (84,396) -> (84,300), width 26 | carved through the gate pocket's north band |
| jet bridge, north leg | capsule (84,300) -> (109,227), width 26 | angles up to the fwd door, as a bridge does |

Art (no collision): both wings as sprites swept ~55 degrees off the axis
from root ~(147,153) — the SE wing overhangs the apron (you walk under it;
the two nacelle discs are its ground truth), the NW wing lies in the
out-of-bounds band; tailplanes at the tail cone; fuselage flank sprites along
the axis at rot ≈ -41; the measured jet-bridge block (44..72, 392..477)
stays as the bridge's machinery base.

### Center Court — the engine's forced plaza, designed in [ADJ]

r70 forced ring at (655,450); design margin r74. Four trims make it a real
mid plaza instead of a random bite:

| [ADJ] | literal | what it does |
|---|---|---|
| plaza clear | disc r74 at (655,450), forced floor | clears the conveyor pips and wall stubs inside the ring |
| bookstore splay storefront | walls `shapeDiagonal(610,585, 660,540, 10)` + `shapeDiagonal(688,515, 752,457, 10)`, corner clear `MapRect(640,470,110,96)` | replaces the bookstore's square NW corner with a 45-degree storefront tangent to the ring; the 36px gap between the two segments is the store's plaza door; the west segment also breaks the x≈615 full-height sightline column |
| newsstand SW tip | clear `MapRect(640,372,100,62)` | sets the shop's face back to y≤372 so the ring carves nothing |
| info kiosk | remove `MapRect(642,419,20,18)`, re-add at `MapRect(914,478,26,22)` | the measured kiosk sat inside the ring; its new spot in the pre-security hall breaks the x≈933 full-height column |

### Security — the comb, opened to playable width [ADJ]

Measured pieces (keep): x-ray capsule (999..1144, 374..439), belt tables
(989..1054, 336..368) and (989..1054, 446..476), detector frames
(1064,336,12,30) and (1064,446,12,30), I-mark (999,396,18,20), queue walls
per SHELL_RIM. The comb as traced is SEALED (6-7px slits). Carves:

| [ADJ] | literal | shipped width |
|---|---|---|
| north lane | clear `MapRect(985,354,140,26)` | 28 |
| south lane | clear `MapRect(985,436,140,26)` | 28 |
| detector frame trims | clear `MapRect(1060,352,20,16)`, `MapRect(1060,440,20,24)` | the frames still read; the lanes pass through them |
| queue slot | clear `MapRect(1092,272,26,44)` | 42 |
| capsule east trim | clear `MapRect(1121,370,28,74)` | blue spawn-pocket clearance (section 5) |

### Baggage — belt, carousel, feed [ADJ solidified from the measured dots]

The minimap draws conveyors as dotted pips. v2 solidifies the two that shape
play, and leaves the mid-hall spur dots as measured (broken low cover):

| piece | literals | notes |
|---|---|---|
| apron belt wall | `MapRect(96,274,54,8)`, `MapRect(182,274,106,8)`, `MapRect(344,274,108,8)`, `MapRect(484,274,16,8)` | walls the baggage hall off the tarmac, on the measured dot line |
| belt doors | dot-clears `MapRect(150,268,32,18)`, `MapRect(288,264,56,26)`, `MapRect(452,268,32,18)` | three doors, widths 32/28/27 |
| the carousel | `MapRect(634,177,66,8)`, `MapRect(728,177,168,8)`, `MapRect(888,185,8,108)`, `MapRect(660,293,120,8)`, `MapRect(808,293,88,8)` | the loop on the measured dot path; gaps at (700..728, 177) and (780..808, 293), both 28 |
| baggage feed | measured housing (554..594, 146..219), keep | the apron's east pinch |
| conveyor spur | measured dots x 596..624, y 270..530, keep (plaza clears its middle) | broken N-S cover through mid |

### The Bookstore — walk-in [CHOICE]

The big roofed unit (634..826, 422..682) becomes the map's fight-inside shop:
interior clear `MapRect(660,560,130,90)`, south door `MapRect(700,650,26,44)`
(width 28), east door `MapRect(818,600,30,26)` (width 42), plaza door = the
splay gap (36). Shelf islands `MapRect(688,592,64,10)` and
`MapRect(688,618,64,10)`. All other roofed units stay solid — one walk-in
shop is signal, five is mush.

### Callout -> coordinate index

| callout | canvas anchor | trace id |
|---|---|---|
| The 747 / the Plane | hull (51,238)-(284,34) | authored on the measured stand |
| The Apron | wedge (96..554, 146..274) + tail apron | |
| Gate A2 (RED spawn zone) | pocket (19..110, 274..529) | jet-bridge base s24 |
| Burger Town | counter island (122..197, 479..569) | s18/p180 — red stand's backdrop |
| The Café | kiosk (259..337, 404..532) | s19/p202 |
| Ticket office | room block (106..281, 304..379) | s41/p269 |
| Baggage claim | hall (96..600, 186..430) | belt + spur |
| The Carousel | loop (634..896, 177..301) | solidified dots |
| Gates B1/B2 | rooms (604..766, 66..146) | p648; gate-seating art |
| The Newsstand | block (626..811, 219..372 after trim) | p236 |
| Center Court | (655,450) r70 | engine-forced, designed |
| The Bookstore | (634..826, 422..682), walk-in | p61 |
| Duty Free | block cluster (392..599, 454..707) | p171/p175/p45 — solid |
| Info desk | (856..924, 384..426) | s33/p240 |
| Flight-info kiosk | (914,478,26,22) | relocated s31 |
| Security | comb (985..1150, 272..480) | s28/s44/s23/s22/s45 |
| The Offices (BLUE spawn) | (1160..1256, 294..506) | desk tabs in rim |
| Medical room | (549..609, 686..791) — the white cross | s1/p21 |
| Arrivals offices | (660..960, 620..790) | SE rooms |
| Concourse pillars | (302,629,20,52), (349,629,20,52) | s12/s13 |
| Escalators | SW pocket (19..184, 589..844) | balustrade walls s14-s16 |
| Luggage carts | (292..364, 202..280) on the apron | s95, tilted pair |
| The tug | (62..104, 246..286) | s81 |

---

## 5. OBJECTIVES

| field | value | rationale |
|---|---|---|
| `redHome` | `MapPoint(x: 131, y: 430)` | the west hall between ticket office and Burger Town — where the plane-side team musters off the gate |
| `blueHome` | `MapPoint(x: 1180, y: 430)` | the office antechamber directly behind security — the drop-off-side muster |
| `captureRadius` | 64 | unchanged (MW2 capture model) |
| `redSpawn` | `MapRect(x: 20, y: 296, w: 76, h: 88)` | Gate A2 pocket, ~110px NW of the stand; audited zero wall px |
| `blueSpawn` | `MapRect(x: 1190, y: 416, w: 56, h: 84)` | inside the offices, ~35px E of the stand behind the desk tabs; zero wall px |
| `spawnClearW/H` | **55 / 48** | see section 1; red pocket carves ZERO measured structure, blue only the capsule [ADJ] |
| `carveClear` | **-1** | see section 1 — forced columns would breach the hull and the west tarmac band |
| `medKitSpawns` [CHOICE] | `MapPoint(x: 398, y: 206)`, `MapPoint(x: 940, y: 430)` | one mid-apron (clearance 32px — a reason to cross the tarmac), one in the pre-security hall (clearance 17px) — both on contested ground, neither owned |
| `trenches` | `MapRect(304,158,140,44)` apron service duct; `MapRect(370,210,44,40)` apron foxhole; `MapRect(500,400,48,48)` west of the conveyor spur; `MapRect(816,320,44,44)` carousel east; `MapRect(900,560,48,48)` SE hall | all five audited zero wall px; two on the apron by design |

Symmetry: homes symmetric about center-x by construction
(131 + 1180 = 1311 = width + 1), both at y 430 (off the y-center line, like
the real spawns). **BFS walk-to-midfield, measured on the composite with
forced regions applied: red -> Center Court 524, blue -> Center Court 525
(0.2% apart), red <-> blue 1049.** The asymmetric-map fairness suite should
still assert this (and assert the map is NOT a mirror); if a future edit
shifts it, nudge `blueHome` west along y=430 — red is hall-locked.

---

## 6. LANES

Three genuinely distinct ways across, plus the cross-links. Polylines are
lane centerlines (every waypoint verified on floor); lengths are polyline px.

**Lane A — the Plane / Apron (north), len ~1575:**
```
(131,430) -> (60,330) -> (84,300)             # Gate A2, jet bridge
          -> (102,218)                        # fwd door, into the cabin
          -> (184,146) -> (267,74)            # the aisle (mid + aft doors)
          -> (330,95) -> (430,200)            # air-stairs, tail apron
          -> (560,245) -> (620,230)           # apron east, past the feed
          -> (680,150) -> (714,190)           # Gates B1/B2, carousel N gap
          -> (830,240) -> (1000,290)          # carousel hall
          -> (1060,300) -> (1090,367)         # the queue, comb N lane
          -> (1180,430)
```
Sub-route A': skip the cabin — Gate A2 -> apron directly via the belt door W,
or exit the cabin mid-door and re-enter the hall via belt door C.

**Lane B — the Concourse (center), len ~1064:**
```
(131,430) -> (260,430) -> (420,400)           # west hall, baggage claim edge
          -> (560,430) -> (655,450)           # spur gap, CENTER COURT
          -> (770,447) -> (830,450)           # newsstand-bookstore corridor
          -> (940,430)                        # pre-security (medkit B)
          -> (1050,449) -> (1120,449)         # comb S lane
          -> (1180,430)
```

**Lane C — the South rooms, len ~1352:**
```
(131,430) -> (180,560) -> (300,640)           # past Burger Town, escalators
          -> (400,690) -> (530,730)           # south lounge bays
          -> (620,760) -> (721,783)           # Medical room, arrivals row
          -> (900,620) -> (940,500)           # SE hall, north turn
          -> (1050,449) -> (1120,449)         # merges at the comb S lane
          -> (1180,430)                       # (the offices' south tongue
                                              #  (1134..1219, 526..549) is the
                                              #  flanking back door)
```

Cross-links: the three belt doors (A<->B through baggage claim), the
carousel gaps (A<->B), the bookstore's three doors (B<->C through the shop),
the conveyor-spur plaza gap, and the offices south tongue (C -> blue's back
door).

**The apron now has three reasons to exist** (the v1 defect: alternates
existed but the flag crossed in ONE lane, and 57,100px² of apron was never
entered): (1) Lane A is the ONLY route through the cabin, and the cabin's
mid/aft doors dump onto it; (2) medkit A (398,206) and two of five trenches
sit on it; (3) cover parity — nacelles, luggage carts, the air-stair, the
belt wall and the feed housing turn the old open band into fightable ground.
Route-length spread A/B/C = 1575/1064/1352 keeps mid fastest but flankable.

Chokepoint schedule (all [ADJ] carves from section 4; widths measured on the
composite by distance transform):

| chokepoint | measured | shipped | how |
|---|---|---|---|
| security comb lanes | 6-7px, sealed | **28 + 28** | N/S lane carves |
| detector frames | 14px under-frame | **28** | frame half-trims |
| the queue slot | 20px | **42** | queue widening carve |
| belt line (apron <-> baggage claim) | dotted, no formal door | **32 / 28 / 27** | solidify + three doors |
| carousel | dotted loop | **28 + 28** | solidify + two gaps |
| cabin doors | not traced (covered) | **26 / 27 / 26** | flank gaps |
| cabin aisle | not traced | **25-26** | 26px hull spacing |
| jet bridge | not traced | **26 (legs), 58 (mouth)** | capsule carves |
| plaza corridor | 24px slot at x 602..626 | **r70 plaza** | forced ring, designed |
| bookstore | sealed roof | **36 / 28 / 42** | walk-in carve + three doors |

Invariant compliance (all measured on `v2-composite.png` with the engine's
forced regions applied):

- **Connectivity:** ONE floor component; no sealed pocket ≥ 50px anywhere
  (cabin, bookstore, offices, medical room, gates all breathe).
- **No open cross-field row:** longest floor row-run < 850 of 1310. No
  full-height column: the two measured 600px+ columns (x≈615, x≈933) are
  broken by the splay storefront and the relocated info kiosk.
- **Forced-carve hygiene:** red pocket 0 wall px; blue pocket 0 after the
  capsule trim; Center Court trims are section 4's four [ADJ]s and nothing
  else. Both spawn zones, all five trenches: 0 wall px.
- **Doors ≥ 24px everywhere** — every portal in the schedule above measures
  25px or wider.
- **Pickups on occupiable floor:** medkits at 32px / 17px clearance.
- Run the 1px flood from `redHome` and assert it reaches `blueHome`, both
  medkits, the aisle mid-point (169,133), the bookstore interior (725,585),
  the offices (1220,440), and the medical room.

Verification renders: `/tmp/terminal_plan_view.jpg` (annotated canvas-scale
overlay: shell + structures + hero + lanes + objectives, eye-verified).
Regenerate via the measurement pipeline in the provenance note if the
reference or scale changes; the masks in
`docs/designs/mw2-reference/terminal-v2-masks/` are the arbiter.
