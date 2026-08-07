# Hex Arena Conversion — Plan

> **SUPERSEDED IN PART, and kept because four source files cite it as the
> design authority** (`hex.nim`, `sim_types.nim`, and the two generator
> modules). It was written as a PROPOSAL and its section numbers are still the
> right references for *why* the geometry is what it is; it is no longer an
> accurate account of what shipped. Read it with this note:
>
> | The plan says | What shipped |
> |---|---|
> | "hex REPLACES square entirely" | True for the arena. The campaign board's hex tiles shipped separately and are unrelated to the playfield. |
> | "3-team and 6-team modes are added" | **Neither exists.** `symRot120`/`symRot60` need the cube-space orbit rasterizer (Stage 2b) and 6 teams need the `Team` enum widened (Stage 4). Both refusals are pinned by `tests/test_three_team.nim` and `tests/test_six_team.nim`. |
> | 4-team via Klein-four | Shipped as GEOMETRY only. The generator emits 2-team boards; 4 teams are reachable through the hand-authored `arena-hex4` / `arena-hex4-giant` boards, which are bare. |
> | portrait board | Flipped to LANDSCAPE (flat-top, 1119×969). Several depth and range constants were re-derived rather than carried over — see `arena.nim`'s `homeDepthWindow`. |
>
> For what actually landed and what it cost: `docs/HEX_SHIP_GATE.md`,
> `docs/HEX_SILENT_FAILURES.md`, and `docs/HEX_BLAST_RADIUS.md`.

**Status:** proposed, 2026-08-04
**Decision:** hex REPLACES square entirely (no dual geometry path). Arena + the
Paintbot campaign board. 3-team and 6-team modes are added.
**Companion plan:** `2026-08-04-map-generator-rebuild.md` (the generator that
fills the hex arena is a separate epic and a separate track).

---

## 0. The five findings that constrain everything below

These came out of the audit and each one kills an obvious approach. Read them
before reading the stages.

### 0.1 `symRot90` cannot survive the move. C4 is not a hex symmetry.

The hexagonal point group is D6 = {C1, C2, C3, C6} × reflections. **C4 is not a
subgroup of D6** (crystallographic restriction), so the entire `symRot90`
machinery — `rot90Point`, `rot90Quarter`, `rot90TeamPoint`, `rot90Orbit`,
`layoutCorners`, `layoutPlus` — has no hex analogue and is deleted, not ported.

For **4 teams on a hex** the correct group is the **Klein four-group**
V₄ = {e, mirror₀°, mirror₉₀°, rot180}. It has order 4, is a subgroup of D6, and
acts freely and transitively on 4 spawn points.

**DECIDED 2026-08-04: keep `4ffa`, on V₄.** The kernel work settled the open
question. V₄'s pixel action is `(x,−y)`, `(−x,y)`, `(−x,−y)` — precisely the
isometries a square pixel lattice *also* admits exactly. `hexEdgeDist` is
therefore **bit-identical** under all four V₄ operations over a full-board sweep,
asserted in `tests/test_hex.nim` as exact float equality. So 4-team hex loses **no
fairness whatsoever**; it is exactly as fair as the rot90 boards it replaces.

The only real cost is **handedness**: two of the four teams see a mirror-image
world, so a learned route flips chirality for them. That is a policy-side cost,
not a map-fairness cost. Three consequences to hold:

- Audit `spawnAimBrads` — 32 aim slots must behave sanely across a mirror
  boundary, and the existing per-layout facing table assumes rotation.
- Anything that bakes in a turn direction (serpentine, `arcStandoff`'s diagonal
  retreat, lane-side preferences in `players/baseline`) must be checked for
  chirality assumptions, not just for coordinates.
- The generator must not produce chirally-biased terrain (e.g. every snake
  winding the same way), or the mirror pair inherits a systematically different
  map feel even though the geometry is exactly fair.

**4-team spawns are not at 90°.** V₄ carries a seed at angle *t* to
`{t, −t, 180−t, 180+t}`, so gaps alternate `2t` and `180−2t` and are equal only at
*t* = 45°, which is not a lattice direction. `spawnSeed` takes the nearest free
lattice cell (ring 12 → ±43.90°, gaps 87.8°/92.2°, identical for every team).
Seeding on a lattice axis instead would give each team one close and one far
neighbour, which is worse.

### 0.2 Exact fairness requires authoring in axial/cube coordinates.

