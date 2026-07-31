# Highrise layout v2 — measured rebuild plan

Status: layout plan for the integrating session. Supersedes the current in-game
`highriseCtfMap()` (1235x659). Keeps that map's strengths — homes inside real
glass-walled interiors (its 61% interior enclosure is the best in the pack),
`captureRadius: 64`, spawn zones distinct from homes — and adds what it lacks:
the measured two-tower rooftop footprint, the tower-gap seam, the real interior
room plans, and the south girder-walk flank.

Provenance: every number below is MEASURED from the official 2009 overhead
(`docs/designs/mw2-reference/highrise.png`, 512x512) rotated into game space
per `tools/mw2_ref_prep.py` (rot=90 CCW, frame (0.050, 0.270, 0.940, 0.710)),
then line-art thresholded (luma > 230 isolates the minimap's white wall
outlines cleanly — the plateau in the threshold sweep sits at 215..225),
morphologically split into horizontal/vertical/diagonal runs, and transcribed.
The transform from rotated-reference plate pixels (px, py) — equivalently
original-image pixels (ox, oy) — to THIS canvas is:

```
canvas.x = px * 3 + 16  =  (oy -  25) * 3 + 16
canvas.y = py * 3 + 12  =  (373 - ox) * 3 + 12
```

(25/138 = the prep-tool crop origin in rotated space; 3.0 = chosen scale;
+16/+12 center the 1368x675 content in the canvas so the content center
(700, 349) coincides with the engine's forced center `(width/2, height/2) =
(700, 350)` to within 1 px.) Items marked [CHOICE] are creative decisions
where the reference is ambiguous; [ADJ] are deliberate departures from the
measured footprint (to clear the flag ring, widen a door to playable width,
or break an illegal sightline). Measured wall centerlines are 2 plate px
(6 canvas px); all walls are authored 12 px thick centered on the measured
centerline unless noted.

**Raster masks (source of truth):**
`docs/designs/mw2-reference/highrise-v2-masks/{boundary,walls,glass,fixtures}.png`
(1400x700 single-channel, wall=white; README there has semantics + white-pixel
counts + the regen command). The tables below are the same geometry in
Nim-transcribable form; if they ever disagree, the rasters win.

---

## 1. CANVAS

**`width = 1400, height = 700`** [CHOICE]

- Real Highrise's playable frame is a wide landscape strip: 456x225 in the
  rotated reference, aspect 2.03. The canvas aspect is 2.00 — no squash.
  (This map is the pack's shape-outlier in the opposite direction from Afghan:
  keep it wide, don't square it.)
- Scale 3.0 canvas px per reference px, matching Afghan's plate scale, so
  footprints and engagement ranges feel like the rest of the pack.
- Content spans x 16..1384, y 12..687; the remaining band to the canvas edge
  is the parapet/sky border (16 px sides, 12/13 px top/bottom). Nothing
  playable touches the canvas edge.
- Engine center is `(700, 350)`; the center flag ring r70 sits in the open
  "flag court" between the seam's south mouth and the offices penthouse —
  **nearest solid is 72 px** (the seam's SE lip at (770, 330)); no forced
  carve chews any structure. The AC pipe and the seam's measured south-west
  wall stub were [ADJ]-trimmed to make this true.
- Keep `gunRange = 1300`, `captureRadius = 64`, `captureClear = 210`,
  `flagRing = 70` (verified compatible; same values as the current map).

---

## 2. ORIENTATION DECISION

**Plate rotation.** Game space is the original image rotated **90 degrees
counter-clockwise** (PIL `rotate(90)`, exactly `tools/mw2_ref_prep.py`).
Compass mapping:

| original (2009 map, north up) | game space |
|---|---|
| north (machine-room tower, upper complex) | **west — RED end** |
| south (offices/helipad tower, lower complex) | **east — BLUE end** |
| east (city drop behind the north parapet) | **north edge** |
| west (crane side, window-washer ledge) | **south edge** |

Every structure below is stated in GAME orientation (the Afghan plane lesson:
nothing is traced in original orientation and left unrotated). Explicit
game-space orientations of the majors:

- **West office core (machine room + suite):** rooms run N-S along the west
  end; its main door faces EAST onto the mid deck.
- **The seam** (the gap between the two towers): runs **NORTH-SOUTH** at
  x 742..829 — in the original it is the horizontal construction cut across
  the map's middle. The gantry crosses it at the NORTH edge.
- **Offices penthouse:** long axis EAST-WEST (x 484..1039), chamfered bow at
  its WEST end, chevron tip pointing EAST.
- **Tilted skylight:** axis SW-NE, from (610, 255) to (682, 185) (~44 deg).
- **Girder walk:** runs EAST-WEST along the whole SOUTH edge, outside the
  parapet walls (in the original this is the map's west-face ledge).
- **Crane:** overhangs the SOUTH edge west of mid-field (measured jib
  diagonals enter the frame at canvas x ~470..650); jib art points NE onto
  the deck. **Helipad:** the open SE deck of the east tower.
- End identity (the asymmetry the pack test must see): **RED end = machine
  rooms + office suite + crane/scaffold side; BLUE end = glass offices +
  atrium + helipad.** As in the real map, the two ends share no layout.

---

## 3. THE ROOFTOP BOUNDARY

Highrise's edges are building edges: parapet, then sky/city drop. **The border
reads as a solid parapet ring** — fill everything outside the content frame
(and the strips below) as wall; the wall texture over the border band is the
parapet coping, not masonry mass. `boundary.png` is this layer, verbatim:

| piece | rect `MapRect(x,y,w,h)` | what it is |
|---|---|---|
| border ring | N `(0,0,1400,12)`, S `(0,688,1400,12)`, W `(0,0,16,700)`, E `(1384,0,16,700)` | parapet coping / sky |
| north solid above corridor | `(346,12,75,48)` | city drop behind the west corridor |
| north solid W | `(421,12,240,90)` | city drop; mid-deck N wall fronts it |
| north solid above gantry | `(646,12,264,45)` | void the gantry bridges over |
| north solid E | `(895,12,204,90)` | city drop |
| NE corner solid | `(1099,12,45,132)` | drop beside the tower vestibule |
| east tower N band | `(1144,12,240,27)` | drop behind the tower N wall |
| raised roof (sealed balcony) | `(1207,39,135,72)` | measured walled roof, no doors in the reference — solid [MEAS] |
| raised roof NE plant | `(1321,39,63,120)` | measured pale plant roof — solid [CHOICE] |
| SW void under west tower wall | `(16,681,405,19)` | drop below the tower S wall |
| W parapet tie-back S | `(16,516,42,24)` | [ADJ] breaks the spawn-deck alley column (see section 6) |
| W parapet tie-back N | `(16,270,41,24)` | [ADJ] same |
| solid above landing | `(421,102,33,33)` | [ADJ] seals a measured dead sliver |
| void strip W of rig bay | `(466,615,165,48)` | the drop between parapet wall and girder walk |
| void strip E of rig bay | `(922,615,162,48)` | same, east side |
| void under rig bay | `(646,663,261,37)` | forces the girder walk THROUGH the rig bay |
| void under girder walk | `(418,687,766,13)` | sky below the girders |

**`carveClear = -1` (no forced always-floor columns) — load-bearing.** The
current map needed 96 because its traced mask kept the outer sixths clear; in
v2 the outer columns are parapet ring, the red spawn deck, and the east tower
rooms. A forced floor column at either edge would punch through the parapet
ring (sealed-pocket/ring-breach failures) and chew the tower rooms. Homes are
interior and the spawn pockets alone guarantee spawnable floor. If the engine
build cannot take -1, use 0; there is no value >= 16 that does not carve the
border ring.

---

## 4. STRUCTURES

All rects `MapRect(x, y, w, h)` canvas px; `DG(x0,y0,x1,y1,t)` = shapeDiagonal
with thickness t; `D(cx,cy,r)` = disc; `DM(cx,cy,r)` = diamond. Everything is
[MEAS] unless tagged. Door widths are stated where a wall is split.

### 4.1 West tower — RED end (the machine-room core + office suite)

The current map's "office core west". Interiors are real rooms; the pale
west band (x 16..262 north, narrowing to x 16..106 beside the suite) is the
open RED SPAWN DECK.

| structure | shapes | notes |
|---|---|---|
| north corridor | W wall `(346,60,12,30)` + `(346,120,12,108)` (door y 90..120, 30 px [ADJ] — links deck to corridor, the real stair link), top `(346,60,75,12)`, E wall `(409,60,12,177)` | green-floored corridor (352..409, 72..213) |
| NE landing | N wall `(406,135,63,12)` | alcove (421..454, 147..228) off the deck door |
| machine room shell | N `(259,228,81,12)` + `(406,228,63,12)`, W `(262,228,12,195)`, S stub `(259,408,54,12)`, E = deck W wall below | interior (274..454, 240..408); RED core |
| machine rm N door | stubs `(322,213,39,12)` + `(388,213,36,12)` | door x 361..388 (27) [ADJ shifted onto the boiler axis to kill an interior enfilade] |
| deck W wall (the core's east face) | `(454,102,12,48)` + `(454,225,12,270)` | **main east door y 150..225 (75 px)** onto the mid deck |
| machine interior | stubs `(325,261,12,81)`, `(325,372,12,51)`; boilers `D(376,322,15)`, `D(378,404,12)` | the two measured round units |
| office suite shell | N `(103,399,168,12)`, W `(106,399,12,189)`, S `(157,585,177,12)`, E dbl `(316,438,12,117)` + `(319,561,12,39)` | suite entrance x 307..328 at y 405..444; S door x 334..415 (81) |
| suite interior | `(103,435,36,12)`, mid wall `(160,435,12,186)` + `(160,648,12,33)` (door y 621..648, 27), bars `(157,456,45,12)` `(238,456,39,12)` `(178,471,150,12)` `(178,486,87,12)` `(157,513,171,12)` `(238,537,90,12)`, rack `(127,483,27,48)` | the measured desk/partition plan; **redHome room is (172..316, 525..585)** |
| SW deck | W wall `(31,570,12,111)`, N wall `(31,573,111,12)`, S wall `(28,669,393,12)` | the tower's south service deck |
| suite/deck E wall | `(409,477,12,138)` + `(409,645,12,36)` | [ADJ] door y 615..645 (30) links the S deck to the girder-walk approach (measured dead-end fixed) |
| spawn-deck furniture | skylight housing `(57,423,46,48)` [MEAS skylight symbol, raised as cover [CHOICE]] | breaks the alley sightline with the tie-backs |

### 4.2 Mid deck — the shared roof

| structure | shapes | notes |
|---|---|---|
| deck N parapet | `(454,102,207,12)` + `(892,102,207,12)` | city drop behind |
| **gantry** (N bridge between towers) | N wall `(643,57,270,12)`, W `(646,57,12,57)`, E `(895,57,12,57)` | bay (658..895, 69..102), open south into the deck; crosses the seam |
| **the seam** (tower gap / tunnel cut) | W wall `(742,57,12,33)` + `(742,120,12,156)`; E wall `(817,57,12,33)` + `(817,120,12,66)` + `(817,213,12,126)`; SE lip `(770,324,59,12)` | corridor (754..817, 69..339), opens N into the gantry (doors y 90..120 both sides, 30 [ADJ from measured 21]), E door y 186..213 (27 [ADJ]), S mouth wide open into the flag court. Measured SW stub (y 297..351) deleted [ADJ] — it sat inside the flag ring |
| stairhead block | `(829,150,39,69)` | the measured closet pair at the seam's tunnel stairs, solid [CHOICE] |
| vent housing | `(487,114,64,105)` | [ADJ] flushed to the N parapet (sightline) |
| tilted skylight | `DG(610,255,682,185,34)` — GLASS | the big angled light over the offices below |
| AC pair + pipe | `(532,321,72,45)`, pipe `(598,336,30,12)` | pipe [ADJ] shortened out of the flag ring |
| planters | `(652,252,48,24)` [ADJ moved out of ring], `(466,336,24,36)` [ADJ, W margin] | |
| crane set piece | pad `DM(520,392,16)`, pallet `(575,382,30,22)` on deck; mast `(560,621,44,42)` + counterweight `(516,627,38,30)` anchored ON the S void; jib/cables/hook = ART props angling NE from the mast across the SW corridor | measured jib diagonals enter at x ~470..650 S; there is no deck room for a collision jib without eating measured structure — identity is carried by the void-anchored mast + art [CHOICE] |
| NE vent row | `(907,114,90,78)` [ADJ flushed N], long wall `(910,156,12,198)`, rack `(880,276,45,96)` [ADJ +18 S, sightline] | the NE quadrant's spine |
| NE skylight box | `(937,252,120,66)` — GLASS | the measured pale square |
| small dorito | `DM(827,207,15)` | measured tilted object |
| hoist crate | `(936,368,40,55)` | [ADJ] breaks the court's E-W row; flush to penthouse N face |
| water tank | `D(923,481,16)` + barrel `D(949,502,10)` | inside the penthouse inner office |

### 4.3 Offices penthouse (the central structure, x 484..1039)

Shell: N `(544,423,174,12)` + `(760,423,111,12)` + `(901,423,108,12)`
([ADJ] whole N face shifted +6 south of measured so the flag ring clears it;
**N door x 718..760, 42 px**; NE door x 871..901, 30 px), S `(541,540,219,12)`
+ `(784,540,228,12)` (**S door x 760..784, 24 px — deliberately staggered
east of the N door** [ADJ]: the measured aligned pair made a 582 px
court-to-bay enfilade), NW chamfer `DG(544,429,520,462,12)`, SW chamfer
`DG(496,525,541,555,12)`, E chevron tip `DG(1012,429,1036,477,12)` +
`DG(1012,552,1036,507,12)` (tip door y 477..507, 30 [ADJ from measured 18]).

Interior: W tip room walls `(484,462,12,63)`, `(484,462,78,12)`,
`(484,513,78,12)`, `(550,462,12,18)` + `(550,507,12,18)` (E door y 480..507);
penthouse skylight `(580,453,78,48)` — GLASS; inner office (the glass suite)
N `(781,441,60,12)` + `(868,441,108,12)` (door x 841..868, 27 [ADJ]),
S `(763,513,66,12)` + `(856,513,120,12)` (door x 829..856, 27 [ADJ]),
W `(676,435,12,33)` + `(676,498,12,42)` (door y 468..498, 30 [ADJ]),
mid `(784,453,12,18)` + `(784,501,12,12)` (door y 471..501, 30 [ADJ]),
E inner wall `(964,441,12,84)`; exhaust housing `(800,552,36,51)` [ADJ,
against the S face — breaks the S corridor row].

### 4.4 South edge — parapet, rig bay, girder walk

| structure | shapes | notes |
|---|---|---|
| parapet walls | `(454,603,207,12)` + `(892,603,207,12)` | the deck's S edge |
| **window-washing rig bay** | W wall `(646,603,12,24)`, E wall `(895,603,12,24)`, S wall `(643,651,270,12)` | the measured S balcony (658..895, 615..651); opens N into the deck; W/E doors y 627..651 (24) pass the girder walk THROUGH it [ADJ — the measured straight ledge gave a 963 px sightline]; rig platform/panel props = art |
| **girder walk** | floor strip y 663..687, x 418..646 and x 907..1184, between the void strips | the exposed S flank, 24 px wide by design; entered W via the (421..466) approach, E under the S junction, mid through the rig bay |

### 4.5 East tower — BLUE end (offices, atrium, helipad)

| structure | shapes | notes |
|---|---|---|
| N wall + vestibule | `(1129,39,93,12)`, vestibule N `(1081,132,66,12)`, S `(1081,228,87,12)` ([ADJ +15 wide, seals a 9 px slit]), W wall upper `(1084,99,16,45)` | vestibule (1099..1132, 144..228), W mouth open to the deck (84 px) |
| tower W wall main | `(1087,225,12,264)` | S gap y 489..570 = the deck's south entrance |
| long spine walls | N `(1132,36,12,132)` + `(1132,195,12,99)` (**vestibule door y 168..195, 27 [ADJ — measured wall was solid; the vestibule was a sealed dead-end and the tower had one effective mouth]**), S `(1132,420,12,75)` + `(1132,522,12,60)` (**S-room door y 495..522, 27 [ADJ, same reason]**) | |
| stair chambers (W face) | alcove walls `(1081,324,66,12)`, `(1081,384,66,12)`, `(1081,480,66,12)` (measured 4th at y 264..276 deleted [ADJ] — it sealed a cell on all four sides) | cells open E into the W corridor |
| offices | N wall `(1162,228,120,12)` + `(1306,228,78,12)` (door x 1282..1306, 24), W corridor wall `(1171,279,12,90)` + `(1171,393,12,33)` (door y 369..393, 24 [ADJ]), desk island `(1168,333,42,27)` [ADJ −12 for a 30 px passage], curved desk `DG(1216,150,1246,168,10)` + `DG(1244,166,1264,198,12)` | **blueHome room is the S office (1183..1273, 372..411)** |
| atrium | N wall `(1204,261,48,12)`, W wall `(1240,258,12,57)`, **well `(1270,261,96,120)` — GLASS** | the sunken skylight well; see-through, not walkable |
| S office walls | `(1168,411,48,12)` + `(1243,411,63,12)` (door x 1216..1243, 27 [ADJ]), room walls `(1273,372,12,51)`, `(1333,372,12,51)` | |
| helipad boundary | N wall `(1174,444,144,12)` + `(1342,444,27,12)` (door x 1318..1342, 24 [ADJ from measured 15]), W wall `(1177,441,12,141)` | |
| S junction | `(1081,570,111,12)`, `(1084,570,12,48)`, scaffold `DG(1150,621,1180,651,12)` | funnels walk <-> helipad <-> deck |
| **helipad deck** | open (1189..1384, 456..687); parapet stubs `(1192,663,84,12)` + `(1306,663,78,12)`; H circle r72 at (1284,566) = ART | BLUE spawn ground |

Trenches (walkable, existing mechanic):

```
result.trenches = @[
  MapRect(x: 757,  y: 132, w: 54, h: 138),  # the seam tunnel dig
  MapRect(x: 573,  y: 300, w: 84, h: 54),   # deck expansion joint, west court
  MapRect(x: 1100, y: 618, w: 45, h: 45),   # girder-walk east foxhole
  MapRect(x: 996,  y: 352, w: 54, h: 54),   # NE deck foxhole
]
```

Art-only props (no collision): crane jib + cables + hook, rig platform
panels, helipad H + circle + windsock, seam plank textures, floor skylight
paint on the red deck, girder track texture.

---

## 5. OBJECTIVES

| field | value | rationale |
|---|---|---|
| `redHome` | `MapPoint(x: 244, y: 552)` | inside the office suite's SE room — a real interior, like the current map's in-core homes |
| `blueHome` | `MapPoint(x: 1205, y: 390)` | inside the east tower's south office, beside the atrium |
| `redSpawn` | `MapRect(x: 75, y: 45, w: 150, h: 150)` | the NW spawn deck — offset ~380 px from redHome |
| `blueSpawn` | `MapRect(x: 1195, y: 500, w: 150, h: 150)` | the helipad — offset ~195 px from blueHome; opposite corner from red, as in the real map |
| `spawnClearW` / `spawnClearH` | **70 / 130** (current values) | both pockets sit on open deck; neither carve touches a wall (red deck is clear x 16..262 above y 12; helipad clear below y 500) |
| `carveClear` | **-1** (0 if the engine refuses) | see section 3 — any forced column breaches the parapet ring |
| `medKitSpawns` [CHOICE] | `MapPoint(x: 782, y: 200)`, `MapPoint(x: 770, y: 585)` | one in the seam tunnel (the contested heart), one at the rig-bay mouth on the south flank — both on every-lane ground, neither owned; measured clearances 29/30 px |

Fairness (measured on the masks, 4-connected BFS on walkable floor):
**redHome -> center 702, blueHome -> center 755 (7.0% gap)**; spawn-center ->
center 1070 (red) vs 971 (blue), 9.7%. Straight-line home symmetry is
meaningless here (walk distance is the number that matters — see the
asymmetric-map fairness suite). **Integrator: re-run the BFS check on the
built map; if blue measures short/long by >10%, slide `blueHome` within the
south office (1183..1273, 372..411) or `redHome` within (172..316, 525..585);
do not move the spawn zones — both are corner-locked like the real map.**

---

## 6. LANES

Four genuinely distinct ways across, plus the seam as the N-S connector.

**Lane 1 — Gantry / north wall:**
```
(150,120) -> (380,90) corridor door -> (390,180) -> (460,190) deck door
          -> (600,150) vent-housing gap -> (770,85) gantry bay (bridges the seam)
          -> (950,200) NE deck -> (1050,170) -> (1115,185) vestibule
          -> (1150,180) spine door -> (1170,210) north hall -> (1294,234) office N door
```

**Lane 2 — Flag court (center):**
```
(244,552) -> (370,600) suite S door -> (437,545) SW junction -> (500,450) crane pad field
          -> (630,390) court -> (700,350) FLAG -> seam S mouth (785,300) or
          penthouse N door (739,429) -> (940,390) hoist-crate gap -> (1093,320) tower W chambers
```

**Lane 3 — Penthouse interior:**
```
(437,545) -> SW chamfer -> W tip room (523,493) -> skylight side (700,480)
          -> inner office doors (854,480) -> chevron tip door (1024,492)
          -> (1060,545) SE deck -> tower S entrance (1093,530) -> S-room door (1138,508)
          -> blue S office (1205,390)
```

**Lane 4 — Girder walk (south flank, high risk):**
```
(437,600) approach -> (430,675) walk W run -> rig bay W door (652,639)
          -> rig bay (770,630; medkit) -> E door (901,639) -> walk E run (1000,675)
          -> S junction (1140,640) -> helipad (1284,566) = blue spawn back door
```

**Seam connector (N-S):** gantry bay (770,85) -> seam doors -> tunnel trench
(782,200; medkit) -> E door (823,200) to NE deck -> S mouth -> flag court.

Chokepoint schedule (all [ADJ] values already in section 4):

| chokepoint | measured gap | shipped gap | how |
|---|---|---|---|
| seam N doors (both walls) | 21 px | **30** | door y 90..120 |
| seam E door | 21 px | **27** | y 186..213 |
| machine-rm N door | 27 px | 27 (moved) | x 361..388, on the boiler axis |
| penthouse N/S doors | 33 / 33 aligned | **42 / 24 staggered** | N x 718..760, S x 760..784 |
| chevron tip door | 18 px | **30** | y 477..507 |
| office W-corridor door | 18 px | **24** | y 369..393 |
| desk-island passage | 18 px | **30** | island shrunk to w 42 |
| office N door | 24 px | 24 | x 1282..1306 |
| helipad N door | 15 px | **24** | x 1318..1342 |
| tower spine doors | 0 (sealed) | **27 / 27** | y 168..195, y 495..522 |
| suite/deck E door | 0 (sealed) | **30** | y 615..645 |
| rig-bay walk doors | n/a (new) | **24** | y 627..651 both walls |

Invariant compliance (all measured on the shipped masks by
`highrise-v2-masks/gen_masks.py` — regenerate after any edit):

- **Asymmetry >= 15%:** mirror IoU of the solid mask (left half vs flipped
  right half) is **0.313 -> 68.7% asymmetric** — this layout cannot pass as a
  mirror (the pack once caught a 6.6% near-mirror Highrise; v2 is structurally
  end-distinct: machine rooms + crane vs offices + atrium + helipad).
- **Fairness alongside it:** home->center walks 702 vs 755 (7.0%), spawns
  1070 vs 971 (9.7%) — asymmetric ends, near-equal races (section 5).
- **No sealed pockets:** exactly **1** walkable floor component; the measured
  layout had five sealed cells/dead-ends (E tower vestibule, spine, alcove
  cell, W tower S deck, landing sliver) — all resolved by the tagged [ADJ]
  doors above, every interior has >= 2 mouths except the NE landing alcove
  (1-mouth by real design, 33x81 px, scan-exempt as an alcove not a pocket).
- **No open cross-field rows/columns:** longest open row segment 477 px
  (y 675 — the girder walk + helipad, the deliberate exposed flank; next
  worst 470), longest open column 489 px (x 1042, and it is through the NE
  skylight GLASS — a sightline, not a walk line). Both < 0.35 of canvas
  width; nothing crosses the field.
- **Flag ring:** 0 solid or glass px inside r70 of (700,350); nearest
  obstacle 72 px.
- **Pickups on occupiable floor:** medkits 29/30 px clear of any blocking
  face; all four trenches on open floor.
- Run the 1-px flood fill from `redHome` and assert it reaches `blueHome`,
  both medkits, the gantry bay, the seam tunnel, the penthouse interior, the
  rig bay, both girder-walk runs, the machine room, and the helipad (the
  generator script's probe list does exactly this — all 16 probes pass).

Verification render for this plan: `/tmp/highrise_plan_view.jpg` (canvas-scale
color composite: boundary/walls/glass/fixtures + homes, spawns, medkits, flag
ring, trenches, helipad art) — regenerate via `gen_masks.py` if anything
changes.
