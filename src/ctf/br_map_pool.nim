## The certified Battle Royale map pool: a small accessor over
## `data/br_map_pool.json`, a JSON array of FULL expanded BR mapSpec
## objects — the same wire shape the live BR variant pins for its one
## map today (`br-gen-1339`, see `coworld_manifest_paintbot.json`'s
## "battle-royale" variant and `docs/designs/BR_MAPGEN.md`). Every entry
## is a fresh `tools/brmapkit generate --seed <N>` draw, converted with
## `tools/br_spec_to_ctf`, that passed `validateBr`'s full `allPass` gate
## (18 independent structural checks — connectivity, per-spawn cover,
## item fairness across all 16 spawns, zero unreachable cells, a viable
## final-zone center, ...) on that draw with NO --lenient override and NO
## hand-editing. A seed that fails any gate is simply absent from this
## file, never patched to pass (doctrine: "ALWAYS good" means every
## member provably passes a hard structural check, not that a score
## threshold made failure rarer).
##
## Pinning the FULL expanded spec (not just `genSeed`) is deliberate and
## matches how the live variant itself is pinned: `tools/brmapkit.nim`'s
## generator can change under a later doctrine revision, and a
## seed-only pool would silently re-roll every entry's geometry out from
## under any ballot built on this file. `src/ctf/map_pool.nim` (the CTF
## 2-team pool) stores bare seeds because 2-team maps regenerate
## deterministically from a stable generator with cheap re-validation at
## load time; BR's generator is a fork under active tuning
## (`tools/brmapkit.nim`'s own header), so this pool follows the
## replay-pinning discipline (`arena.mapSpecJson`/`mapFromSpecJson`)
## instead.
##
## This module does NOT wire into the ballot/vote path itself — that is
## the vote-v1 lane's own code. It only exposes read access:
##   loadBrMapPoolRaw*(path = BrMapPoolPath): JsonNode
##   brMapPoolNames*(path = BrMapPoolPath): seq[string]
##   loadBrMapPool*(path = BrMapPoolPath): seq[CtfMap]
##   getBrMap*(name: string, path = BrMapPoolPath): CtfMap

import std/[json, strformat]
import sim_types, arena

export sim_types.CtfMap

const BrMapPoolPath* = "data/br_map_pool.json"
  ## Repo-root-relative, matching every other map/replay fixture path in
  ## this codebase (e.g. `tests/fixtures/br-golden-map.json`). Callers
  ## running from a different working directory (tests, tools invoked
  ## from elsewhere) should pass an absolute override.

proc loadBrMapPoolRaw*(path: string = BrMapPoolPath): JsonNode =
  ## The pool file as parsed JSON: a top-level array of full expanded
  ## mapSpec objects, each self-naming via its own "name" field
  ## ("br-gen-<seed>") — the identical shape `arena.mapSpecJson` emits
  ## and `arena.mapFromSpecJson` consumes for any other pinned map.
  result = parseJson(readFile(path))
  if result.kind != JArray:
    raise newException(ValueError, &"br map pool at '{path}' is not a JSON array")

proc brMapPoolNames*(path: string = BrMapPoolPath): seq[string] =
  ## Every certified pool member's name, in file order — the menu a
  ## ballot picks from without paying to fully parse every map.
  for node in loadBrMapPoolRaw(path):
    result.add node["name"].getStr()

proc loadBrMapPool*(path: string = BrMapPoolPath): seq[CtfMap] =
  ## Every certified pool member as a playable CtfMap, in file order.
  for node in loadBrMapPoolRaw(path):
    result.add mapFromSpecJson($node)

proc getBrMap*(name: string, path: string = BrMapPoolPath): CtfMap =
  ## One named pool member (e.g. "br-gen-5001"). Raises if `name` isn't
  ## in the pool — an unknown name is a config error a ballot should
  ## surface loudly, never silently substitute for.
  for node in loadBrMapPoolRaw(path):
    if node["name"].getStr() == name:
      return mapFromSpecJson($node)
  raise newException(ValueError, &"br map pool at '{path}' has no entry named '{name}'")