`rot90` is an exact integer bijection on ℤ²: `(x,y) → (side-1-y, x)`. That
exactness is the codebase's entire team-fairness proof — see `arena.nim:267-277`
and the refusal at `arena.nim:51-54` to allow a non-square rot90 board *precisely
because* it "would silently produce team-unfair obstacle images".

**rot60 and rot120 are not integer-exact on a square pixel lattice** (sin 60° =
√3/2 is irrational). Rotating in floats and rounding reintroduces exactly the
failure the existing validator refuses to permit.

**Therefore: obstacles are authored in cube coordinates `(q,r,s)`, `q+r+s=0`,
where rot60 is the exact integer permutation `(q,r,s) → (-r,-s,-q)`, and the
symmetry orbit is walked in cube space and rasterized to pixels ONCE.** Never
rotate pixels. This is non-negotiable and it dictates the shape of the new
`ArenaShape` type.

### 0.3 3-team and 6-team fairness forces a near-square board.

Any group transitive on 3 or 6 spawns contains a 120° rotation, which confines
the bounding-box aspect to **[0.866, 1.155]**. Our standard board is **1.874**.
Exact 3/6-team fairness on a 1235×659 canvas is **impossible**.

Equal-area hexagon for the standard class: **969 × 1119**. Every size class needs
re-deriving. Do not "fix" this by anisotropically stretching the lattice — an
affine stretch is not an isometry and silently breaks per-team travel times.

### 0.4 6-team spacing needs a giant board or a shorter gun.

Adjacent-base separation on an N-ring is `2·f·R·sin(π/N)`. For N=6 that reduces
to `f·R` — the worst case of any team count. With bases at 0.75·R you need
**R ≥ 1400**, i.e. a **2425×2800** board (5.09 Mpx, the giant class), for adjacent
bases to sit at least one gun range (1050px) apart. At R=600 adjacent bases are
**450px** apart, which is cross-ring spawn sniping.

**Decision: `6ffa` ships on the giant size class only.** Revisit only with a
mode-specific `gunRange`.

### 0.5 6 teams breaks two compile-time sprite/object pool asserts.

Both fire at build time (good — loud, not silent):

- `EndzoneFadeObjectBase = 39700`, `MaxEndzoneFadeBands = 64`. At 6 teams
  `39700 + 6·64 = 40084 > DebugObjectBase = 40000`. Fix: drop
  `MaxEndzoneFadeBands` to 48, or relocate `Debug`/`Stain` bases.
- The packed block `FlagSpriteBase=700`, `FlagAuraSpriteBase=704`,
  `PlantedFlagSpriteBase=708`, `GameOverIconSpriteBase=712` — four team-indexed
  pools at stride 4. All four bases must be re-laid out at stride 6 (716..819 is
  free, needs 24).

Also: `array[Team, …]` widening changes `gameHash` → **GameVersion bump → all six
`.bitreplay` fixtures re-record**. And `bin/*` are stale committed arm64 binaries
— **rebuild `bin/ctf-server` before re-recording or you will record the old
geometry.**

---

## 1. Sequencing constraint

`maxwell/preferred-team-colors` froze the 8-slug palette, the wire-word set
(`red|blue|green|yellow`), and 13 golden resolver vectors **today**. 6 teams
requires two more wire words → `ColorPayloadVersion: 2` + regenerated goldens +
`COLOR_CONTRACT.md` §1/§2/§5 amendments.

**Land the color branch first. Then Stage 5 treats the wire-word extension as a
deliberate versioned amendment, appending to palette entries 4–7 — never
reordering (the webpage repo vendors that array and its order IS the fallback
walk order).**

Retro-palette constraint: `teal` maps to retro index 9; **`purple` has no retro
equivalent**. Pick the two new wire words from `{teal, magenta, orange}` where a
retro index exists, or add retro entries.

---

## 2. Stages

Stages 1–3 are the geometry core and are strictly ordered. Stages 4–8 fan out.

### Stage 1 — Hex coordinate kernel (blocks everything)
New module `src/ctf/hex.nim`. Pure, no globals, wasm32-audited (`int` is 32-bit
on wasm; the existing `int64` discipline in the diagonal test and the `uint64`
cast in `trenchRoughEdge` are the precedent).

