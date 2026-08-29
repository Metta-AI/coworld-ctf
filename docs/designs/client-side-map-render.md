# Client-side map render from mapSpec (design only — not built)

## The problem this kills permanently

Steps 1-3 of the pixel-pipe fix (see server.nim's needsReregister comment,
global.nim's `addMapBands`/`blockAverageRgba`, and player_client.html's
`scheduleDraw` coalescing) all reduce or reschedule the cost of shipping a
**baked RGBA image** of the arena. That image is still, at minimum, a
multi-megabyte one-time payload per human connection (measured: 3.99 MB
post-snappy for the real BR arena at the current block factor). Every one of
those bytes exists only because the server rasterizes the map to pixels and
ships the pixels.

The mapSpec that already describes the arena is **kilobytes**: the real BR
board (`/tmp/br-scout/maps/ctf-spec-1337.json`, 3211x1713) is 9,378 bytes —
about 400x smaller than its current wire bake. It is already computed
server-side (`GameConfig`/map generator output) and already present in the
runtime config. If the client can paint the arena from this spec instead of
from baked pixels, the map-bytes problem is not reduced, it is eliminated:
there is no pixel data to ship, cache, chunk, or decode, ever.

## What is actually in a mapSpec

Inspected `ctf-spec-1337.json` directly. The fields that matter for
rendering:

- `width`, `height` — canvas size (3211x1713 here), unchanged, this design
  does not touch logical map size.
- `leftObstacles`: an array of ~130 shapes, each one of:
  - `{kind: "rect", x, y, w, h}`
  - `{kind: "polygon", points: [[x,y], ...]}`
  - `{kind: "diagonal", x0, y0, x1, y1, t}` (a thick line segment, `t` =
    thickness)
  - (symmetric maps mirror `leftObstacles` to the right half server-side
    today — see `symmetry` field; a client painter needs the same mirror
    step, or the spec needs to ship the already-mirrored full set.)
- `spawnPoints`, `spawnGroups`, `medKitSpawns`/`Candidates`, `shieldSpawns`,
  `spraySpawns`, `grenadeSpawns` — item/spawn markers, not geometry, but the
  client already needs to know obstacle geometry to avoid drawing pickups
  inside walls if it ever wants to place them itself (it currently doesn't —
  pickups arrive as sprites, out of scope here).
- `flagRing`, `endzone`, `endzoneRadius`, `homeDepth`, `flagless` — endzone
  shape/placement parameters (BR is `flagless: true`, `endzone: "column"`).
- `layout` — an archetype tag (e.g. `"sides"`), not raw geometry. Cosmetic/
  generator provenance only; a painter does not need it.

This is exactly the "rects/diagonals + floor" the task called out. The
obstacle list is the entire wall layer. What is **not** in the spec: any
texture, color, bevel, or shading — that is 100% server-side art applied on
top of the geometry (see below).

## What the client painter needs to do

1. **Fetch the spec once.** A tiny new endpoint (or piggyback on
   `/capabilities` or a new field in the existing init handshake) ships the
   mapSpec JSON — kilobytes, once per connection, never per round (this
   composes with STEP 1: a lobby's map never changes between rounds, so this
   is fetched at most once per socket's life, same as the STEP-1-fixed
   sprite defs).
2. **Rasterize the wall mask.** For each obstacle: fill a `rect` directly;
   fill a `polygon` via a scanline/even-odd fill (standard canvas
   `ctx.fill()` with a `Path2D` built from `points` handles this natively —
   this is the one piece that gets EASIER client-side, since the browser's
   path-fill is already what `renderArenaRgbaPair`'s per-pixel geometry test
   exists to approximate in software); draw a `diagonal` as a thick line
   (`ctx.lineWidth = t; ctx.stroke()` between the two points — again a
   built-in canvas primitive).
3. **Composite the floor.** Tile `arena_floor.png` (already a static asset,
   already shipped once for the page shell) as a canvas pattern
   (`ctx.createPattern(img, 'repeat')`) under the wall mask.
