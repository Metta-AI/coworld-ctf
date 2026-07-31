# Favela layout v2 — measured rebuild plan

Status: layout plan for the integrating session. Supersedes the current
in-game `favelaCtfMap()` (1235x659). Fixes the filed defect (board task
fd4bf8ba): the current midfield is ONE 486px continuous open span because the
traced blocks stop short of the centre. Real Favela's buildings run THROUGH
the middle — the map IS its alley grid. **This plan divides the engine-center
column into exactly FIVE distinct alleys (verified on the shipped rasters),
while keeping the streets wide enough that the map still converts** (current
Favela has the pack's best dead-space number; nothing here is a maze — min
corridor 26px, main street 56px, and every named room floods from redHome).

Provenance: every number below is MEASURED from the official 2009 minimap
(`docs/designs/mw2-reference/favela.png`, 512x512), frame-cropped per
`tools/mw2_ref_prep.py` (favela: rot=0, frame (0.100, 0.150, 0.900, 0.880)),
uniformly rescaled x3 (the prep tool's 1235x659 plate squashes favela 1.71x
vertically — same defect that amputated Afghan), percentile-stretched,
thresholded (Otsu T=119), scipy-component-labelled and cv2-contour-traced
(approxPolyDP eps 6-10). The transform from 512-reference pixels (rx, ry) to
THIS canvas is:

```
canvas.x = round((rx - 51) * 3.0)
canvas.y = round((ry - 76) * 3.0)
```

(51/76 = the prep-tool playable-frame origin; 3.0 = chosen scale; no
re-centering offsets are needed — the measured street junction at the map's
heart lands at (613,561), 1px from the engine's forced center.) Items marked
[CHOICE] are creative decisions where the reference is ambiguous; [ADJ] are
deliberate departures from the measured footprint (engine carve zones, 24px
width discipline, or anti-sightline baffles).

**Machine-readable source of truth: `tools/mw2_favela_v2_plan.py`** holds
every polygon/rect below as data, rasterizes the shipped masks
(`docs/designs/mw2-reference/favela-v2-masks/`), re-runs every acceptance
check, and renders the plan view. Change geometry THERE, never only here.

---

## 1. CANVAS

**`width = 1228, height = 1122`** [CHOICE]

- Real Favela's playable frame is 409x374 in 512-reference space (aspect
  1.096, near-square) — the current 1235x659 canvas squashes it 1.71x
  vertically, which is what flattened the hillside into one open span.
- Scale 3.0 px-canvas per px-reference matches the Afghan v2 plate scale, so
  footprints and engagement ranges feel like the rest of the pack.
- Engine center is `(614, 561)` — the measured main street/alley junction
  (the town square). The flag ring r70 sits in that junction; every adjacent
  face is placed 70+ px from center, so **no forced carve chews any
  structure** (verified: 0 wall px inside the ring or either spawn pocket).
- Keep `gunRange = 1300`, `captureClear = 210`, `flagRing = 70`,
  `captureRadius = 64`.

---

## 2. ORIENTATION DECISION

**Plate rotation: none** (`rot=0`, per `tools/mw2_ref_prep.py`) — the real
map's spawn-to-spawn axis already runs east-west. Verified per structure on
the plate (game space == reference space here):

| structure | game-space orientation (verified) |
|---|---|
| the main street + market stalls | runs EAST-WEST across the whole south, y ~727-783, and BENDS up at x~880 (measured shop fronts step y 736 -> 721 -> 661) |
| the hillside | rises to the NORTH: street level -> shop back alley -> mid terrace -> upper back alley -> top terrace (5 steps), plus a LOWER terrace south of the street |
| the big shop row (comp 180) | long axis east-west, fronting the street |
| the ladder building / east terrace (comp 98) | long axis NORTH-SOUTH — the tall landmark column of the blue end |
| the crackhouse mass (comp 92) | L-shaped, its tower overlooking the town square from the north-west |
| the west yard (the Pitch) | walled rectangle on the WEST edge, its mouth facing east |
| upper back alley | east-west along the north edge, y ~150-218 |