- Cube/axial types + conversions to pixel space. **Orientation is a dual pair and
  both halves are frozen: lattice CELLS are flat-top, the ARENA hexagon is
  pointy-top** — a hexagonal region of flat-top cells is itself pointy-top, which
  is why §0.3's board is portrait. `lattice()` sizes a radius-N lattice so its
  hull lands exactly on the arena outline, so the boundary needs no fairness
  argument separate from the lattice's.
- **Angles are in the SCREEN frame** (+x toward +y), because `cubeToPixel` emits
  y-down pixels. Quoting a mirror axis in a conventional y-up frame silently
  yields the wrong mirror with no error; each of the six axes is pinned by a
  fixed-point probe test.
- The exact integer symmetry operators: `rot60`, `rot120`, `rot180`, the three
  mirror axes; the D6 subgroup table; orbit walkers for N ∈ {2,3,4,6}.
- `insideHex(x, y)` / `hexEdgeDist(x, y)` — **one predicate, six half-planes.**
- Size classes re-derived at aspect ∈ [0.866, 1.155]; standard = 969×1119.
- Property tests: every operator is an exact bijection on the lattice; orbits
  close; `insideHex` agrees with `hexEdgeDist > 0` on every pixel of a board.

### Stage 2 — Geometry: shapes, symmetry, boundary
- `ArenaShapeKind`: **delete `shapeRect` and `shapeDiamond`** (neither is closed
  under 60° rotation). Keep `shapeDisc` (rotation-invariant) and `shapeDiagonal`
  (its point-to-segment math at `arena.nim:801-825` is already angle-general —
  60° chevrons work today). Add `shapeHex` (center + circumradius + orientation)
  and an oriented `shapeBar` (center + half-extents + angle) to replace rects.
- `MapSymmetry`: `symMirrorHex | symRot180 | symRot120 | symRot60 | symKlein4`.
- `TeamLayout`: `layoutHex2 | layoutHex3 | layoutHex4 | layoutHex6`.
- Replace the rectangular border test with `hexEdgeDist(x,y) < ArenaBorder` in
  **all four parallel wall predicates** — `mapWallAt` (`arena.nim:1110`),
  `isArenaWall` (`:2699`), `mapObstacleWallAtF` (`:2782`), `mapShapeWallAtF`
  (`:2802`) — plus the three `isProtectedFloor` copies (`:2658`, `:1069`,
  `:2722`). These must stay pixel-identical; add a test that sweeps a whole board
  asserting agreement.
- Endzones: **go all-disc.** `ezDisc` is the one geometry that is already
  rotation-invariant, already tested, and needs zero art work. Delete `ezColumn`
  and `ezSquare`; add `ezHex` only if a sector zone proves necessary.
- New label token for the hex/sector endzone in `LabelEndzoneShapes` — and
  **kill the `else: LabelEndzoneShapeColumn` fallthrough** at
  `global.nim:3193-3208`, which would otherwise tell every policy that the entire
  bounding box scores.

### Stage 3 — Sim & perception
Ordered by the audit's silent-failure ranking:

1. **Grenade spawns become unreachable.** `sim.nim:15-34` puts them at the four
   bbox corners at inset 50 — deep in the hex void — and `sim.nim:106-107` says
   outright they are *never nudged*. Derive from hex geometry (6 vertices) **and**
   route them through `placeWalkablePickups`.
2. **Rect clamps project into the void.** `throwTarget`/`throwGrenade`
   (`sim.nim:1210,1228`) and `randomEndzonePosition` (`sim_state.nim:288`). Note
   `explodeGrenade` has **no line-of-sight test**, so a lob into the void still
   damages through the map edge.
3. **Slide fails on a 60° wall below a speed threshold.** `slideScanRadius`
   (`sim.nim:219-226`) returns 1 at walking speed, which only tries a 45°
   diagonal; a 60° edge needs offset 2. Movement feel becomes speed-dependent on
   exactly the new geometry. Floor the scan at 2.
4. Respawn: reject on walkability as well as `inCaptureZone`; `nearestWalkable`
   can currently walk an accepted point back out of the zone.
5. Re-base `GrenadeMaxRange` / `ShoutRange` off playfield extent, not bbox width
   (they inflate ~15% on a hex).
6. FOV: the `walls*2 >= pixels` downsample leaks through staircased 60° edges.
   Mark the whole out-of-hex void opaque and assert it.
7. `game teams <n> map <W>x<H>` now states a bounding box, not the playfield. The
   walkability sprite remains the only channel carrying true shape. Decide and
   document which is authoritative.

