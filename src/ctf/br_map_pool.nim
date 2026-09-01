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
