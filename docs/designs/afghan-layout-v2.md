# Afghan layout v2 — measured rebuild plan

Status: layout plan for the integrating session. Supersedes the current in-game
`afghanCtfMap()` (1235x659). Fixes the two rejection causes: the C-130 was 90
degrees off, and the mountain ring + cave complex were missing entirely.

Provenance: every number below is MEASURED from the official 2009 overhead
(`docs/designs/mw2-reference/afghan.png`, 512x512) rotated into game space,
thresholded (Otsu T=115), component-labelled, Moore-traced and Douglas-Peucker
simplified. The transform from rotated-reference pixels (rx, ry) to THIS
canvas is:

```
canvas.x = round((rx - 36) * 3.0) + 123
canvas.y = round((ry - 61) * 3.0) + 78
```

(36/61 = the prep-tool playable frame origin; 3.0 = chosen scale; +123/+78
place the valley so the two flag homes sit symmetric about the engine's forced
center `(width/2, height/2)`.) Items marked [CHOICE] are creative decisions
where the reference is ambiguous; [ADJ] are deliberate small departures from
the measured footprint (usually to clear an engine carve zone or to widen a
chokepoint to playable width).

---

## 1. CANVAS

**`width = 1460, height = 1400`** [CHOICE]

- Real Afghan's playable frame is near-square (435x415 px in the rotated
  reference, aspect 1.05). The current 1235x659 canvas squashed it 1.9x
  vertically, which is what amputated the mountain ring and south riverbed.
- Scale 3.0 px-canvas per px-reference keeps the same linear scale the other
  MW2 plates use horizontally (1235/435 = 2.84), so structure footprints and
  engagement ranges feel like the rest of the pack.
- The valley content spans x 81..1398, y 93..1347; the remaining band out to
  the canvas edge is solid mountain (min band: 53 px at the south spur, 62 px
  at the east bowl). Nothing playable touches the canvas edge.
- Engine center is `(730, 700)`; the center flag ring r70 sits in open
  crash-site floor (nearest obstacle: massif west foot at ~110 px, plane tail
  at ~83 px) — **no forced carve chews any structure**.
- Keep `gunRange = 1300`, `captureRadius = 64`, `captureClear = 210`,
  `flagRing = 70` (all verified compatible with this layout).

---

## 2. ORIENTATION DECISION

**Plate rotation.** The game-space plate is the original image rotated **90
degrees counter-clockwise** (PIL `rotate(90)`, as in `tools/mw2_ref_prep.py`).
Compass mapping:

| original (2009 map, north up) | game space |
|---|---|
| north (OpFor spawn, compound) | **west — RED end** |
| south (TF141 spawn, sandbag ring) | **east — BLUE end** |
| east (the ridge + bunker) | **north wall** |
| west (cliff road, low riverbed) | **south flank** |

**The C-130.** In the original image the fuselage lies roughly east-west
(tail west at orig (219,212), nose east at orig (330,234) in 512-space). After
the 90-CCW plate rotation that axis becomes **north-south in game space**:

> **The wreck runs NORTH-SOUTH. The nose section is the NORTHERN piece and
> points NORTH, leaning ~9 degrees toward east (heading 009). The tail lies
> at the SOUTH end of the debris chain.**

The current in-game placement (props at y≈290-300 spanning x 289..748,
nose at the east end) runs the plane east-west along the mid-line — exactly
the 90-degree error the owner flagged. Rotate the whole prop chain 90 degrees
(nose from "east" to "north") and move it to the crash site west of the cave
hill. Measured piece placements are in section 4.

Why the bug happened: the plane reads "horizontal" on the original minimap,
and the old trace kept it horizontal — but the *plate* is rotated 90 degrees,
so everything traced from the *original* orientation must rotate with it.

---

## 3. THE TERRAIN RING

The valley is fully enclosed. **Fill the entire canvas with mountain
(wall), then carve the valley floor as the polygon below.** This one polygon
is the measured inner face of the whole mountain ring (74 pts, canvas px,
clockwise from the north-east rim; simplification eps = 15 canvas px):