### Stage 4 — 3/6-team modes
`Team` grows by 2 (append only). `roster.nim`'s `slot mod teamCount()` is already
generic. `sim.nim`'s win/wipe/capture/elimination logic is already N-team
generic — **the sim is genuinely well-factored here and needs almost nothing.**
The work is: enum + `teamText` + `teamColor` + the two color `case`s + the sprite
pool relayout (§0.5) + manifest variants.

Seat plans (`MaxPlayers = 32`): `3ffa` = 15 or 18 (**not** 16 — 16 % 3 = 1 deals
6/5/5); `6ffa` = 24 or 30. **`6ffa8` = 48 seats does not fit.**

Decide explicitly: **pot scoring is not zero-sum at 3 or 6 teams.**
`teamCount div loserTeams` truncates (3÷2=1, 6÷5=1), so 3 teams pays +3/−1/−1 =
+1 and 6 pays +6/−1×5 = +1. (4 teams already rakes +1 today.) Either accept the
rake as intentional or switch to an exact split.

### Stage 5 — Color contract v2
Two new wire words appended to palette entries 4–7, `ColorPayloadVersion` 1→2,
`scripts/resolve_reference.py` re-run, `tests/resolver_vectors.json` regenerated,
`COLOR_CONTRACT.md` §1/§2/§5 amended, `chrome_common.js` `TEAM_ORDER`/`TEAM_COLOR`
/`otherTeam()` extended. **After the color branch merges.**

### Stage 6 — Rendering & art
The single highest-leverage change: **replace `floorDistDir`'s 4-axis ray metric
with a real Euclidean distance transform, and derive the light from `∇d`.**
`rooftopColorAt` (`map_art.nim:213-268`) currently quantizes the surface normal
into two buckets ({up,left} lit / {down,right} shaded), which is exactly right for
a rectilinear world and collapses a hexagon's six face normals into two tones. An
EDT + gradient fixes all six faces, fixes the pre-existing 45°-chevron parapet
bug, is *cheaper* than the ray version at scale=2, and makes the shader
lattice-agnostic. It benefits `rooftopColor`, `windowGlassColorAt`, and
`rotatingDiamondPixels` at once.

**Correction, measured 2026-08-05.** An earlier draft of this plan said the
chevron parapet was √2 **too wide**. It is too **narrow**, and the sign matters
for anyone reasoning about hex faces. A ray *overshoots* the true perpendicular
distance by `1/cos θ`, so a 45° face reaches each band threshold at `1/√2` of the
perpendicular distance an axis face needs — the band closes *early*. Measured
perpendicular cut through an arena chevron arm at scale 2, before → after:
ink 2→2, parapet 3→4, lip 1→2, total **6 px → 8 px** — exactly the rim an
axis-aligned rect already wore. The same sign applies on a hex board: every 60°
face would otherwise wear a rim `cos 30° ≈ 0.87` of the correct width, i.e.
thinner, not thicker.

Also: a distinct **void material** for the out-of-hex corners (code, not an
asset — they would otherwise render as a vast flat roof); a hex-periodic
`data/arena_floor.png` honoring the lum 66/34 glow contract with
`emberThroughCracks`; minimap uniform scale + dynamic aspect + hex outline
replacing the `W/2` midline + a void palette entry.

**Free win, independent of hex:** `replay_broadcast.html:1698` hard-codes
`BOARD_ASPECT = 1235/659` and **never syncs it** — `league_replayer.html:359-364`
already has the correct `syncBoardAspect`. This already misrenders square 4-team
boards today. Port it now.

`map_art.nim:4` states nothing here is in `gameHash` — **the entire art bake can
change freely without invalidating replays.** Biggest de-risking fact in the
audit.

### Stage 7 — Campaign board → hex
Owner located: **`Metta-AI/metta`, `app_backend/src/metta/app_backend/v2/campaign/`.**
⚠️ The local metta checkout is on an old branch and does not contain these files;
work from a fresh branch off `origin/main`.

- `engine.py:29-36` `neighbors()` — the **single source of truth** for adjacency;
  4 offsets → 6. `frontier()` and the order validator both route through it.
- `strategist.py:33` — the prompt hard-codes "ADJACENT (up/down/left/right)" in
  English. The LLM general will otherwise plan on a square board.
- `CampaignBoard.tsx:361-366` — a *second*, hard-coded 4-neighbour flood fill for
  territory labels; plus `:258-259, 1889-1899, 2150-2161` square geometry, → hex
  SVG cells.