RED = west end (the pitch yard), BLUE = east end (NE yard under the ladder
building terrace). The layout is used VERBATIM (`fullObstacles`, no mirror) —
mirroring would destroy the alley grid that makes it Favela.

---

## 3. THE BLOCK FABRIC

Fill the entire canvas with hillside mass (wall), then carve the playable
outline below; the named blocks are then stamped back INSIDE it. This one
polygon is the playable boundary (canvas px, clockwise; [ADJ] noted):

```
BOUNDARY = [
  (342,106),(525,106),(525,32),(668,32),(670,120),      # top terrace notch
  (932,150),(1000,150),(1000,120),(1160,120),           # north edge; NE yard deepened to y120 for the blue pocket [ADJ]
  (1217,180),(1181,269),(1181,306),(1210,310),          # NE corner + jut
  (1208,490),(1160,660),(1160,828),                     # east wall + SE diagonal
  (1060,860),(1060,985),                                # SE yard
  (708,985),(708,1091),(664,1091),(664,783),            # south stairs + bottom landing (shaft moved x620->664 [ADJ], anti-sightline)
  (443,783),                                            # street south face (pocket mouth staggered off the shop cut [ADJ])
  (443,947),(266,947),                                  # SW pocket
  (223,893),(189,869),(167,857),                        # SW pocket west mouth
  (27,838),(29,776),(73,777),(79,736),                  # west nook (boulder ground)
  (161,734),(177,607),                                  # stepped street east side
  (120,530),(80,530),(54,488),                          # yard south extension [ADJ: red pocket clearance]
  (54,260),(247,258),(247,282),(342,282),               # west yard north wall + the yard slot's ceiling (x 245..345, y<282 is SOLID hillside)
]
```

Four solid masses INSIDE the outline (also perimeter):

```
PERIM_SOLIDS = [
  [(708,815),(908,815),(908,905),(708,905)],     # south terrace block (street vs lower pocket)
  [(1021,716),(1160,716),(1160,828),(1021,828)], # SE corner block (east reach vs SE yard)
  [(664,120),(694,120),(694,220),(664,220)],     # north-edge spur [ADJ]: bends the upper back alley (dogleg x 628..664)
  [(932,150),(946,150),(946,218),(932,218)],     # buttress at the measured jog (932,151)-(944,172): caps the Bar-front alley (east end descends the bar-arm gap); (946..1000, 150..221) is a yard-side spawn nook
]
```

### The stepped hillside terraces

Five measured terrace levels, north (top) to south (bottom); the terrace
edges are the map's east-west walls:

| level | ground | terrace edge below it |
|---|---|---|
| T0 top terrace | notch (525..668, 32..106) wrapping the hilltop shack | boundary step y 106 |
| T1 upper back alley | y ~150-218, x 342..932, plus the NW terrace column (342..472, 106..336) linking it down to the yard slot; the east end descends the bar-arm gap (x 902..930) | yellow building / bar row tops |
| T2 mid terrace | y ~300-383, x ~540..970 | the terrace lip wall (740..917, 383..408) — the measured comp-92 east arm |
| T3 street level | town square + shop back alley + main street y 583..783 | street south face y 783 |
| T4 lower terrace | south stairs + lower pocket + SE yard, y 783..1091 | (lowest ground) |

West-side steps: the stair wall + parapet (comp 133) and the slope terrace
wall step the plaza street down. The measured downhill quad was
(98,490)-(177,607)-(161,734)-(79,736); the SHIPPED road runs EAST of the
(120,530)-(177,607) diagonal (the quad's west half was traded for the
red-pocket yard extension [ADJ]) and is stepped by the slope terrace wall
(177..277, 616..630) with its gap at x 277..309 (the laundromat corner); the
storm-gully trench sits on the slope below the wall.

### Callout -> coordinate index