```
VALLEY_RIM = [
  (1185,93),(1209,156),(1251,129),(1275,210),(1170,267),(1245,495),
  (1380,498),(1344,555),(1398,501),(1380,720),(1362,723),(1338,675),
  (1302,678),(1281,714),(1197,720),(1194,984),(1101,1017),(1095,1059),
  (951,1044),(915,1086),(897,1185),(717,1260),(693,1329),(642,1347),
  (615,1302),(615,1170),(552,1155),(483,1185),(441,1143),(363,1137),
  (309,1164),(291,1020),(261,993),(180,984),(147,948),(141,855),
  (195,828),(297,831),(315,741),(249,732),(237,702),(315,636),
  (213,609),(207,624),(204,558),(105,540),(81,507),(87,447),
  (147,342),(168,339),(171,381),(231,378),(267,402),(285,387),
  (267,342),(300,291),(444,303),(471,330),(522,297),(573,297),
  (579,321),(534,366),(441,372),(423,393),(426,489),(465,507),
  (474,588),(498,600),(576,393),(705,375),(738,294),(864,210),
  (1065,162),(1182,96)
]
```

Named wall segments (indices into VALLEY_RIM, real callouts):

| segment | rim points | what it is | approx wall width to canvas edge |
|---|---|---|---|
| **The Ridge** (north wall) | 69..74, 0 | orig-east ridge; the bunker is carved into it at (585,261)-(756,363) | 90..300 px |
| **NE corner alcove** | 0..4 | notch where the canyon meets the ridge | 90 px |
| **Canyon east wall / NE massif** | 4..5 | rim face x≈1170..1245 forming the east canyon with the cave hill's NE lobe | 150+ px |
| **Bowl rim** (east wall behind BLUE) | 5..9 | TF141 plateau backwall | 62..115 px |
| **Bowl SE cutback** | 9..14 | measured notch; keeps the bowl from being a half-open box | — |
| **East leg wall** | 14..15 | west-facing wall of the ledge corridor, x≈1197..1209, y 720..984 | 250 px |
| **Stepped retaining walls** (SE) | 15..20 | the man-made stepped edge above the riverbed | 260 px |
| **South rim / cliff road** | 20..30 | orig-west cliff road wraps outside this face (art band, out of bounds) | 53..250 px |
| **SW spur pocket** | 22..25 | overlook pocket at (615..693, 1260..1347); Dom-A marker sits here | — |
| **West wall + shack pockets** | 30..48 | rim weaves around the west-edge shacks; incl. the dotted cliff-edge pocket (81..105, 447..540) | 80..140 px |
| **NW corner / compound backwall** | 48..55 | the OpFor compound sits against this | 90..340 px |
| **Rock pier ("the Tongue")** | 60..67 | measured peninsula (423..534, 366..600) hanging off the north wall; splits the RED field from the bunker forecourt | attached to ridge |
| **Bunker forecourt face** | 67..69 | rim face y≈375..393 under the bunker | — |

[ADJ] widenings to the rim (playability, see chokepoint table in section 6):
pull rim point (315,741)→(270,741) (shack alley); drop the stepped-wall face
between x 900..1100 south to y≥1130 (SE strait).

### The central massif ("the Hill")

One measured island — cave hill, hilltop and south-hill lobes are a single
connected rock mass (verified by labelling). Fill as wall (73 pts, eps 12):

```
MASSIF = [
  (1080,360),(1131,369),(1194,447),(1194,510),(1152,552),(1155,639),
  (1125,660),(1125,630),(1152,636),(1149,552),(1191,510),(1188,468),
  (1176,507),(1125,555),(1107,630),(1119,681),(1176,723),(1194,888),
  (1125,894),(1128,918),(1176,918),(1164,966),(1086,993),(1071,1038),
  (975,1038),(978,1020),(1044,1029),(1065,987),(1161,954),(1155,921),
  (1122,921),(1122,885),(1170,882),(1173,741),(1140,819),(1095,798),
  (1047,813),(1062,876),(1044,897),(1026,897),(990,756),(951,744),
  (936,807),(957,873),(927,933),(930,1008),(915,1026),(885,1032),
  (816,972),(753,957),(678,900),(648,918),(603,1011),(621,1056),
  (603,1110),(498,1101),(501,1065),(468,1026),(546,951),(666,906),
  (765,783),(870,741),(900,690),(903,636),(879,615),(876,516),
  (810,501),(837,414),(903,366),(981,387),(1011,417),(1026,384),
  (1077,363)
]
```