- Board is a JSONB doc in `League.commissioner_state` (`state.py:19-47`), cells
  keyed `"x,y"`, row-major arrays in `routes/campaign.py:192-216`. Choose: keep
  offset coords with hex adjacency (smaller diff) or move to axial. **Live boards
  cannot be resized** (`runner.py:325-336`) — a hex board is a new campaign.
- Note the board is **12×12 by default**; the observed 10×10 is a per-league
  stored setting. Modes are derived from the coworld's variant mix
  (`episodes.py:144-155`), so **adding `3ffa`/`6ffa` variants automatically
  changes the campaign's cell-mode distribution.** Coordinate the two epics here.
- Tests exist: `test_campaign_engine.py` (18), `_runner` (25), `_episodes` (28),
  `_routes` (20), `CampaignBoard.test.*` (18).

### Stage 8 — Tests, tools, fixtures, docs
Ordered per the blast-radius audit:

1. `tests/helpers.nim` first — `openField`/`blockAll`/`segmentBlocked`/`fovAt` are
   what every terrain test builds on.
2. Rewrite the geometry tests: `test_mapgen`, `test_map_los`, `test_windows`,
   `test_shot_exposure`, `test_fov`, `test_endzone_shapes`, `test_four_team`,
   `test_trenches`, `test_map_editor_core`, `test_render_scale`, `test_medkits`,
   `test_spinning_diamonds`. Add `test_three_team` / `test_six_team` modeled on
   `test_four_team`. Extend `test_sprite_collisions` to 6 teams (it is the
   pool-collision regression suite).
3. Regenerate `tests/fixtures/map-validation-baseline.tsv` (402 rows) and
   `PoolRenderHashes`.
4. **Rebuild `bin/ctf-server`**, then re-record all six `.bitreplay` fixtures on
   an idle machine and re-pin the asserted winner/ending in
   `test_broadcast_state.nim` (the seed→ending map is a property of the rules).
5. `tools/`: rewrite `map_editor` (+ its 3 browser files — the API's
   `xLo/xHi/yLo/yHi/diag` vocabulary cannot express a hex zone), `map_render`
   (keep its purity invariant — the editor serves from a mummy thread pool),
   `dump_map_mask` (**external contract** — `daveey/cogamer` pins
   `decoder-gv<N>-<sha>`; version the format and re-release), `mapkit`,
   `gen_map_pool`, `four_team_map_probe`, `render_map_pool`,
   `build_pool_review.py` (its width→name dict `KeyError`s on any new size).
6. `players/baseline/baseline.nim` — ~81 geometry refs, hard-codes `MapW=1235`,
   and `homeDeepX()` still carries the scarred `MapW * 150 div 1235` literal.
   It is the canary for every deployed policy.
7. Docs: `RULES.md` (the four-team section and the endzone-marker table are
   published policy contracts), `ENV_VARIATION.md` (**same-change obligation per
   AGENTS.md**), `PROTOCOL.md:95`, `MAPKIT.md`, `designs/map-editor.md`, README,
   `REPLAY_DESIGN.md`; supersede the three old plan docs.
8. Add the hex knob to **both** coworld manifests — `coworld_manifest.json` has
   `additionalProperties: false` and no `teams` key today, so a knob missing there
   is unreachable in production.

---

## 3. Explicit non-goals

- Movement stays **continuous pixel-space**. No discrete hex-cell movement — that
  would rewrite `PROTOCOL.md`, break every league policy, and invalidate the
  entire doctrine ledger.
- The wire format does not change shape. Coordinates stay absolute pixels in a
  bounding box.
- The MW2 map pack (branch `maxwell/mw2-paintball-maps`, not on HEAD) is **not**
  migrated here. Decide separately whether it dies or gets a second migration.

## 4. Proof obligations (borrowed from the compact-endzone landing)

- `tools/dump_map_specs.nim` sha1 diff before/after every generator-adjacent
  change. Fix its strip list first — it is the migration's proof instrument.
- Every symmetry operator asserted an exact bijection, in cube space.
- The four wall predicates asserted pixel-identical over a full board sweep.
- Per-team fairness (`b_a`, `b_e`, `b_s`) asserted **exactly 1.000** under exact
  symmetry — any deviation is a pipeline bug, classically a repair pass run on
  the assembled map instead of on the fundamental domain.
- Eyes-on screenshots on both delivery paths (native server + wasm bundle).
</content>
</invoke>