4. **Draw the border.** A fixed-width inset rect stroke — `ArenaBorder` is a
   compile-time constant, already public data (not secret geometry), ship it
   alongside the spec or hardcode it client-side same as other protocol
   constants already are (`spliceWireConstants`, per server.nim's client
   embedding).
5. Everything else (players, pickups, HUD, splatters, damage pops, shout
   bubbles, glow/endzone tint) is **unchanged** — those already arrive as
   sprites over the existing protocol and composite over whatever the
   MapLayerId canvas contains. This design only replaces the one static
   background sprite; the retained-mode object protocol above it does not
   care whether that background came from a decoded PNG blob or a client
   paint.

## What stays server-baked (deliberately, not as a shortcut)

- **The floor texture image itself** (`arena_floor.png`) and the **pedestal
  sprites** (`ped_<team>.png`) — these are hand-authored raster art, not
  geometry. They are small, static, cacheable-forever assets (unlike the
  per-map bake, they do not vary per map or per connection), so shipping them
  once via normal HTTP asset caching is already the right answer and costs
  nothing per-connection today.
- **The rooftop parapet bevel / window-glass sub-material shading** that
  `renderArenaRgbaPair` computes per obstacle (see map_art.nim's per-shape
  loop building `artMask`/`windowMask`). This is deliberate art polish over
  the raw geometry — flat fills from the client would look visibly flatter
  than the server bake. Two honest options, punted to implementation time:
  (a) accept the flatter look for the human player view specifically (the
  POV canvas is small and in motion; static bevel shading is the least
  noticeable detail at play resolution — worth a real side-by-side check,
  not assumed here), or (b) ship a small per-obstacle-**kind** style table
  (a handful of CSS-gradient-equivalent parameters, not pixels) that
  approximates the bevel client-side. Either way this is a follow-up
  decision, not a blocker to the core win (killing the megabyte pixel
  payload).
- **The endzone glow/fade overlay** (`EndzoneColdRgba`, per-band crossfade in
  global.nim) stays a server-computed OVERLAY sprite exactly as it streams
  today — it is dynamic (fades in/out with capture state), small, and
  already incremental; this design does not touch it.
- **The 1x collision/walkability mask** (`loadMapLayers`) — this is
  authoritative simulation state, already never rendered to humans
  (STEP 1's doc comment: `if spritesOff: addWalkabilitySprite`), and stays
  exactly as it is. This design is about the human's VISUAL bake only.

## Determinism

Nothing here touches gameHash or the sim. The geometry list is read-only,
already-generated data that the server currently also reads (to build the
SAME wall mask for its own bake) — client and server rasterize from the
IDENTICAL `leftObstacles` array, so there is no new source of divergence
between what a human sees and what the sim collides against; today's
baked-pixel path already has that same property (the bake is a rendering of
the same geometry, just pre-rendered server-side). The only new risk is a
client-side rasterizer BUG producing a wall shape that looks different from
the server's collision mask — mitigated by testing the painter against
every map in the pool's existing golden fixtures (`ctf-spec-*.json` +
recorded replay) and a pixel-diff tolerance check, analogous to the existing
`PoolRenderHashes` non-determinism tolerance already accepted for map-pack
renders (see `ctf-pool-seeds-stable-renders-not` in project memory) — this
is presentation-layer drift, never a gameplay-affecting one, since the sim
never reads client pixels.

## Estimated effort

- Spec delivery (new tiny endpoint or handshake field): ~0.5 day.
- Client painter (rect/polygon/diagonal fill + floor tile + border, using
  Canvas2D `Path2D`/pattern primitives that already exist in every target
  browser): ~1-1.5 days, including symmetry mirroring for maps that use it.
- Visual parity pass against the server bake (bevel/window decision above,
  screenshot diff harness): ~1 day.
- Removing the now-dead server bake path for the PLAYER stream specifically
  (`addMapBands`'s player-facing call site; the spectator/global viewer and
  bots keep their own paths untouched) once parity is signed off: ~0.5 day.
- **Total: ~3-4 engineer-days**, and it deletes the entire pixel-payload
  class of bug (this ladder's steps 1-3) for every future map, permanently,
  rather than continuing to optimize a payload that should not exist.