[ADJ] massif trims: NE lobe east face to x≤1155 for y 405..560 (canyon);
east face to x≤1130 for y 700..830 (ledge corridor); SE foot to y≤1000 for
x 950..1100 (SE strait); merge the SW-rocks group (below) into the SW lobe
so the two <15 px micro-straits beside it read as one rock group.

### THE CAVE COMPLEX [CHOICE within the measured dotted footprint]

The reference draws the covered (dotted) region on the massif's SE quarter at
**(903,576)-(1137,744)**; the north notch and the west/east face concavities
are measured inlets in the massif polygon. Carve out of the massif:

- **Footprint rect:** `MapRect(x: 903, y: 576, w: 234, h: 168)`
- **Main chamber (floor):** `MapRect(x: 925, y: 590, w: 200, h: 140)`
- **West mouth** (opens onto the crash site): portal
  `MapRect(x: 875, y: 620, w: 50, h: 40)` — carved through the measured west-face
  concavity at x≈876..903.
- **East mouth** (opens onto the bowl-SW / ledge junction): portal
  `MapRect(x: 1125, y: 650, w: 50, h: 50)` — through the east face at x≈1125..1155.
- **North leg** (to the crates field, via the measured notch inlet at
  (981,384)-(1026,417)): passage polyline, 36 px wide:
  `(1000,590) -> (975,500) -> (990,415)`, exiting portal
  `MapRect(x: 975, y: 384, w: 45, h: 30)`.
- **South ravine** (open-air, NOT cave): the measured dark inlet at
  (885..960, 800..1030) stays an open notch from the riverbed up to the cave's
  south wall — a grenade-lob / sound approach, no through passage. [CHOICE]

Interior passage route (the "C" of the real cave), 40 px corridor width:
```
CAVE_ROUTE = [(900,640),(975,660),(1065,695),(1150,675)]
```

### Other rock islands (fill as wall)

```
WEST_CENTRAL_ROCK = [  # the rock outcrop west of the crash site
  (465,615),(510,630),(528,657),(498,819),(447,861),(393,861),
  (378,849),(381,816),(345,789),(336,762),(342,735),(369,723),(462,618)
]
SW_ROCKS = [  # merge with massif SW lobe per [ADJ] above
  (396,972),(447,990),(435,1011),(456,1059),(423,1083),(435,1113),
  (357,1119),(336,1074),(348,1050),(336,1023),(345,978),(393,975)
]
```

### Callout -> coordinate index

| callout (real name) | canvas anchor |
|---|---|
| The Cave | chamber center (1025, 660) |
| The Bunker | (670, 312) |
| The Ridge | north wall, y≈300 band, x 300..1100 |
| Crash site / the Plane | (665, 620) |
| The Hilltop (red-smoke Stinger hill) | massif crown (1000, 800) — wall; art-only smoke plume prop |
| The Riverbed / wadi | south bowl (720, 1140) |
| The Compound (OpFor/RED spawn) | (210, 470) |
| TF141 plateau (BLUE spawn) | (1251, 598) |
| The Canyon (east flank) | (1215, 300)..(1220, 480) |
| The Ledge | corridor (1165, 750)..(1180, 950) |
| SW Overlook spur | (655, 1300) |
| Cliff road | out-of-bounds art band along the south-west rim |

Note: the three pale circles in the reference at (1251,599), (853,1145),
(669,1315) are the 2009 Domination A/B/C **icons, not terrain** — exclude
them from any auto-trace. Same for the dotted lines (they mark covered areas).