| callout (real name) | canvas anchor |
|---|---|
| the Pitch / soccer yard (RED spawn) [CHOICE] | walled yard (54..250, 258..530); pedestal at (150,430); pitch markings floor-art in its south half, market carts in its north half |
| NW terrace stairs (the open column north of the green house, x 342..472, y 106..336) | stand (390, 220) |
| Top terrace + Hilltop shack | (594, 45) walk; shack (551..637, 63..158) |
| Upper back alley | y 158-218 band, x 342..932; east end descends the bar-arm gap (x 902..930); the nook (946..1000, 150..221) is blue-spawn cover, not a through-route |
| the Bar | (818, 265); interior + south yard |
| Yellow building | (582, 245) |
| the Crackhouse (tall landmark, overlooks the square) | body (467..540, 300..545); slit at (528, 500..533) |
| Green house | (397, 389) |
| Brickhouse | (386, 527) |
| Town square (engine center, flag ring) | (614, 561) |
| the Red House (courtyard house east of the square) | (690..852, 450..606) |
| Market / main street (shop strip) | WEST reach x 170..880, y 727..783 (stand (765, 765)); EAST reach x 880..1160, y 660..716 (stand (1000, 690)) — the street steps UP at the measured bend x~880; stalls on both |
| Laundromat / Barber / Ice cream shop | (384,673) / (556,680) / (765,682) |
| East court + kiosk | (920, 500) |
| Ladder building (tall landmark, enterable lobby) | strip (970..1067, 358..656) |
| the Garage | lobes at (1067..1121, 494..641) + (1121..1156, 527..577) |
| NE yard (BLUE spawn) | (1085, 222); east edge house (1156..1200, 230..266) |
| Back street (blue flank) | x ~1121..1208, y 310..660 |
| East reach + ramp + SE yard | (1000,690) / (960,780) / (1000,920) |
| South stairs + bottom landing | (686, 880) / (686, 1040) |
| Lower pocket + Junk row (SW pocket) | (800, 945) / (360, 865) |
| West nook + boulder | (100, 800) |

Measured-component provenance (Otsu components of the x3 plate):
comp 92 (457,201)-(918,558) = yellow building + crackhouse annex/body/wing +
terrace lip arm; comp 34 = hilltop shack; comp 96 = the bar; comp 98
(833,221)-(1158,658) = terrace-houses arm + ladder strip + north arm +
garage; comp 149 = red house; comp 180 (309,577)-(876,780) = the shop row;
comp 136 = green house; comp 153 = brickhouse; comp 133 = stair wall +
parapet; comp 91 = NE tin shack (relocated [ADJ] out of the blue pocket);
comp 179 = east court kiosk; comp 227 = junk row hut; comps
208/211/213/216/221/222/229/230 + the west-yard cluster = the market carts.

---

## 4. STRUCTURES

All rects are `MapRect(x, y, w, h)` canvas px. Solid unless an interior is
listed in the next table.