## --- Season 2 rotating pool (8 duos / 16 seats) ----------------------------
##
## `data/br_s2_map_pool.json` is the battle-royale-s2 variant's map source:
## a JSON array of LEDGER ENTRIES (not bare specs), each
##   {"name", "seed", "certifiedAt", "gates": {..18 booleans + "all"..},
##    "spec": {..full expanded ctf mapSpec..}}
## Every entry is a fresh `tools/brmapkit generate --seed <N> --groups 8
## --scale 1.8384776` draw (the exact br-gen-8024 params from #354),
## converted by `tools/br_spec_to_ctf`, that passed the FULL `validateBr`
## 18-gate `allPass` — rejection-gated at generation time (a failing draw
## is never written, never patched, never `--lenient`'ed) and re-asserted
## by the rotation tool. The embedded gate ledger + certification date make
## age queryable: `tools/rotate_br_pool.sh --replace N` swaps out the N
## OLDEST entries for freshly certified draws without ever changing pool
## SIZE, only membership.
##
## Selection is per-episode and deterministic: `brPoolIndex(seed, len)` —
## the episode seed through a splitmix64 finalizer, mod pool size. The
## same episode seed maps to a DIFFERENT map after a rotation changes the
## membership under its index; that is fine and intended (an episode's
## replay never re-selects — the chosen spec is pinned into the replay
## config at parse time, see sim_config's `update`).

const
  BrS2MapPoolPath* = "data/br_s2_map_pool.json"
    ## Repo-root-relative, same rule (and same caveat) as BrMapPoolPath.
  BrPoolMapName* = "brpool"
    ## The mapPath value that selects from this pool ("map": "brpool" /
    ## "mapPath": "brpool" in a variant's game_config).

proc brPoolIndex*(seed, n: int): int =
  ## Deterministic, platform-stable spread of an episode seed over `n`
  ## pool slots: the splitmix64 finalizer, mod n. Pure integer math on
  ## fixed-width unsigned words — no float, no std/random, no wall clock —
  ## so the same seed picks the same slot on every box, forever.
  doAssert n > 0, "brPoolIndex needs a non-empty pool"
  var x = uint64(seed)
  x = (x xor (x shr 30)) * 0xBF58476D1CE4E5B9'u64
  x = (x xor (x shr 27)) * 0x94D049BB133111EB'u64
  x = x xor (x shr 31)
  int(x mod uint64(n))

proc loadBrS2PoolRaw*(path: string = BrS2MapPoolPath): JsonNode =
  ## The s2 pool file as parsed JSON: a top-level array of ledger entries.
  result = parseJson(readFile(path))
  if result.kind != JArray:
    raise newException(ValueError, &"br s2 map pool at '{path}' is not a JSON array")
  if result.len == 0:
    raise newException(ValueError, &"br s2 map pool at '{path}' is empty")

proc pickBrS2SpecJson*(seed: int, path: string = BrS2MapPoolPath): string =
  ## The mapSpec JSON (as a string, ready for `config.mapSpec`) of the pool
  ## member this episode seed selects. Raises on a missing/empty/misshapen
  ## pool — a config that asked for "brpool" must never silently fall back.
  let pool = loadBrS2PoolRaw(path)
  let entry = pool[brPoolIndex(seed, pool.len)]
  if entry.kind != JObject or not entry.hasKey("spec"):
    raise newException(ValueError,
      &"br s2 map pool at '{path}' entry {brPoolIndex(seed, pool.len)} has no \"spec\"")
  result = $entry["spec"]

proc brS2PoolNames*(path: string = BrS2MapPoolPath): seq[string] =
  ## Every s2 pool member's name, in file (= certification) order.
  for node in loadBrS2PoolRaw(path):
    result.add node["name"].getStr()

proc pickBrS2VoteBallotSpecJsons*(
  seed: int, path: string = BrS2MapPoolPath
): seq[string] =
  ## MAP VOTE (S2): the episode's 4-candidate ballot — 4 DISTINCT certified
  ## pool members, deterministic from the episode seed alone: candidate i's
  ## first draw is `brPoolIndex(seed + i, n)` (the splitmix64 finalizer, so
  ## i = 0 is EXACTLY the member `pickBrS2SpecJson` pins — the vote's
  ## no-show fallback is the #355 status quo), deduplicated by walking
  ## forward (+1 mod n) past already-drawn slots. Pure integer math on the
  ## seed: the same seed names the same 4 candidates on every box — and a
  ## replaying client never needs this proc at all, because the drawn specs
  ## are pinned into the replay header config (`voteMapSpecs`), following
  ## mapSpec's own rotation-proof pinning discipline.
  let pool = loadBrS2PoolRaw(path)
  if pool.len < 4:
    raise newException(ValueError,
      &"br s2 map pool at '{path}' has fewer than 4 members; a map ballot needs 4 distinct candidates")
  var chosen: seq[int]
  for i in 0 ..< 4:
    var index = brPoolIndex(seed + i, pool.len)
    while index in chosen:
      index = (index + 1) mod pool.len
    chosen.add index
    let entry = pool[index]
    if entry.kind != JObject or not entry.hasKey("spec"):
      raise newException(ValueError,
        &"br s2 map pool at '{path}' entry {index} has no \"spec\"")
    result.add $entry["spec"]
