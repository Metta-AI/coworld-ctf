## map_seed — the map generator's RANDOMNESS ARCHITECTURE.
##
## One root seed; every SCENE gets an independently derived sub-stream, named
## by string and spawnable to any depth. Nothing in the map pipeline may
## construct an RNG from a raw integer.
##
## WHY THIS EXISTS
## ---------------
## The generator used to run on ONE flat splitmix64 stream: `MapRng(state:
## seed)`, drawn top to bottom through `generateMapAttempt`. That has a cost
## that stays invisible until you pay it — inserting a single draw at position
## k shifts every draw after it, so every seed re-deals, the curated pool
## re-curates, and every pinned regression baseline moves. The oversize size
## classes paid it once (widening the size draw 3 -> 5 re-dealt every seed's
## board). The endzone-archetype work dodged it exactly once, with a hand
## rolled second stream keyed `seed xor 0x5A17E9D3C0FFEE11` — which is what let
## compact endzones ship with all 29 column maps byte-identical and no
## GameVersion bump.
##
## This module makes that escape hatch STRUCTURAL and OPEN-ENDED. A scene draws
## from its own stream derived from its NAME, so scenes may be added, removed,
## reordered or rewritten without disturbing any other scene's output. That is
## the property a scene-graph generator needs: a new scene must be able to
## appear without re-dealing the ones already there.
##
## The discipline is borrowed from Cogs-vs-Clips' scene-graph mapgen
## (`mettagrid/mapgen`): one root generator, every child SPAWNED from its
## parent, any node individually pinnable. `spawn` and `pinScene` are those two
## operations.
##
## THE API, for a generator that is a tree of scenes
## ------------------------------------------------
## ```nim
## let root = mapSeed(seed, attempt)          # one map, one candidate
## var shell = root.seedStream(SceneLayout)   # SAME for every candidate
## var terrain = root.stream("terrain")       # re-rolled per candidate
## var roomRng = terrain.spawn("room:7")      # a child node, one parent draw
## var doorRng = roomRng.spawn("door:north")  # nested as deep as you like
## ```
## * Scene names are free-form strings. There is no registry and no enum: two
##   scenes collide only if they pick the same name, and `KnownScenes` below is
##   documentation, not a closed set.
## * `spawn` consumes EXACTLY ONE draw from the parent, whatever the child does
##   with its own stream. So a scene that grows from 3 draws to 3000 cannot
##   move its siblings.
## * A name is the whole key. `stream("terrain")` is the same stream whether it
##   is asked for first or last, so scenes need no fixed evaluation order.
##
## PER-CANDIDATE VS PER-SEED
## -------------------------
## `generateCtfMap` draws K candidates for one seed and ships the best. The
## candidate index is `MapSeed.attempt`, and which streams it reaches is chosen
## at the CALL SITE, not by a table:
##
##   * `seedStream(name)` ignores `attempt`. Use it for anything that defines
##     the board rather than fills it — size class, symmetry, team layout,
##     endzone archetype, biome. Every candidate for seed 1002 is then the same
##     board, which is the point: the old re-roll walked `seed + attempt` on
##     the flat stream whose FIRST draw was the size class, so a rejected seed
##     came back as a differently-SIZED map. Asking for map 1002 and getting
##     map 1003 on another board is why `tools/gen_map_pool.nim` had to demand
##     first-attempt validity, and why K could not be picked per size class.
##   * `stream(name)` varies with `attempt`. Use it for everything selection is
##     meant to search over.
##
## TWO SEEDS, NOT ONE
## ------------------
## `config.mapSeed` names the LAYOUT; `config.seed` names the SIMULATION (spawn
## order, bot RNG, scatter). Separate on purpose: re-running one board under a
## different sim seed is the only way to sample how that map plays.
## `resolveCtfMapMetadata` falls back to `config.seed` when `mapSeed` is unset,
## so a config naming one seed still works. Never derive sim randomness here.
##
## COST
## ----
## Deriving a stream is a short string hash plus three integer multiplies.
## Streams are derived per scene, not per pixel.

const
  Golden = 0x9E3779B97F4A7C15'u64
    ## splitmix64's increment; also the odd multiplier that folds the attempt
    ## index in. Odd, so multiplying by it is a bijection on uint64.
  FnvOffset = 0xCBF29CE484222325'u64
  FnvPrime = 0x100000001B3'u64
  RootSalt = 0x5A17E9D3C0FFEE11'u64
    ## The original endzone escape hatch's constant, kept as this module's root
    ## salt so the file is visibly the generalization of that one trick rather
    ## than a second unrelated convention.
  AttemptSalt = 0x632BE59BD9B4E019'u64

const
  SceneLayout* = "layout"
    ## Board shell: size class, symmetry, team layout, endzone archetype. Drawn
    ## with `seedStream` — it is what makes K candidates K tries at ONE board.
  SceneTerrain* = "terrain"
    ## The structural pass: the wall set. The scene a scene-graph generator
    ## replaces wholesale.
  SceneCover* = "cover"      ## dressing on the structure: trenches, windows.
  ScenePickups* = "pickups"  ## med kits and any future item spawn.
  SceneBiome* = "biome"      ## surface skin; cosmetic, so drawn per SEED.
  SceneDecor* = "decor"      ## non-collidable dressing. Nothing draws it yet.