| structure | rect(s) | notes |
|---|---|---|
| hilltop shack | `(551, 63, 86, 95)` | top-terrace slots: west 26px [ADJ notch widened to x525], east 31px |
| yellow building | `(536, 196, 92, 105)` | top raised 201->196 [ADJ] (sightline alignment) |
| crackhouse annex | `(472, 246, 64, 54)` | fused to yellow building (no sub-24 slot) |
| crackhouse body | `(467, 300, 73, 245)` | measured SE corner reached (610,557) — 14px from engine center; the forced ring makes the cutback unavoidable [ADJ] |
| crackhouse east wing | `(540, 407, 124, 73)` | covers the center column at y 407-480; bottom face 81px from center (ring-safe) |
| green house | `(327, 336, 140, 106)` | touches the body (467) — sealed seam by design |
| brickhouse | `(333, 471, 106, 112)` | |
| west stair wall + parapet | `(254, 317, 28, 86)` + `(270, 403, 12, 180)` | comp 133, the west terrace step |
| terrace lip wall | `(740, 383, 177, 25)` | measured comp-92 east arm; lip gap 917..945 (28px) at its east end |
| red house | `(690, 450, 162, 156)` | west face 76px from center |
| laundromat | `(309, 611, 150, 125)` | |
| barber shop | `(485, 640, 143, 81)` | top 640 [ADJ from measured 577: ring]; west face 485 staggers the shop cut off the N-S column [ADJ] |
| ice cream shop | `(656, 640, 219, 84)` | |
| backalley bridge | `(690, 606, 34, 34)` | [ADJ] fuses red-house SW corner to ice-cream top: splits the shop back alley (anti-sightline) |
| the bar (hall + wings) | hall `(735, 218, 167, 50)`, west wing `(735, 268, 52, 44)`, east wing `(869, 268, 33, 44)` | measured south-face notch = the bar yard (787..869, 268..312) |
| terrace houses arm | `(930, 221, 40, 109)` | bottom at 330 (measured west-face alcoves y 301..331): opens the yard-stair dogleg |
| ladder building strip | `(970, 358, 44, 298)` + `(1014, 358, 53, 298)` | top at the MEASURED y 358; the 44px corridor x 970..1014 above it is blue's stair to the terrace band (load-bearing for fairness: ratio 0.585 -> 0.921) |
| ladder north arm | `(1014, 326, 131, 32)` | top 326 [ADJ]: blue pocket clearance (8px margin) |
| garage | lobe a `(1067, 494, 54, 147)`, lobe b `(1121, 527, 35, 50)` | lobe b trimmed [ADJ]: back-street pinch vs the SE diagonal measured 23px -> shipped 27px |
| east edge house | `(1156, 230, 44, 36)` | [ADJ] fused to the NE boundary: breaks the back-street N-S sightline; 1px east of the blue pocket |

### Interiors (5 enterable buildings + doors + windows)

Wall rings are 12px; every door is 26-28px. Interior floors:

```
crackhouse room  (479, 392, 37, 141)   red house room  (702, 462, 138, 132)
laundromat room  (321, 623, 126, 101)  barber room     (497, 652, 107, 57)
bar room         (747, 230, 143, 26)   ladder lobby    (982, 470, 73, 90)
```

```
DOORS = (467,440,12,26) crackhouse W -> plaza alley | (690,516,12,28) red house W -> square
        (780,594,12,28) red house S -> shop alley   | (380,611,26,12) laundromat back (N)
        (520,640,28,12) barber N -> square (through-shop cut square->street!)
        (806,256,28,12) bar S -> bar yard           | (970,500,12,26) ladder lobby W -> east court
        (1055,448,12,26) ladder lobby E -> garage yard (offset from W door: shoot-through lobby)
WINDOWS (window: true — shots pass, walk blocked):
        (528,500,12,33) crackhouse slit over the square (the famous overlook)
        (690,468,12,28) red house window over the square
        (321,724,126,12) laundromat shopfront | (497,709,119,20) barber shopfront+counter lip
        (668,712,195,16) ice cream shopfront+counter lip | (747,218,143,12) bar N window over the upper alley
```

### Shanties (small cover: stalls, carts, huts, low walls)

```
("diam",952,250,20)  NE tin shack (comp 91, relocated [ADJ])   ("diam",922,592,20)  east court kiosk (comp 179)
("rect",300,865,46,56) junk row hut (comp 227)                 ("rect",266,776,140,16) street stall row wall (comp 213)
("rect",352,765,44,18) street stall W                          ("rect",513,756,46,27)  street stall mid
("diag",660,764,696,788,t12) street stall (kink, comp 211)     ("rect",852,825,47,33)  apron stall A (comp 221)
("rect",696,843,49,36) apron stall B (comp 222)                ("rect",807,882,49,30)  apron stall C (comp 229)
("rect",875,890,62,26) pocket stall (comp 230)                 ("rect",906,660,64,20)  east reach stall (court mouth) [ADJ]
("rect",1130,460,28,28) back-street stall [ADJ]                ("diag",96,278,132,266,t12) yard cart A
("diag",180,300,214,316,t14) yard cart B                       ("rect",228,420,26,18)  yard cart C
("diag",230,500,254,524,t12) yard cart D                       ("diam",430,745,13)     main street planter
("disc",760,741,14) main street drum                           ("disc",120,800,12)     west nook boulder
("rect",177,616,100,14) slope terrace wall [ADJ]               ("diag",262,700,296,738,t14) slope cart (comp 193)
("rect",352,583,26,28) back-alley shed [ADJ]
```