---

## 4. STRUCTURES

All rects are `MapRect(x, y, w, h)` canvas px, measured unless marked.

### The C-130 wreck (position + heading per section 2)

Debris chain axis: nose tip (735, 435) -> tail end (676, 810); heading 009
(9 degrees east of true north). Pieces (walls + matching props, sprites
rotated 90 from their current east-west orientation):

| piece | rect | notes |
|---|---|---|
| nose section | `MapRect(x: 678, y: 432, w: 69, h: 99)` | pointed end north; sits under the bunker's overlook |
| forward fragment | `MapRect(x: 579, y: 444, w: 30, h: 51)` | broken-off door/panel west of the nose |
| cargo/debris square | `MapRect(x: 603, y: 525, w: 27, h: 30)` | between nose and mid section |
| mid fuselage + wing box | `MapRect(x: 579, y: 567, w: 111, h: 108)` | the big section; wings stub east-west |
| engine debris x4 [CHOICE] | discs r14 at (537,588), (513,634), (717,600), (741,648) | two per side, perpendicular to the new N-S axis |
| tail cone | `MapRect(x: 666, y: 723, w: 21, h: 87)` | |
| tail fin (fallen) | `MapRect(x: 561, y: 726, w: 81, h: 123)` | lies beside the tail, angled ~120 deg |
| scorch/furrow (art only) | streak from (690, 850) to (740, 540) | crash direction: it slid north |

### The Bunker (carved into the north Ridge wall)

- Interior floor: `MapRect(x: 585, y: 261, w: 171, h: 102)`
- Room divider wall at x 660..672, y 261..330 (leaves a 33 px interior door
  at the south end) — the reference draws it as two rooms.
- **West door:** carve `MapRect(x: 567, y: 300, w: 18, h: 40)` to the NW pocket
  floor at (534..579, 300..366).
- **South embrasure** (the overlook over the nose): carve
  `MapRect(x: 630, y: 363, w: 60, h: 30)` through the rim face. Make this
  strip a `window: true` shape 18 px deep if a firing-slit feel is wanted;
  plain floor gap otherwise. [CHOICE]
- **East door:** carve `MapRect(x: 756, y: 315, w: 18, h: 40)` to the crates
  field. (Engine has no roofs — the real bunker's covered interior is lost;
  the three-mouth room still plays like a bunker.)

### RED end — the Compound (OpFor spawn)

| structure | rect | notes |
|---|---|---|
| compound wall A (north run) [ADJ] | `MapRect(x: 168, y: 330, w: 111, h: 42)` walls 12 thick, gate gap x 210..240 in south face | measured at y 339..405; shifted north 33 so the spawn pocket does not carve it |
| ruin B block + hut | polygon `[(369,348),(390,405),(339,417),(321,399),(321,357)]`, hut `MapRect(x: 333, y: 366, w: 42, h: 36)` | measured id3 |
| thin wall W1 [ADJ +6x] | `MapRect(x: 294, y: 450, w: 18, h: 120)` | the two long qalat ruin walls east of the plaza |
| thin wall W2 | `MapRect(x: 378, y: 450, w: 21, h: 93)` | |
| plaza wall bits [ADJ, moved out of pocket] | `MapRect(x: 150, y: 590, w: 50, h: 18)`, `MapRect(x: 250, y: 585, w: 18, h: 40)` | measured at (162..207,516..537)/(237..276,537..579) |
| west shack C1 [ADJ +20y] | `MapRect(x: 117, y: 575, w: 45, h: 30)` | |
| west shack C2 [ADJ +12y] | `MapRect(x: 168, y: 573, w: 39, h: 72)` | |
| south hut D | `MapRect(x: 168, y: 615, w: 57, h: 45)` | tilted in reference; axis-align is fine |

### Mid-field and BLUE end