const KnownScenes* = [
  SceneLayout, SceneTerrain, SceneCover, ScenePickups, SceneBiome, SceneDecor,
]
  ## The scenes that exist TODAY, for tooling and tests that want to enumerate
  ## something. Deliberately not an enum and not exhaustive: adding a scene
  ## must not require editing this list, and a generator may use any name.

type
  MapRng* = object
    ## The generator's own splitmix64. Deliberately NOT `std/random`: this
    ## stream must be identical on every target including wasm, and
    ## `std/random`'s algorithm is not part of Nim's compatibility promise.
    ## Construct one only through `stream`, `seedStream` or `spawn`.
    state*: uint64

  MapSeed* = object
    ## The root of one map candidate's randomness. Build it with `mapSeed`.
    root*: uint64
    attempt*: int               ## which best-of-K candidate this is.
    pins*: seq[(string, uint64)]
      ## Per-scene stream overrides, set by `pinScene`. A seq rather than a
      ## table because it is almost always empty and never long, and because
      ## `MapSeed` has to stay a cheap copyable value.

func mix(x: uint64): uint64 =
  ## splitmix64's finalizer, used on its own as an avalanche mixer.
  var z = x
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

func sceneHash*(scene: string): uint64 =
  ## FNV-1a over a scene name. Short, stable across targets, and usable at
  ## compile time, so a scene tag can be folded into a `const`.
  result = FnvOffset
  for ch in scene:
    result = (result xor uint64(ord(ch))) * FnvPrime

func mapSeed*(seed: int, attempt = 0): MapSeed =
  ## The root for one map candidate. `seed` is the LAYOUT seed (`mapSeed` in
  ## the config), never the simulation seed.
  MapSeed(root: mix(uint64(seed) xor RootSalt), attempt: attempt)

func pinScene*(s: MapSeed, scene: string, streamSeed: uint64): MapSeed =
  ## A copy of `s` whose `scene` draws from a caller-chosen stream instead of
  ## its derived one — the A/B tool for a single scene: hold one still and let
  ## the rest re-derive ("same terrain, re-roll the cover"). A `streamSeed` of
  ## 0 would be indistinguishable from unpinned, so it is nudged to 1.
  result = s
  let value = if streamSeed == 0: 1'u64 else: streamSeed
  for i in 0 ..< result.pins.len:
    if result.pins[i][0] == scene:
      result.pins[i][1] = value
      return
  result.pins.add (scene, value)

func withAttempt*(s: MapSeed, attempt: int): MapSeed =
  ## The same root at another candidate index. `seedStream` output is identical
  ## across every value of `attempt`; `stream` output is not.
  result = s
  result.attempt = attempt

func pinnedStream(s: MapSeed, scene: string): uint64 =
  for (name, value) in s.pins:
    if name == scene: return value
  0'u64

func seedStream*(s: MapSeed, scene: string): MapRng =
  ## The stream for a scene that belongs to the SEED: identical for every
  ## best-of-K candidate. Board shell, biome — anything selection must hold
  ## fixed while it searches.
  let pin = s.pinnedStream(scene)
  if pin != 0: return MapRng(state: pin)
  MapRng(state: mix(s.root xor sceneHash(scene)))

func stream*(s: MapSeed, scene: string): MapRng =
  ## The stream for a scene that is re-rolled per candidate. Independent of
  ## every other scene's stream and of how many draws they take.
  let pin = s.pinnedStream(scene)
  if pin != 0: return MapRng(state: pin)
  MapRng(state: mix(
    mix(s.root xor sceneHash(scene)) + uint64(s.attempt) * Golden + AttemptSalt))

proc next*(rng: var MapRng): uint64 =
  ## splitmix64: tiny, statistically solid, identical on every target.
  rng.state = rng.state + Golden
  mix(rng.state)

proc spawn*(parent: var MapRng, node: string): MapRng =
  ## A CHILD generator, in the scene-graph sense: it consumes exactly one draw
  ## from the parent and mixes it with `node`. Use it inside a scene that wants
  ## sub-independence — each room, lane or chokepoint on its own stream — so
  ## re-tuning one node cannot shift the next. Two children with different
  ## names never share a stream, and the parent advances by exactly one step
  ## however much either child draws.
  MapRng(state: mix(parent.next() xor sceneHash(node)))

proc pick*(rng: var MapRng, bound: int): int =
  ## Uniform 0..bound-1 (modulo bias is immaterial at these bounds).
  int(rng.next() mod uint64(bound))

proc pickRange*(rng: var MapRng, lo, hi: int): int =
  lo + rng.pick(hi - lo + 1)

proc coin*(rng: var MapRng): bool =
  (rng.next() and 1'u64) == 1

proc shuffle*[T](rng: var MapRng, items: var seq[T]) =
  for i in countdown(items.high, 1):
    let j = rng.pick(i + 1)
    swap(items[i], items[j])
