## Proves the Season 2 ARMING ROUTE: a manifest VARIANT's game_config with
## `barrierPickups` set flows through the real config path and stages
## pickups -- no container ENV anywhere. Also proves the OFF default is
## byte-identical to the pre-barrier game.
import
  std/[json, os, strformat],
  ../src/ctf/[global, sim],
  toolutil

proc armed(gameConfig: JsonNode): SimServer =
  var config = defaultGameConfig()
  config.update($gameConfig)
  result = initSimServer(config)

proc main() =
  chdirGameDir()
  let manifest = parseJson(readFile("coworld_manifest_paintbot.json"))

  # Every published variant: can each one be armed as-is?
  echo "--- arming sweep across every published variant ---"
  for v in manifest["variants"]:
    let vid = v["id"].getStr
    var g = v["game_config"].copy()
    g["barrierPickups"] = %1
    try:
      let sim = armed(g)
      var walkable = true
      for sp in sim.barrierSpawns:
        if not (sp.present and sim.canOccupy(sp.x, sp.y)): walkable = false
      echo &"  {vid:<14} spawns={sim.barrierSpawns.len} walkable={walkable}"
    except CatchableError as e:
      echo &"  {vid:<14} REJECTED: {e.msg}"
  echo "---"

  # The base variant, exactly as published today.
  var base: JsonNode = nil
  for v in manifest["variants"]:
    if v["id"].getStr == "2v2":
      base = v["game_config"]
  doAssert base != nil

  let off = armed(base)
  echo &"2v2 as published      -> barrierSpawns={off.barrierSpawns.len}"
  doAssert off.barrierSpawns.len == 0, "published 2v2 must be barrier-free"
  doAssert not parseJson(off.config.configJson()).hasKey("barrierPickups"),
    "an OFF config must not echo the key (replay bytes stay identical)"
  echo "  OFF default confirmed: no spawns, no config echo"

  # The SAME variant with the one knob added -- this is the whole Season 2 diff.
  for n in 1 .. MaxBarrierPickupsPerTeam:
    var s2 = base.copy()
    s2["barrierPickups"] = %n
    let sim = armed(s2)
    let teams = if base.hasKey("teams"): base["teams"].getInt else: 2
    echo &"2v2 + barrierPickups:{n} -> barrierSpawns={sim.barrierSpawns.len}" &
      &" (teams={teams})"
    doAssert sim.barrierSpawns.len == n * teams
    for sp in sim.barrierSpawns:
      doAssert sp.present and sim.canOccupy(sp.x, sp.y),
        "a staged pickup landed in a wall"
    doAssert parseJson(sim.config.configJson())["barrierPickups"].getInt == n
    echo "  armed: every pickup present, walkable, and echoed into the replay"

  # The knob is bounded by the schema AND the engine.
  let schemaMax = manifest{"game", "config_schema", "properties",
    "barrierPickups", "maximum"}
  echo &"schema maximum={schemaMax}  engine MaxBarrierPickupsPerTeam=" &
    &"{MaxBarrierPickupsPerTeam}"
  doAssert schemaMax != nil and schemaMax.getInt == MaxBarrierPickupsPerTeam,
    "manifest schema and engine cap disagree"
  var bad = defaultGameConfig()
  var rejected = false
  try:
    bad.update("""{"barrierPickups": """ &
      $(MaxBarrierPickupsPerTeam + 1) & "}")
  except CtfError:
    rejected = true
  doAssert rejected, "over-cap value was not rejected"
  echo "  over-cap value rejected by the engine"

  # TRAP: under the paintball LOADOUT every pickup family is emptied by
  # design (sim.placeWalkablePickups) -- so barrierPickups is SILENTLY a
  # no-op there. It is accepted, echoed, and stages nothing. Any Season 2
  # variant built on `loadout: "paintball"` cannot carry barriers.
  var pb: JsonNode = nil
  for v in manifest["variants"]:
    if v["id"].getStr == "paintball":
      pb = v["game_config"].copy()
  doAssert pb != nil
  pb["barrierPickups"] = %2
  let pbSim = armed(pb)
  doAssert pbSim.barrierSpawns.len == 0, "paintball loadout staged barriers?"
  doAssert parseJson(pbSim.config.configJson())["barrierPickups"].getInt == 2,
    "the knob is still echoed -- which is exactly why the no-op is silent"
  echo "TRAP CONFIRMED: loadout=paintball accepts barrierPickups:2, echoes it," &
    " and stages 0 pickups (silent no-op)"
  echo "ARMING ROUTE VERIFIED (config only, no ENV)"

main()