| structure | rect | notes |
|---|---|---|
| crates row (Ridge field) | `MapRect(x: 855, y: 279, w: 54, h: 27)` | measured id2 |
| **burnt tank** [CHOICE] | `MapRect(x: 1029, y: 276, w: 42, h: 57)`, rot ~30 | measured tilted vehicle-size block id1; this is the pack's burnt-armor set piece |
| wadi ledge wall | `MapRect(x: 243, y: 951, w: 153, h: 15)` | low wall at the west wadi entrance (id39) |
| sandbag V (wadi) | `MapRect(x: 642, y: 1074, w: 66, h: 45)` | id44 |
| sandbag T (wadi) | `MapRect(x: 783, y: 1011, w: 33, h: 48)` | id42 |
| sandbag rect (wadi) | `MapRect(x: 750, y: 1110, w: 45, h: 21)` | id45 |
| sandbag T south | `MapRect(x: 645, y: 1155, w: 54, h: 39)` | id47 |
| sandbag arc at BLUE (props only) | arc (1263,564)-(1308,651) | id19 — inside the spawn pocket, so visual props only |
| sandbag collision arcs at BLUE [ADJ] | `MapRect(x: 1180, y: 702, w: 70, h: 18)`, `MapRect(x: 1262, y: 702, w: 68, h: 18)` | the ring's fighting cover, placed just south of the pocket so it survives the carve |

Trenches (walkable, existing trench mechanic):

```
result.trenches = @[
  MapRect(x: 390, y: 885, w: 140, h: 56),   # the wadi, west reach
  MapRect(x: 700, y: 1150, w: 160, h: 56),  # the wadi, mid reach (Dom-B field)
  MapRect(x: 1000, y: 1078, w: 140, h: 56), # the wadi, SE reach under the stepped walls
  MapRect(x: 685, y: 760, w: 56, h: 56),    # forward foxhole at the tail
]
```

---

## 5. OBJECTIVES