Street stalls hug the street's south face / shopfront counters so every
remaining street gap is >= 24px. The five [ADJ] baffles (spur, buttress, east
edge house, shed, bridge, court-mouth stall, back-street stall) exist to break
sightlines the raw trace left open; each is placed on a measured jog or fused
to measured fabric.

Trenches (walkable dug pits, the drainage gully family kept from v1):

```
result.trenches = @[
  MapRect(x: 180, y: 640, w: 48, h: 80),   # storm gully on the SW slope, below the slope wall
  MapRect(x: 466, y: 731, w: 140, h: 24),  # gully along the main street west reach (clears the stalls)
  MapRect(x: 668, y: 880, w: 36, h: 60),   # soakaway pit in the south stairs
]
```

Props (art only): water tanks on the yellow building / crackhouse / bar /
laundromat roofs, pitch markings + goals painted in the yard's south half,
ladder art on the ladder building's west face, laundry lines over the back
alley. Collision comes ONLY from the masks.

---

## 5. OBJECTIVES

| field | value | rationale |
|---|---|---|
| `redHome` | `MapPoint(x: 150, y: 430)` | center of the walled pitch yard — the west muster ground |
| `blueHome` | `MapPoint(x: 1085, y: 222)` | the NE yard under the ladder-building terrace — the east muster ground |
| `redSpawn` | `MapRect(x: 60, y: 292, w: 110, h: 120)` | NW of the stand (deeper in the yard) — offset per the Afghan lesson (respawn waves must not materialise inside the capture circle) |
| `blueSpawn` | `MapRect(x: 1090, y: 160, w: 64, h: 130)` | NE of the stand, against the boundary; clears the east edge house |
| `spawnClearW/H` | **70 / 96** | pockets: red (80..220, 334..526), blue (1015..1155, 126..318). Verified: 0 wall px carved in either |
| `carveClear` | **-1** | **load-bearing.** The canvas edge is solid hillside on all four sides; forced always-floor home columns would punch corridors through the west warehouse mass and the east wall (sealed-pocket failures + boundary breaches). The spawn pockets alone guarantee spawnable floor — same argument as Afghan v2 |
| `captureRadius` | 64 | r64 around each home is verified open floor |
| `medKitSpawns` [CHOICE] | `MapPoint(x: 580, y: 600)`, `MapPoint(x: 920, y: 480)` | one on the town square's SW apron (the contested heart), one in the east court under the ladder lobby door — both multi-lane crossfire ground, neither team-owned |

Fairness (measured on the shipped rasters, engine carves applied, 13px-fit
floor, 4-connected BFS): **walk-to-midfield red 726 vs blue 669, ratio
0.921** (Afghan shipped 0.832); full red->blueHome walk 1437. Straight-line
distances 482 vs 580 — the walk numbers converge because blue's yard-stair
corridor (x 970..1014) is short and direct; **do not delete or narrow that
corridor without re-measuring fairness.** Homes are near-symmetric in x
(150 + 1085 = 1235 = width + 7). Integrator: run the walk-to-midfield BFS in
the fairness suite and nudge `blueHome` west along the yard (down to x 1060)
if blue measures slow; red is yard-locked. This layout is NOT a mirror —
assert the asymmetry test actually fires.

---

## 6. LANES

Three genuinely distinct west-east routes plus a south loop. Lane
centerlines are AUDITED against the saved masks: every waypoint is
13px-standable and every polyline pixel is on floor (the audit lives in the
session record; re-run it by checking these points against
`perimeter|blocks|windows|shanties`). Lanes 1 and 2 are distinct across the
whole midfield and merge only for the final yard entry (the terrace band ->
yard stair); blue's home approach has two mouths — the yard stair and the
back street — plus the spawn nook for cover.