| field | value | rationale |
|---|---|---|
| `redHome` | `MapPoint(x: 210, y: 472)` | center of the compound plaza — where OpFor musters in the real map |
| `blueHome` | `MapPoint(x: 1251, y: 598)` | the measured 2009 Domination-C circle on the TF141 plateau, inside the sandbag ring |
| `redSpawn` | `MapRect(x: 135, y: 397, w: 150, h: 150)` | |
| `blueSpawn` | `MapRect(x: 1176, y: 523, w: 150, h: 150)` | |
| `spawnClearW` / `spawnClearH` | **80 / 96** | pockets: red (130..290, 376..568), blue (1171..1331, 502..694). Structures above are placed/[ADJ]-shifted so neither pocket carves a wall; blue pocket clears the massif east face by 6 px and the bowl rim by 13 px |
| `carveClear` | **0** | **load-bearing.** The old 96-px always-floor columns would punch floor corridors through the west and east mountain walls (x<96 and x>1364 are solid mountain here), creating sealed-pocket invariant failures and ring breaches. Homes sit ~130 px inside the ring; the spawn pockets alone guarantee spawnable floor. If the engine cannot take 0, any value <=24 keeps the strips fully inside mountain — but then those strips must be excluded from the sealed-pocket scan. |
| `medKitSpawns` [CHOICE] | `MapPoint(x: 1025, y: 660)`, `MapPoint(x: 805, y: 1150)` | one INSIDE the cave chamber (the map's contested heart), one in the open wadi between the sandbags and the massif — both on every-lane crossfire ground, neither owned by a team |

Symmetry note: homes are symmetric about center-x by construction
(210 + 1251 = 1461 = width + 1). Straight-line home->center distances are
568 (red) vs 531 (blue), a 7% gap — but blue's straight line is blocked by
the massif while red's crash-site corridor is near-straight, so BFS walk
distance is the number that matters. **Integrator: run the walk-to-midfield
BFS check (per the asymmetric-map fairness suite) and nudge `blueHome` east
up to (1290, 598) if blue measures short; do not move red — its pocket is
wall-locked.** Also assert the asymmetry test actually fires (this layout is
NOT a mirror).

---

## 6. LANES

Four genuinely distinct ways across. Polylines are lane centerlines in canvas
px; min corridor widths after the [ADJ] widenings are listed below.

**Lane 1 — the Ridge / Bunker route (north):**
```
(210,472) -> (330,430) -> (480,560) -> (498,600)   # around the Tongue tip
          -> (560,430) -> (585,330)                 # NW pocket, bunker west door
          -> [through bunker] -> (774,335)          # east door
          -> (885,300) -> (1050,280)                # crates field, burnt tank
          -> (1215,300) -> (1220,480)               # the Canyon
          -> (1245,540) -> (1251,598)               # drop into the bowl
```
(Bunker can be bypassed south of its embrasure through the forecourt at
y≈380, under its guns — the real map's trade-off.)

**Lane 2 — Crash site / the Cave (center):**
```
(210,472) -> (330,510) -> (450,590)                 # thin-wall alley
          -> (555,620) -> (665,620)                 # through the wreck pieces
          -> (730,700)                              # center flag ring
          -> (900,640) -> (975,660) -> (1065,695)   # the Cave (west->east)
          -> (1150,675) -> (1200,640) -> (1251,598) # bowl SW junction
```
Sub-route 2b [CHOICE]: cave north leg (990,590) -> (975,500) -> (990,415)
pops out at the notch into the crates field — links Lane 2 to Lane 1
mid-map (the real cave's third mouth).

**Lane 3 — the Riverbed / wadi (south):**
```
(210,472) -> (250,620) -> (290,780)                 # shack alley
          -> (390,920) -> (560,940)                 # west wadi channel + trench
          -> (700,1080) -> (853,1145)               # sandbag field (Dom-B ground)
          -> (1000,1050) -> (1120,1000)             # SE strait under stepped walls
          -> (1180,900) -> (1175,760)               # the Ledge, northbound
          -> (1220,700) -> (1251,598)               # bowl south entrance
```

**Lane 4 — the Ledge crossover (east, connects 2 and 3):**
```
(1150,675) -> (1170,760) -> (1180,950) -> (1120,1000)
```

Chokepoint schedule (all [ADJ] values already reflected in sections 3-4):

| chokepoint | measured gap | shipped gap | how |
|---|---|---|---|
| Canyon (NE lobe vs rim) | 39 px | **>=78** | trim lobe east face to x<=1155, y 405..560 |
| SE strait (massif foot vs stepped walls) | ~20 px | **>=90** | massif foot y<=1000 (x 950..1100) + rim face y>=1130 (x 900..1100) |
| Tongue tip vs west-central rock | ~15 px | **>=75** | Tongue tip y<=555; rock north face y>=630 |
| shack alley (rim bulge vs rock west face) | ~25 px | **>=75** | rim (315,741)->(270,741) |
| Ledge corridor (massif east face vs east-leg wall) | 33 px | **>=80** | massif east face x<=1130, y 700..830 |
| west wadi micro-straits beside SW rocks | 9-12 px | **closed** | merge SW_ROCKS into the massif SW lobe (no sealed pocket results; the SW spur opens north into the bowl) |

Invariant compliance:
- **No full-width open row:** every horizontal line crosses at least one of
  {west rim pocket, compound A, the Tongue, the massif, the bowl rim} —
  verified against the measured polygons; longest open row segment is the
  crates field (~420 px), well under map width. No open column exists (ridge
  and south rim cap every column).
- **No sealed pockets:** requires `carveClear = 0` (see section 5) and the
  SW-rocks merge above. The bunker interior has three mouths; the cave has
  three; the SW spur opens north.
- **Pickups on occupiable floor:** both medkits and all four trenches sit on
  carved floor >=28 px from any wall face.
- Run the 1-px flood fill from `redHome` and assert it reaches `blueHome`,
  both medkits, the bunker interior, the cave chamber, and the SW spur.

Verification renders used for this plan: `/tmp/afghan_plan_full.png`
(canvas-scale overlay of rim + massif + placements + lanes) — regenerate via
the measurement pipeline in this doc's provenance note if the reference or
scale changes.