**Lane 1 — the upper back alley (north, fastest):**
```
(150,430) -> (264,300) -> (310,300)       # yard slot (band x 247..342, y 282..317)
          -> (350,298) -> (365,270) -> (365,180)  # NW terrace column, northbound
          -> (450,170) -> (600,178)       # upper alley
          -> (640,188) -> (645,215) -> (680,240) -> (715,205)  # dogleg under the spur (x 628..664 down, back up east of 694)
          -> (880,190) -> (916,205)       # Bar-front reach, under the bar's north window; DEAD-ENDS at the buttress (932)
          -> (916,290)                    # descend the bar-arm gap (x 902..930)
          -> (916,335) -> (940,355)       # arm dogleg into the terrace band
          -> (985,345) -> (990,250)       # yard stair corridor (x 970..1014), northbound
          -> (1015,235) -> (1085,222)     # BLUE
```

**Lane 2 — plaza street / town square (center):**
```
(150,430) -> (264,300) -> (307,340)       # yard slot -> plaza street
          -> (307,450) -> (410,456)       # under-green band (y 442..471)
          -> (448,466) -> (453,510) -> (453,555)  # crackhouse alley (west door on it)
          -> (470,595) -> (545,595)       # back alley east -> square west entry
          -> (614,561)                    # TOWN SQUARE (flag ring)
          -> (677,520) -> (677,435) -> (700,430)  # square N exit -> red house north alley
          -> (880,425) -> (920,418) -> (931,396)  # around the lip wall's east end
          -> (940,370) -> (985,350)       # terrace band -> yard stair (shared with lane 1)
          -> (990,250) -> (1015,235) -> (1085,222)
```

**Lane 3 — the main street / market (south):**
```
(150,470) -> (150,505) -> (190,560)       # yard extension, onto the SW slope
          -> (250,595) -> (292,622)       # through the slope-wall gap (x 277..309)
          -> (260,660) -> (230,720) -> (250,756)  # down the slope past the cart, into the street
          -> (340,748) -> (400,758) -> (430,770) -> (460,765)  # west reach, threading planter + stalls
          -> (490,748) -> (575,740) -> (600,745) -> (700,748)
          -> (740,765) -> (790,765) -> (870,748)  # south of the drum, to the bend
          -> (910,700) -> (1000,690)      # the bend + east reach
          -> (1140,680) -> (1170,600)     # back street southern mouth
          -> (1190,480) -> (1195,330)     # back street north
          -> (1160,290) -> (1120,245) -> (1085,222)
```

**Lane 4 — the lower terrace loop (south flank connector):**
```
(640,760) -> (686,800) -> (686,900)       # south stairs (bottom landing lurk pocket below)
          -> (720,945) -> (800,945) -> (920,945)   # lower pocket (junk stalls)
          -> (1000,900) -> (1000,840) -> (975,760) -> (960,700)  # SE yard + ramp back to the east reach
```

Plus the through-shop cuts: barber (square <-> street), ladder lobby (east
court <-> garage yard), red house (square <-> shop alley), crackhouse (plaza
alley, slit overwatch), the bar (upper alley overwatch).

### THE ACCEPTANCE CRITERION — midfield alleys

The engine-center column (x = 614) crosses exactly **five** distinct floor
gaps, each its own named east-west route, separated by real fabric:

| # | gap (y) | width | what it is | separator below it |
|---|---|---|---|---|
| 1 | 32..63 | 31px | top terrace walk | hilltop shack |
| 2 | 158..196 | 38px | upper back alley | yellow building |
| 3 | 301..407 | 106px | mid terrace | crackhouse east wing |
| 4 | 480..640 | 160px | town square (flag ring) | barber shop |
| 5 | 729..784 | 55px | main street | street south face / south terrace block |

(The current in-game favela measures ONE 486px span here.)

### Chokepoint schedule

All corridors >= 24px floor (disc overreach + 13px player); measured vs
shipped:

| chokepoint | measured | shipped | how |
|---|---|---|---|
| yard east slot (band x 247..342, y 282..317) | ~32 | **35** (vertical clearance) | as measured |
| plaza street (stair wall vs green house) | 45 | **45** | as measured |
| crackhouse alley (brickhouse 439 vs body 467) | ~20 | **28** | body west face [ADJ] |
| under-green band (green bottom vs brickhouse top) | ~25 | **29** | green bottom 442 / brick top 471 [ADJ] |
| shop cut (laundromat 459 vs barber 485) | fused (<6) | **26** | barber west face [ADJ] |
| back alley (brickhouse bottom vs laundromat top) | fused (<6) | **28** | y 583..611 [ADJ] |
| junction alley (barber 628 vs ice cream 656) | 19 | **28** | [ADJ] |
| square N exit (wing 664 vs red house 690) | ~34 | **26** | wing east face aligned to the spur [ADJ] |
| red house north alley (lip wall 408 vs house 450) | 42 | **42** | as measured |
| lip gap (917..945) | 28 | **28** | as measured |
| bar-arm gap (902..930) | ~27 | **28** | |
| yard stair corridor (970..1014) | 44 | **44** | measured strip top y 358 restored |
| arm dogleg (arm bottom 330 vs lip band) | notched | **28+** | arm bottom at the measured alcove line [ADJ] |
| NE spawn nook (946..1000, 150..221) | — | **54**-wide yard-side pocket | new [ADJ] — spawn cover, NOT a through-route (the buttress+arm seal it from the alley) |
| upper-alley dogleg (yellow 628 vs spur 664) | — | **36** | new [ADJ] |
| slope-wall gap (wall 277 vs laundromat 309) | — | **32** | new [ADJ] |
| top terrace slots | ~18/31 | **26 / 31** | notch widened [ADJ] |
| back street pinch (garage lobe b vs SE diagonal) | 23 | **27** | lobe b trimmed [ADJ] |
| east reach south gap (court-mouth stall) | — | **36** | |
| south stairs shaft / SW pocket mouth | 19..26 / ~53 | **44 / 37** | shaft straightened + moved [ADJ] |
| main-street gaps at planter/drum/stalls | — | **>= 24** | stalls hug the south face / counters |
| all interior doors | — | **26-28** | |

### Invariant compliance (verified on the shipped rasters)

- **Forced carves chew nothing:** flag ring r70 = 0 wall px; red pocket = 0;
  blue pocket = 0.
- **No open cross-field rows/columns:** longest open row segment 474px (the
  mid-terrace walk, y 330) — map is 1228 wide; longest open column 494px
  (plaza street, x 302) — map is 1122 tall. Main street reaches capped at
  462px by the stall/planter/drum line and the measured street bend.
- **No sealed pockets, pickups on floor:** 13px-fit flood from `redHome`
  reaches blueHome, both medkits, all five interiors, the top terrace, NE
  yard, SW pocket, lower pocket, SE yard and the bottom landing; 0 stranded
  open-floor components. A 24px-corridor flood also connects both homes and
  every outdoor target. The bottom landing (664..708, 985..1091) is an
  intentional one-mouth lurk pocket (measured), open at its top.
- **Cover:** blocks+shanties = 22.5% of playable; playable = 58.0% of canvas.
- Regenerate + re-verify everything: `python3 tools/mw2_favela_v2_plan.py`
  (prints all checks, writes the masks, renders `/tmp/favela_plan_view.jpg`).

Verification renders for this plan: `/tmp/favela_plan_view.jpg` (verified by
eye AND re-audited programmatically against the saved masks: all four lane
polylines pixel-on-floor with standable waypoints, five midfield crossings,
spawns offset and wall-free, all three trench rects fully on floor).
Collision fitting: fit engine discs/rects to the four masks in
`docs/designs/mw2-reference/favela-v2-masks/` (<=4px overreach, Afghan v2
recipe); windows.png must become `window: true` shapes, not solid cover.
