## GameConfig lifecycle: defaults, JSON readers, validation, update, and
## the config echo (configJson). Stage 5 of
## docs/plans/2026-08-01-sim-split.md; re-exported by sim.nim.

import
  std/[algorithm, json, strutils],
  jsony,
  sim_types, arena, br_map_pool, build_stamp, glory

proc defaultGameConfig*(): GameConfig =
  ## Returns the default CTF gameplay config.
  GameConfig(
    motionScale: MotionScale,
    accel: Accel,
    frictionNum: FrictionNum,
    frictionDen: FrictionDen,
    maxSpeed: MaxSpeed,
    stopThreshold: StopThreshold,
    playerBouncePct: PlayerBouncePct,
    seed: 0xA6019,
    speed: 1,
    lives: Lives,
    hitPoints: HitPoints,
    respawnTicks: RespawnTicks,
    gunRange: GunRange,
    fireCooldownTicks: FireCooldownTicks,
    fireWindupTicks: FireWindupTicks,
    carrierSpeedPct: CarrierSpeedPct,
    aimTurnRate: AimTurnRate,
    visionConeDeg: VisionConeDeg,
    visionBubble: VisionBubble,
    minPlayers: MinPlayers,
    startWaitTicks: StartWaitTicks,
    lobbyJoinTimeoutTicks: 0,
    gameOverTicks: GameOverTicks,
    maxTicks: MaxTicks,
    maxGames: MaxGames,
    showPlayerLabels: true,
    fastMode: true,
    teams: 2,
    scoring: ClassicScoring,
    mapPath: DefaultMapPath,
    mapSeed: -1,
    mapPoolIndex: -1,
    mapGen: MapGenOverrides(windows: -1, pits: -1, pitDensity: -1),
    mapSpec: "",
    closedRoster: false,
    allowSeatTakeover: false,
    allowDirectAim: false,
    allowAimAssist: false,
    aimAssistConeBrads: AimAssistConeBrads,
    slots: @[],
    perkMods: DefaultPerkMods,
    puddleDamagePct: DefaultPuddleDamagePct,
    barrierPickups: 0,
    barrageMaxPerSec: 0,
    barrageStartPerSec: BarrageStartPerSec,
    barrageStartSec: BarrageStartSec,
    barrageSaturateSec: BarrageSaturateSec,
    brMode: false,
    zonePhases: @[],
    allowCallouts: false,
    allowPolicyReflash: false,
    numAgents: 0,
    # Classic games field one cog per seat. Squad mode is opt-in:
    # cogsPerTeam defaulted to 4 from Coworld 0.7.243 until the production
    # incident restore, which made every num_agents classic variant run through
    # paintball's squad/runtime/scoring path.
    cogsPerTeam: 1,
    loadout: LoadoutCtf,
    floorPaint: false,
    paintBuff: false,
    hill: false,
    paintTile: PaintTile,
    hillRadiusTiles: DefaultHillRadiusTiles,
    hillOwnPermille: DefaultHillOwnPermille,
    hillDecisiveTicks: DefaultHillDecisiveTicks,
    paintSpeedOwnPct: DefaultPaintSpeedOwnPct,
    paintSpeedEnemyPct: DefaultPaintSpeedEnemyPct,
    paintHealTicks: DefaultPaintHealTicks,
    sprayDamage: SprayPaintDamage,
    regimes: @[regimeResident],
    turnTicks: DefaultTurnTicks,
    turnBudgetMs: DefaultTurnBudgetMs,
    attempt1Ms: DefaultAttempt1Ms,
    retryMs: DefaultRetryMs,
    turnSpacingMs: DefaultTurnSpacingMs,
    wallClockBudgetSeconds: DefaultWallClockBudgetSeconds,
    model: "",
    maxOutputTokens: DefaultMaxOutputTokens,
    season2Shell: true,
    allowDeprecatedModes: false,
    viewIntervalTicks: ViewIntervalTicksDefault,
    lobbyChatTicks: LobbyChatTicksDefault,
    playSeatBindTicks: PlaySeatBindTicksDefault,
    allowShotFeedback: false,
    allowCosmeticFx: false,
    # voteTicks deliberately 0, not VoteTicksDefault — see that const's own
    # comment (sim_types.nim) for why.
    voteTicks: 0,
    # LOOT(s2): all five loot-rework mechanisms dark by default. The two
    # downed timing knobs default to their real values (not 0) so arming
    # downedMode alone plays the ruled shape; they are read ONLY while
    # downedMode is on and echoed ONLY then (echoDownedKeys), so the dark
    # config echo carries none of them.
    medKitCount: -1,
    bandagePickups: 0,
    lootStart: false,
    downedMode: false,
    downedBleedOutTicks: DownedBleedOutTicksDefault,
    downedReviveTicks: DownedReviveTicksDefault,
    downedEscalation: true,
    # GIVE(s2): the play-called exchange mechanic, dark by default — no
    # declaration is ever accepted and the channel never runs (echoed only
    # when armed, echoGiveItemKeys).
    giveItem: false,
    # DROP(s2): the button-chord item drop, dark by default — the aim-pair
    # chord stays the inert no-op it always was, droppedItems never populate,
    # and the gameHash carries no drop block (echoed only when armed,
    # echoDropItemKeys).
    dropItem: false,
    # RECUT(v13): the multiplier-recut economy and the realized-config
    # stamp, both dark by default and each its OWN independently-settable
    # key (per-flag activation, recut contract Amendment 2 §1).
    gloryMultiplierRecut: false,
    # §A6/AMENDMENT 7: win-as-multiplier, dark by default — its OWN key
    # (per-flag activation), reads only under an armed recut.
    winAsMultiplier: false,
    # MINTCAP: per-episode deed mint budgets + the meaningful product
    # backstop, dark by default — its OWN key (per-flag activation),
    # reads only under an armed recut.
    deedMintCaps: false,
    stampRealizedConfig: false,
    variantId: "",
    # SPAWNLOOT: dark by default (see sim_types.nim's own field comments) —
    # 0 seeded guns, 0 seeded hoppers, so the radius is never read.
    lootSpawnSeedGuns: 0,
    lootSpawnSeedHoppers: 0,
    lootSpawnSeedRadius: 0,
    # SITECLASS: dark by default — every fallback hopper crate keeps the
    # inherited med-kit (retreat-class) siting, byte-identical.
    hopperSiteTrafficPermille: 0,
    # PERCEPTION(glory-2 §17): the frame loadout-flag exposure, dark by
    # default — no hasGun/hasHopper key ever appears on the replay frame
    # or the duo-partner grant until armed.
    frameLoadoutFlags: false,
    # ZONEPAINT: dark by default — the ring keeps its rect-membership
    # damage test byte-identical; the bleed knob is only READ under the
    # flag (echoed only when armed, echoZonePaintKeys).
    zoneDamageByPaint: false,
    zonePaintDownedBleedPermille: ZonePaintDownedBleedPermilleDefault,
    # PAINTDEATH: dark by default — a rescue under paint stays possible,
    # exactly as it was before the flag existed.
    zoneBlocksRevive: false
  )

proc squadModeConfigured*(config: GameConfig): bool =
  ## True only when a live config explicitly asks each seat to command a squad.
  ## `numAgents` alone is not a paintball signal: classic hosted variants also
  ## carry it so the platform can seat policies.
  config.numAgents > 0 and config.cogsPerTeam > 1

proc deprecatedModeTriggers(config: GameConfig): seq[string] =
  ## Returns every live-boot legacy-mode trigger in the published seam order.
  if not config.brMode:
    result.add("classic")
  if not config.season2Shell:
    result.add("season1Shell")
  if config.loadout != LoadoutCtf or config.floorPaint or config.paintBuff or
      config.hill:
    result.add("paintball")
  if config.squadModeConfigured():
    result.add("squadMode")

proc checkDeprecatedMode*(config: GameConfig) =
  ## Refuses deprecated live modes at the boot seam. Parsing, validation, and
  ## replay playback stay exempt; callers choose that placement.
  if config.allowDeprecatedModes:
    return
  let triggers = config.deprecatedModeTriggers()
  if triggers.len == 0:
    return
  raise newException(
    CtfError,
    "Config selects deprecated mode(s) [" & triggers.join(", ") & "]:\n" &
      "deprecated since 0.7.253 — season 2 battle royale (brMode + " &
      "season2Shell)\n" &
      "is the only supported mode. Set allowDeprecatedModes: true to run " &
      "this\nconfig anyway."
  )

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  ## Reads one optional integer config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(CtfError, "Config field " & name & " must be an integer.")
  value = item.getInt()

proc readConfigBool(node: JsonNode, name: string, value: var bool) =
  ## Reads one optional boolean config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JBool:
    raise newException(CtfError, "Config field " & name & " must be a boolean.")
  value = item.getBool()

proc readConfigString(node: JsonNode, name: string, value: var string) =
  ## Reads one optional string config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(CtfError, "Config field " & name & " must be a string.")
  value = item.getStr()

proc teamNameList(): string =
  ## All valid team-name tokens (`teamText` order), comma-joined for error
  ## messages. Looping the enum here (rather than a literal string) means
  ## the message stays correct as `Team` widens — see BR_MAPGEN.md §6.2.
  for team in Team:
    if result.len > 0: result.add ", "
    result.add teamText(team)

proc readSlotTeam(text: string, slotIndex: int): Team =
  ## Reads one slot team string.
  let key = text.strip().toLowerAscii()
  for team in Team:
    if key == teamText(team):
      return team
  raise newException(
    CtfError,
    "Config field slots[" & $slotIndex & "].team must be one of: " &
      teamNameList() & "."
  )

proc normalizedSlotColor(text: string): string =
  ## Returns a normalized slot color name.
  result = text.strip().toLowerAscii()
  result = result.replace("_", " ")
  result = result.replace("-", " ")
  result = result.replace(" ", "")

proc playerColorText*(color: uint8): string =
  ## Returns the readable player color name.
  for i in 0 ..< PlayerColors.len:
    if PlayerColors[i] == color:
      return PlayerColorNames[i]
  "unknown"

proc readSlotColor(text: string, slotIndex: int): uint8 =
  ## Reads one slot color string.
  case text.normalizedSlotColor()
  of "red":
    PlayerColors[0]
  of "orange":
    PlayerColors[1]
  of "yellow":
    PlayerColors[2]
  of "lightblue", "cyan":
    PlayerColors[3]
  of "pink":
    PlayerColors[4]
  of "lime":
    PlayerColors[5]
  of "blue":
    PlayerColors[6]
  of "paleblue":
    PlayerColors[7]
  of "gray", "grey":
    PlayerColors[8]
  of "white":
    PlayerColors[9]
  of "darkbrown":
    PlayerColors[10]
  of "brown":
    PlayerColors[11]
  of "darkteal", "teal":
    PlayerColors[12]
  of "green":
    PlayerColors[13]
  of "darknavy", "navy":
    PlayerColors[14]
  of "black":
    PlayerColors[15]
  else:
    raise newException(
      CtfError,
      "Config field slots[" & $slotIndex & "].color is unknown."
    )

proc readSlotSkin(node: JsonNode, slotIndex: int): Skin =
  ## Reads one tolerant cosmetic skin value.
  if node.kind == JString:
    case node.getStr()
    of "default":
      return DefaultSkin
    of "crown":
      return CrownSkin
    else:
      discard
  stderr.writeLine(
    "Warning: config slots[" & $slotIndex & "].skin value " & $node &
      " is unrecognized; using default."
  )
  DefaultSkin

proc readConfigSlots(node: JsonNode, slots: var seq[PlayerSlotConfig]) =
  ## Reads optional fixed player slot config entries.
  if not node.hasKey("slots"):
    return
  let items = node["slots"]
  if items.kind != JArray:
    raise newException(CtfError, "Config field slots must be an array.")
  slots.setLen(0)
  for i, item in items.elems:
    if item.kind != JObject:
      raise newException(
        CtfError,
        "Config field slots[" & $i & "] must be an object."
      )
    if item.hasKey("name"):
      raise newException(
        CtfError,
        "Config field slots[" & $i & "].name is not supported; use players[" &
          $i & "].name instead."
      )
    var slot: PlayerSlotConfig
    item.readConfigString("token", slot.token)
    if item.hasKey("team"):
      let team = item["team"]
      if team.kind != JString:
        raise newException(
          CtfError,
          "Config field slots[" & $i & "].team must be a string."
        )
      slot.team = readSlotTeam(team.getStr(), i)
      slot.hasTeam = true
    if item.hasKey("color"):
      let color = item["color"]
      if color.kind != JString:
        raise newException(
          CtfError,
          "Config field slots[" & $i & "].color must be a string."
        )
      slot.color = readSlotColor(color.getStr(), i)
      slot.hasColor = true
    if item.hasKey("skin"):
      slot.skin = readSlotSkin(item["skin"], i)
    if item.hasKey("control"):
      # §5.1 of the play-calling design: the one trusted per-seat choice the
      # whole play-seat protocol boundary hangs on. Closed enum, rejected by
      # name on anything else.
      let control = item["control"]
      if control.kind != JString or
          control.getStr() notin ["input", "play"]:
        raise newException(
          CtfError,
          "Config field slots[" & $i & "].control must be \"input\" or " &
            "\"play\"."
        )
      slot.control =
        if control.getStr() == "play": scPlay else: scInput
    slots.add(slot)

proc readConfigPlayers(node: JsonNode, slots: var seq[PlayerSlotConfig]) =
  ## Reads optional fixed player display names by slot index.
  if node.hasKey("player_names"):
    raise newException(
      CtfError,
      "Config field player_names is not supported; use players[].name instead."
    )
  if not node.hasKey("players"):
    return
  let items = node["players"]
  if items.kind != JArray:
    raise newException(CtfError, "Config field players must be an array.")
  if items.len > MaxPlayers:
    raise newException(
      CtfError,
      "Config field players cannot have more than " & $MaxPlayers &
        " entries."
    )
  if slots.len < items.len:
    slots.setLen(items.len)
  for i, item in items.elems:
    if item.kind != JObject:
      raise newException(
        CtfError,
        "Config field players[" & $i & "] must be an object."
      )
    if not item.hasKey("name"):
      raise newException(
        CtfError,
        "Config field players[" & $i & "].name is required."
      )
    let nameNode = item["name"]
    if nameNode.kind != JString:
      raise newException(
        CtfError,
        "Config field players[" & $i & "].name must be a string."
      )
    let name = nameNode.getStr()
    # An EMPTY name means "this slot has no configured display name", and it
    # has to be accepted because THIS SERIALIZER WRITES IT. configJson turns
    # the players array on when ANY slot is named, then emits an entry for
    # EVERY slot -- so one named slot beside one unnamed slot produces
    # {"name":""}, which this reader used to refuse. A recorded config that
    # its own reader rejects is not a round trip: replays from a partially
    # named roster could not be loaded at all, they raised here.
    #
    # Relaxed on the READER rather than fixed on the writer on purpose. The
    # writer's output is stamped into every replay header, and changing what
    # it emits would change recorded bytes for existing configs -- the one
    # thing that must not move. Accepting more is free; emitting differently
    # is not.
    if name.len > 0:
      slots[i].name = name

proc defaultSlotName(slotIndex: int): string =
  ## Returns the canonical name for one generated tournament slot.
  "Player" & $(slotIndex + 1)

proc readConfigTokens(
  node: JsonNode,
  slots: var seq[PlayerSlotConfig],
  closedRoster: bool
) =
  ## Reads optional fixed player slot tokens.
  if not node.hasKey("tokens"):
    return
  let items = node["tokens"]
  if items.kind != JArray:
    raise newException(CtfError, "Config field tokens must be an array.")
  if items.len > MaxPlayers:
    raise newException(
      CtfError,
      "Config field tokens cannot have more than " & $MaxPlayers & " entries."
    )
  if slots.len < items.len:
    slots.setLen(items.len)
  for i, item in items.elems:
    if item.kind != JString:
      raise newException(
        CtfError,
        "Config field tokens[" & $i & "] must be a string."
      )
    let token = item.getStr()
    if slots[i].token.len > 0 and slots[i].token != token:
      raise newException(
        CtfError,
        "Config field tokens[" & $i & "] conflicts with slots[" & $i &
          "].token."
      )
    slots[i].token = token
    if closedRoster and slots[i].name.len == 0:
      slots[i].name = defaultSlotName(i)

proc readTeamKey(text, field: string): Team =
  ## Reads one team-keyed map key (handicaps, perks).
  let key = text.strip().toLowerAscii()
  for team in Team:
    if key == teamText(team):
      return team
  raise newException(
    CtfError,
    "Config field " & field & " has key " & text &
      "; expected one of: " & teamNameList() & "."
  )

proc readHandicapPermille(value: JsonNode, teamName: string): int =
  ## Reads one 0.0..1.0 handicap and returns it as a permille (0..1000).
  var f: float
  case value.kind
  of JFloat:
    f = value.getFloat()
  of JInt:
    f = float(value.getInt())
  else:
    raise newException(
      CtfError,
      "Config field handicaps." & teamName & " must be a number between 0 and 1."
    )
  if f < 0.0 or f > 1.0:
    raise newException(
      CtfError,
      "Config field handicaps." & teamName & " must be between 0 and 1."
    )
  # Round to the nearest permille. f is in [0, 1], so this lands in [0, 1000];
  # exactly 0.0 maps to 0 (the byte-identical no-handicap path).
  int(f * 1000.0 + 0.5)

proc readPerkGroup(value: JsonNode, teamName: string): PerkSet =
  ## Reads one perk group: an array of perk name strings.
  if value.kind != JArray:
    raise newException(
      CtfError,
      "Config field perks." & teamName & " group must be an array of perk names."
    )
  for item in value:
    if item.kind != JString:
      raise newException(
        CtfError,
        "Config field perks." & teamName & " has a non-string perk name."
      )
    try:
      result.incl(parsePerk(item.getStr()))
    except CtfError:
      raise newException(
        CtfError,
        "Config field perks." & teamName & " has unknown perk " &
          item.getStr() & "; expected armor, scope, grenade, thruster, or luck."
      )

proc readConfigPerks(node: JsonNode, config: var GameConfig) =
  ## Reads the optional per-team perk map. A team's value is one of:
  ##   a flat array  — {"red": ["armor", "scope"]} — one team-wide group;
  ##   nested arrays — {"blue": [["grenade"], ["thruster", "luck"]]} —
  ##     unnamed per-policy groups dealt in join order (CTF-Doubles);
  ##   an object     — {"blue": {"botA": ["grenade"], "botB": ["luck"]}} —
  ##     groups PINNED to policy names (policyName match; an unmatched
  ##     policy gets nothing).
  ## Omitted teams keep no perks. Like handicaps, a perk set named for an
  ## inactive team is accepted and simply never applies.
  if not node.hasKey("perks"):
    return
  let perks = node["perks"]
  if perks.kind != JObject:
    raise newException(CtfError, "Config field perks must be an object.")
  for teamName, value in perks.pairs:
    let team = readTeamKey(teamName, "perks")
    var groups: seq[PerkGroup]
    case value.kind
    of JObject:
      # Named groups, pinned to their policies.
      if value.len == 0:
        raise newException(
          CtfError,
          "Config field perks." & teamName &
            " is an empty object; omit the team instead."
        )
      for pol, group in value.pairs:
        if pol.len == 0:
          raise newException(
            CtfError,
            "Config field perks." & teamName & " has an empty policy name."
          )
        groups.add PerkGroup(pol: pol, perks: readPerkGroup(group, teamName))
    of JArray:
      if value.len == 0:
        # A flat empty array has no meaning ("no perks" is spelled by
        # omitting the team) and would otherwise register as one empty group
        # — flipping the has-perks gates (pmods, marker content) on a
        # perk-free team. An empty NESTED group ([["armor"], []]) stays
        # legal: it means "this policy gets nothing".
        raise newException(
          CtfError,
          "Config field perks." & teamName &
            " is an empty array; omit the team instead."
        )
      elif value[0].kind == JArray:
        for group in value:
          groups.add PerkGroup(perks: readPerkGroup(group, teamName))
      else:
        groups.add PerkGroup(perks: readPerkGroup(value, teamName))
    else:
      raise newException(
        CtfError,
        "Config field perks." & teamName &
          " must be an array of perk names, an array of groups, or a " &
          "policy-name object."
      )
    config.perks[team] = groups

proc readPerkModPermille(node: JsonNode, name: string, value: var int) =
  ## Reads one optional 0.0..1.0 perk-mod fraction into a permille.
  if not node.hasKey(name):
    return
  let item = node[name]
  var f: float
  case item.kind
  of JFloat:
    f = item.getFloat()
  of JInt:
    f = float(item.getInt())
  else:
    raise newException(
      CtfError,
      "Config field perkMods." & name & " must be a number between 0 and 1."
    )
  if f < 0.0 or f > 1.0:
    raise newException(
      CtfError,
      "Config field perkMods." & name & " must be between 0 and 1."
    )
  value = int(f * 1000.0 + 0.5)

proc readPerkModInt(node: JsonNode, name: string, value: var int) =
  ## Reads one optional integer perk mod, sanity-capped at 100 so a
  ## fat-fingered extra digit errors instead of shipping an absurd game.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt or item.getInt() < 0 or item.getInt() > 100:
    raise newException(
      CtfError,
      "Config field perkMods." & name & " must be an integer in 0..100."
    )
  value = item.getInt()

proc readConfigPerkMods(node: JsonNode, config: var GameConfig) =
  ## Reads the optional perk-magnitude overrides, e.g.
  ## {"armorHp": 1, "scopeAim": 0.5, "grenadeRange": 0.25,
  ##  "thrusterSpeed": 0.1, "luckChance": 0.1, "luckDamage": 2}.
  ## Fractions are authored 0..1 and stored as integer permille (the
  ## handicaps rule), so every in-sim derivation stays integer or perk-gated.
  ## Mods without a `perks` block are accepted and inert (nothing reads them
  ## until a seat carries the perk), mirroring the inactive-team tolerance.
  if not node.hasKey("perkMods"):
    return
  let mods = node["perkMods"]
  if mods.kind != JObject:
    raise newException(CtfError, "Config field perkMods must be an object.")
  for key in mods.keys:
    if key notin ["armorHp", "scopeAim", "grenadeRange", "thrusterSpeed",
        "luckChance", "luckDamage"]:
      raise newException(
        CtfError, "Config field perkMods has unknown key " & key & ".")
  mods.readPerkModInt("armorHp", config.perkMods.armorHp)
  mods.readPerkModPermille("scopeAim", config.perkMods.scopeAim)
  mods.readPerkModPermille("grenadeRange", config.perkMods.grenadeRange)
  mods.readPerkModPermille("thrusterSpeed", config.perkMods.thrusterSpeed)
  mods.readPerkModPermille("luckChance", config.perkMods.luckChance)
  mods.readPerkModInt("luckDamage", config.perkMods.luckDamage)
  if config.perkMods.luckDamage < 1:
    raise newException(
      CtfError, "Config field perkMods.luckDamage must be at least 1.")

proc readConfigHandicaps(node: JsonNode, config: var GameConfig) =
  ## Reads the optional per-team handicap map, e.g. {"red": 0.0, "blue": 0.6}.
  ## Omitted teams stay at 0 (no handicap). A handicap named for an inactive
  ## team is accepted and simply never applies, so a caller (e.g. a league
  ## commissioner) can set all four teams without knowing the active count.
  if not node.hasKey("handicaps"):
    return
  let handicaps = node["handicaps"]
  if handicaps.kind != JObject:
    raise newException(CtfError, "Config field handicaps must be an object.")
  for teamName, value in handicaps.pairs:
    config.handicaps[readTeamKey(teamName, "handicaps")] =
      readHandicapPermille(value, teamName)

proc readZonePhaseZ(item: JsonNode, index: int): int =
  ## Reads one required zonePhases[index].z scale, authored 0.0..1.0 like a
  ## handicap fraction, and returns it as a permille (1..1000) so every
  ## in-sim derivation (zoneRectAtScale) stays integer-only.
  if not item.hasKey("z"):
    raise newException(
      CtfError, "Config field zonePhases[" & $index & "].z is required.")
  let value = item["z"]
  var f: float
  case value.kind
  of JFloat:
    f = value.getFloat()
  of JInt:
    f = float(value.getInt())
  else:
    raise newException(
      CtfError, "Config field zonePhases[" & $index & "].z must be a number.")
  if f <= 0.0 or f > 1.0:
    raise newException(
      CtfError,
      "Config field zonePhases[" & $index &
        "].z must be greater than 0 and at most 1."
    )
  int(f * 1000.0 + 0.5)

proc readConfigZonePhases(node: JsonNode, config: var GameConfig) =
  ## Reads the optional battle-royale shrink-zone schedule (§4.3), e.g.
  ## {"zonePhases": [
  ##   {"z": 0.75, "waitTicks": 240, "shrinkTicks": 120, "dps": 1}, ...
  ## ]}. Omitted (the default, an empty seq) is the mode OFF — no center
  ## draw, no rect, no damage, no label markers, byte-identical to an
  ## engine without the field. `z` is required per entry; `waitTicks` /
  ## `shrinkTicks` / `dps` default to 0 when omitted. Schedule sanity (z
  ## strictly decreasing phase over phase, in range) is checked in
  ## validate() below, once the whole seq is parsed.
  if not node.hasKey("zonePhases"):
    return
  let items = node["zonePhases"]
  if items.kind != JArray:
    raise newException(CtfError, "Config field zonePhases must be an array.")
  if items.len > MaxZonePhases:
    raise newException(
      CtfError,
      "Config field zonePhases cannot have more than " & $MaxZonePhases &
        " entries."
    )
  config.zonePhases.setLen(0)
  for i, item in items.elems:
    if item.kind != JObject:
      raise newException(
        CtfError, "Config field zonePhases[" & $i & "] must be an object.")
    var phase = ZonePhase(zPermille: item.readZonePhaseZ(i))
    item.readConfigInt("waitTicks", phase.waitTicks)
    item.readConfigInt("shrinkTicks", phase.shrinkTicks)
    item.readConfigInt("dps", phase.dps)
    config.zonePhases.add(phase)

proc readConfigZoneCenter(
  node: JsonNode, config: var GameConfig, mapMeta: CtfMap
) =
  ## Reads the optional {"zoneCenter": [x, y]} config field (docs/designs/
  ## BR_MAPGEN.md §4.3): when present, the battle-royale shrink zone closes
  ## on this AUTHORED map-pixel point instead of the default random draw
  ## (resetZone) — for ease of editing/authoring a specific match, e.g. a
  ## league wanting the zone to always close on the map's own center.
  ## Omitted (the default) leaves zoneCenterConfigured false, which keeps
  ## the existing random draw untouched.
  ##
  ## Validates the FINAL configured zonePhases entry's rect fits fully
  ## on-board around this point with an ArenaBorder margin — the exact rule
  ## resetZone applies to its own random draw (see its doc), just checked
  ## here instead of re-drawn. Uses `mapMeta` (the map already resolved
  ## earlier in update(), same idiom as the gunRange default above) rather
  ## than a stored width/height, since GameConfig itself never pins the
  ## resolved map's dimensions. Skipped when zonePhases is empty: the point
  ## is never read in that case (see SimServer.zoneCenter), so there is
  ## nothing meaningful to validate yet — an author may set zoneCenter
  ## before zonePhases in a config-building pipeline without an ordering
  ## trap, since validation only bites once zonePhases actually lands.
  if not node.hasKey("zoneCenter"):
    return
  let item = node["zoneCenter"]
  if item.kind != JArray or item.len != 2 or
      item[0].kind != JInt or item[1].kind != JInt:
    raise newException(
      CtfError,
      "Config field zoneCenter must be a [x, y] array of two integers."
    )
  config.zoneCenterConfigured = true
  config.zoneCenterX = item[0].getInt()
  config.zoneCenterY = item[1].getInt()
  if config.zonePhases.len == 0:
    return
  let
    finalPermille = config.zonePhases[^1].zPermille
    fw = max(1, mapMeta.width * finalPermille div 1000)
    fh = max(1, mapMeta.height * finalPermille div 1000)
    loX = ArenaBorder + fw div 2
    hiX = mapMeta.width - 1 - ArenaBorder - (fw - 1 - fw div 2)
    loY = ArenaBorder + fh div 2
    hiY = mapMeta.height - 1 - ArenaBorder - (fh - 1 - fh div 2)
  if config.zoneCenterX < loX or config.zoneCenterX > hiX or
      config.zoneCenterY < loY or config.zoneCenterY > hiY:
    raise newException(
      CtfError,
      "Config field zoneCenter (" & $config.zoneCenterX & ", " &
        $config.zoneCenterY &
        ") does not keep the final zonePhases rect fully on-board " &
        "(needs x in " & $loX & ".." & $hiX & ", y in " & $loY & ".." &
        $hiY & ")."
    )
proc parseRegime*(text: string): Regime =
  ## Parses one authored regime name; raises on anything else. The enum is
  ## closed on purpose — an unknown regime would silently change which cogs a
  ## seat drives, which is the whole measurement this coworld exists for.
  case text.strip().toLowerAscii()
  of RegimeResidentText: regimeResident
  of RegimeVisitorText: regimeVisitor
  else:
    raise newException(
      CtfError,
      "Config field regimes has unknown entry " & text & "; expected " &
        RegimeResidentText & " or " & RegimeVisitorText & "."
    )

proc regimeText*(regime: Regime): string =
  ## The authored/wire name of one regime.
  case regime
  of regimeResident: RegimeResidentText
  of regimeVisitor: RegimeVisitorText

proc readConfigRegimes(node: JsonNode, config: var GameConfig) =
  ## Reads the optional per-game regime list. Bounded at 4 entries so the
  ## shape exists for a future mixed matrix without any variant being able to
  ## schedule an unbounded episode.
  if not node.hasKey("regimes"):
    return
  let items = node["regimes"]
  if items.kind != JArray:
    raise newException(CtfError, "Config field regimes must be an array.")
  if items.len < 1 or items.len > 4:
    raise newException(
      CtfError, "Config field regimes must have 1..4 entries.")
  var regimes: seq[Regime] = @[]
  for i, item in items.elems:
    if item.kind != JString:
      raise newException(
        CtfError,
        "Config field regimes[" & $i & "] must be a string."
      )
    regimes.add(parseRegime(item.getStr()))
  config.regimes = regimes

proc hasPlaySeat*(config: GameConfig): bool =
  ## Gate-blind roster predicate: true when any configured slot has
  ## `control: "play"`. Validation pairs it with season2Shell below. Runtime
  ## code should use the episode-level `isPlaySeatEpisode` predicate where
  ## available; season2Shell now defaults true, while an all-input roster must
  ## remain on the direct-input path.
  for slot in config.slots:
    if slot.control == scPlay:
      return true
  false

proc validate(config: GameConfig) =
  ## Raises if a gameplay config has invalid values.
  if config.motionScale <= 0:
    raise newException(CtfError, "Config field motionScale must be positive.")
  if config.frictionDen <= 0:
    raise newException(CtfError, "Config field frictionDen must be positive.")
  if config.minPlayers < 1:
    raise newException(CtfError, "Config field minPlayers must be at least 1.")
  if config.teams notin [2, 4, 8, 16]:
    raise newException(CtfError, "Config field teams must be 2, 4, 8, or 16.")
  if config.scoring notin [ClassicScoring, PotScoring]:
    raise newException(
      CtfError,
      "Config field scoring must be " & ClassicScoring & " or " & PotScoring &
        "; got " & config.scoring & "."
    )
  for i, slot in config.slots:
    if slot.hasTeam and ord(slot.team) >= config.teams:
      raise newException(
        CtfError,
        "Config field slots[" & $i & "].team is " & teamText(slot.team) &
          " but the game seats " & $config.teams & " teams."
      )
  if config.minPlayers > MaxPlayers:
    raise newException(CtfError, "can't do more than 8 players.")
  if config.lives < 1:
    raise newException(CtfError, "Config field lives must be at least 1.")
  if config.hitPoints < 1:
    raise newException(CtfError, "Config field hitPoints must be at least 1.")
  if config.gunRange <= 0:
    raise newException(CtfError, "Config field gunRange must be positive.")
  if config.fireWindupTicks < 0:
    raise newException(CtfError, "Config field fireWindupTicks must not be negative.")
  if config.carrierSpeedPct <= 0 or config.carrierSpeedPct > 100:
    raise newException(CtfError, "Config field carrierSpeedPct must be 1..100.")
  if config.playerBouncePct < 0 or config.playerBouncePct > 100:
    raise newException(CtfError, "Config field playerBouncePct must be 0..100.")
  if config.aimTurnRate < 1:
    raise newException(CtfError, "Config field aimTurnRate must be at least 1.")
  if config.visionConeDeg < 0 or config.visionConeDeg > 180:
    raise newException(CtfError, "Config field visionConeDeg must be between 0 and 180.")
  if config.aimAssistConeBrads < 0 or
      config.aimAssistConeBrads > AimBradsTurn div 2:
    raise newException(
      CtfError,
      "Config field aimAssistConeBrads must be 0.." & $(AimBradsTurn div 2) & "."
    )
  if config.allowAimAssist and not config.allowDirectAim:
    # The engine's only already-recorded, replay-safe signal for "a human,
    # not a policy, is driving this seat" is a direct-aim write landing on
    # the cog this tick (see Player.directAimActive) — without allowDirectAim
    # that signal never fires, so the mode would silently do nothing. Refuse
    # the config outright rather than ship a knob that looks armed and never
    # fires a single assist.
    raise newException(
      CtfError, "Config field allowAimAssist requires allowDirectAim.")
  if config.puddleDamagePct < 0 or config.puddleDamagePct > 100:
    raise newException(CtfError, "Config field puddleDamagePct must be 0..100.")
  if config.barrierPickups < 0 or
      config.barrierPickups > MaxBarrierPickupsPerTeam:
    raise newException(CtfError,
      "Config field barrierPickups must be 0.." & $MaxBarrierPickupsPerTeam & ".")
  if config.visionBubble < 0:
    raise newException(CtfError, "Config field visionBubble must be non-negative.")
  if config.speed notin [1, 2, 3, 4, 8, 16]:
    raise newException(
      CtfError,
      "Config field speed must be 1, 2, 3, 4, 8, or 16."
    )
  if config.startWaitTicks < 0:
    raise newException(CtfError, "Config field startWaitTicks must be non-negative.")
  if config.lobbyJoinTimeoutTicks < 0:
    raise newException(CtfError, "Config field lobbyJoinTimeoutTicks must be non-negative.")
  if config.respawnTicks < 0 or config.fireCooldownTicks < 0:
    raise newException(CtfError, "Timer config fields must not be negative.")
  if config.gameOverTicks < 0 or config.maxTicks < 0 or config.maxGames < 0:
    raise newException(CtfError, "Timer config fields must not be negative.")
  if config.barrageMaxPerSec < 0 or config.barrageMaxPerSec > BarrageAbsMaxPerSec:
    raise newException(
      CtfError,
      "Config field barrageMaxPerSec must be 0.." & $BarrageAbsMaxPerSec & ".")
  if config.barrageMaxPerSec > 0:
    if config.maxTicks <= 0:
      raise newException(
        CtfError,
        "Config field barrageMaxPerSec requires a time limit (maxTicks > 0): " &
          "the barrage starts off the game clock."
      )
    if config.barrageStartPerSec < 1 or
        config.barrageStartPerSec > config.barrageMaxPerSec:
      raise newException(
        CtfError,
        "Config field barrageStartPerSec must be 1..barrageMaxPerSec."
      )
    if config.barrageStartSec < 1:
      raise newException(
        CtfError, "Config field barrageStartSec must be at least 1.")
    if config.barrageSaturateSec < 1:
      raise newException(
        CtfError, "Config field barrageSaturateSec must be at least 1.")
  # Shrink-zone schedule sanity (§4.3): z must fall STRICTLY across phases —
  # including the implicit phase-0 scale of 1000 permille (full field) — so
  # R/G (a group's territory radius in gun-ranges) never ticks back UP mid-
  # match. zPermille's own (0, 1000] range is already enforced per entry by
  # readZonePhaseZ; this is the CROSS-entry check that only makes sense once
  # the whole seq is parsed.
  var previousZPermille = 1000
  for i, phase in config.zonePhases:
    if phase.zPermille >= previousZPermille:
      raise newException(
        CtfError,
        "Config field zonePhases[" & $i & "].z (" &
          $(phase.zPermille.float / 1000.0) &
          ") must be strictly less than the previous phase's (" &
          $(previousZPermille.float / 1000.0) & ")."
      )
    if phase.waitTicks < 0:
      raise newException(
        CtfError,
        "Config field zonePhases[" & $i & "].waitTicks must not be negative."
      )
    if phase.shrinkTicks < 0:
      raise newException(
        CtfError,
        "Config field zonePhases[" & $i &
          "].shrinkTicks must not be negative."
      )
    if phase.dps < 0:
      raise newException(
        CtfError,
        "Config field zonePhases[" & $i & "].dps must not be negative."
      )
    previousZPermille = phase.zPermille
  if config.loadout notin [LoadoutCtf, LoadoutPaintball]:
    raise newException(
      CtfError,
      "Config field loadout must be " & LoadoutCtf & " or " &
        LoadoutPaintball & "; got " & config.loadout & "."
    )
  if config.cogsPerTeam < 1 or config.cogsPerTeam > 8:
    raise newException(CtfError, "Config field cogsPerTeam must be 1..8.")
  if config.paintTile < 4:
    raise newException(CtfError, "Config field paintTile must be at least 4.")
  if config.hillRadiusTiles < 0:
    raise newException(
      CtfError, "Config field hillRadiusTiles must not be negative.")
  if config.hillOwnPermille <= 500 or config.hillOwnPermille > 1000:
    raise newException(
      CtfError,
      "Config field hillOwnPermille must be 501..1000 so at most one team " &
        "can own the hill."
    )
  if config.hillDecisiveTicks < 1:
    raise newException(
      CtfError, "Config field hillDecisiveTicks must be at least 1.")
  if config.paintSpeedOwnPct < 1 or config.paintSpeedEnemyPct < 1:
    raise newException(
      CtfError, "Config field paintSpeed*Pct must be positive.")
  if config.paintHealTicks < 1:
    raise newException(
      CtfError, "Config field paintHealTicks must be at least 1.")
  if config.sprayDamage < 1:
    raise newException(
      CtfError, "Config field sprayDamage must be at least 1.")
  if config.regimes.len < 1 or config.regimes.len > 4:
    raise newException(
      CtfError, "Config field regimes must have 1..4 entries.")
  if config.turnTicks < 1:
    raise newException(CtfError, "Config field turnTicks must be at least 1.")
  if config.turnBudgetMs < 1 or config.attempt1Ms < 1 or config.retryMs < 1:
    raise newException(
      CtfError, "Config LLM deadline fields must be positive.")
  if config.attempt1Ms + config.retryMs > config.turnBudgetMs:
    raise newException(
      CtfError,
      "Config fields attempt1Ms + retryMs must fit inside turnBudgetMs."
    )
  if config.attempt1Ms mod 1000 != 0 or config.retryMs mod 1000 != 0:
    ## v1.1 timing amendment: curly passes the deadline to CURLOPT_TIMEOUT,
    ## which is WHOLE SECONDS, and the turn loop floors the conversion. A
    ## sub-second value is therefore not the deadline it claims to be —
    ## `attempt1Ms: 4500` ran with 4 s against a 4618 ms sidecar median and
    ## every successful call landed on 3999–4001 ms.
    raise newException(
      CtfError,
      "Config fields attempt1Ms and retryMs must be whole seconds " &
      "(multiples of 1000): curly's transport timeout has whole-second " &
      "granularity, so anything else is silently floored."
    )
  if config.turnSpacingMs < 0:
    raise newException(
      CtfError, "Config field turnSpacingMs must not be negative.")
  if config.wallClockBudgetSeconds < 1:
    raise newException(
      CtfError, "Config field wallClockBudgetSeconds must be positive.")
  if config.paintBuff and not config.floorPaint:
    raise newException(
      CtfError, "Config field paintBuff requires floorPaint.")
  if config.hill and not config.floorPaint:
    raise newException(
      CtfError, "Config field hill requires floorPaint.")
  if config.numAgents < 0:
    raise newException(CtfError, "Config field num_agents must not be negative.")
  # Season 2 play-calling shell (§5.1/§9.2 of
  # docs/designs/strategy-play-calling-shell-2026-08-29.md): field ranges
  # and the gate/slot coupling. The deeper play-seat roster-shape rules
  # (closed roster, the BR 16x2 duo shape) are P2 work and land with the
  # protocol, not here.
  if config.viewIntervalTicks < ViewIntervalTicksMin or
      config.viewIntervalTicks > ViewIntervalTicksMax:
    raise newException(
      CtfError,
      "Config field viewIntervalTicks must be " & $ViewIntervalTicksMin &
        ".." & $ViewIntervalTicksMax & "."
    )
  if config.lobbyChatTicks < 0 or config.lobbyChatTicks > LobbyChatTicksMax:
    raise newException(
      CtfError,
      "Config field lobbyChatTicks must be 0.." & $LobbyChatTicksMax & "."
    )
  if config.voteTicks < 0 or config.voteTicks > VoteTicksMax:
    raise newException(
      CtfError,
      "Config field voteTicks must be 0.." & $VoteTicksMax & "."
    )
  if config.voteMapSpecs.len notin [0, BallotOptionCount]:
    raise newException(
      CtfError,
      "Config field voteMapSpecs must hold exactly " & $BallotOptionCount &
        " candidate map specs (or be absent)."
    )
  if config.voteMapSpecs.len > 0 and config.voteTicks <= 0:
    raise newException(
      CtfError,
      "Config field voteMapSpecs requires voteTicks > 0 (the vote window)."
    )
  if config.playSeatBindTicks < 0 or
      config.playSeatBindTicks > PlaySeatBindTicksMax:
    raise newException(
      CtfError,
      "Config field playSeatBindTicks must be 0.." & $PlaySeatBindTicksMax &
        " (positive in a play-seat episode)."
    )
  let hasPlaySeat = config.hasPlaySeat()
  if hasPlaySeat and not config.season2Shell:
    # playSeatRequiresShell: a "play" slot with explicit season2Shell false is
    # invalid. The default-true all-input roster remains a direct-input episode.
    raise newException(
      CtfError,
      "Config field slots[].control \"play\" requires season2Shell " &
        "(playSeatRequiresShell)."
    )
  if hasPlaySeat and config.playSeatBindTicks < 1:
    raise newException(
      CtfError,
      "Config field playSeatBindTicks must be positive in a play-seat " &
        "episode."
    )
  if config.slots.len > MaxPlayers:
    raise newException(CtfError, "Config field slots cannot have more than 8 entries.")
  if config.closedRoster and config.slots.len < config.minPlayers:
    raise newException(
      CtfError,
      "Config field closedRoster requires at least minPlayers configured slots."
    )
  if config.closedRoster:
    for i, slot in config.slots:
      if slot.name.len == 0:
        raise newException(
          CtfError,
          "Config field closedRoster requires players[" & $i & "].name."
        )
      if slot.token.len == 0:
        raise newException(
          CtfError,
          "Config field closedRoster requires slots[" & $i & "].token."
        )
  for i in 0 ..< config.slots.len:
    for j in i + 1 ..< config.slots.len:
      if config.slots[i].name.len > 0 and
          config.slots[i].name == config.slots[j].name:
        raise newException(
          CtfError,
          "Config field players has duplicate name " & config.slots[i].name & "."
        )
      if config.slots[i].token.len > 0 and
          config.slots[i].token == config.slots[j].token:
        raise newException(
          CtfError,
          "Config field slots has duplicate token."
        )
  # LOOT(s2): the loot-rework gates. lootStart/downedMode are BR mechanisms
  # only — refusing them outside brMode is what keeps every CTF config
  # provably untouchable by this lane (the ruling: CTF stays 3-shot, BR
  # experiments), rather than relying on every CTF call site staying dark.
  if config.medKitCount < -1:
    raise newException(CtfError,
      "Config field medKitCount must be -1 (map default) or >= 0.")
  if config.bandagePickups < 0:
    raise newException(CtfError,
      "Config field bandagePickups must not be negative.")
  if config.bandagePickups > NeutralPickupPoolWidth:
    # PLACEMENT CAP: the board addresses one object id per bandage out of a
    # NeutralPickupPoolWidth-wide pool; past that the render loop clamps and
    # the extra pickups exist in the sim but not on any screen. Refuse the
    # knob loudly rather than ship invisible pickups.
    raise newException(CtfError,
      "Config field bandagePickups must be 0.." & $NeutralPickupPoolWidth & ".")
  if config.lootStart and not config.brMode:
    raise newException(CtfError, "Config field lootStart requires brMode.")
  if config.downedMode and not config.brMode:
    raise newException(CtfError, "Config field downedMode requires brMode.")
  if config.downedMode and config.downedBleedOutTicks < 1:
    raise newException(CtfError,
      "Config field downedBleedOutTicks must be at least 1 under downedMode.")
  if config.downedMode and config.downedReviveTicks < 1:
    raise newException(CtfError,
      "Config field downedReviveTicks must be at least 1 under downedMode.")
  # GIVE(s2): same brMode fence as lootStart/downedMode above — the target
  # of a handoff is THE duo partner, a BR fact; CTF configs cannot arm it.
  if config.giveItem and not config.brMode:
    raise newException(CtfError, "Config field giveItem requires brMode.")
  # SPAWNLOOT: seeding an unlootable crate on a config that never places any
  # (lootStart dark, so hasGun/hasHopper already start true) would silently
  # place crates nobody's canFire gate ever consults — refuse it loudly
  # instead of shipping a no-op, same "requires X" shape as every fence
  # above.
  if config.lootSpawnSeedGuns < 0:
    raise newException(CtfError,
      "Config field lootSpawnSeedGuns must not be negative.")
  if config.lootSpawnSeedHoppers < 0:
    raise newException(CtfError,
      "Config field lootSpawnSeedHoppers must not be negative.")
  if config.lootSpawnSeedRadius < 0:
    raise newException(CtfError,
      "Config field lootSpawnSeedRadius must not be negative.")
  if (config.lootSpawnSeedGuns > 0 or config.lootSpawnSeedHoppers > 0) and
      not config.lootStart:
    raise newException(CtfError,
      "Config fields lootSpawnSeedGuns/lootSpawnSeedHoppers require lootStart.")
  # ZONEPAINT: the flag on a schedule-less config would be a silent no-op
  # (updateZone already returns on empty zonePhases) — refuse loudly
  # instead, same "requires X" shape as every fence above. The bleed knob
  # is bounds-checked UNCONDITIONALLY (not just under the flag) so a typo'd
  # value never sits latent waiting for the flag: the ceiling is glory-2
  # amendment 1's never-instant-finalize spec floor stated as a bound.
  if config.zoneDamageByPaint and config.zonePhases.len == 0:
    raise newException(CtfError,
      "Config field zoneDamageByPaint requires zonePhases.")
  if config.zonePaintDownedBleedPermille < 1000 or
      config.zonePaintDownedBleedPermille > ZonePaintDownedBleedPermilleMax:
    raise newException(CtfError,
      "Config field zonePaintDownedBleedPermille must be in [1000.." &
      $ZonePaintDownedBleedPermilleMax & "].")
  # PAINTDEATH: the no-rescue-in-paint gate reads the paint DAMAGE surface
  # (zonePaintedForDamageAt), which only defines "painted ground" while
  # zoneDamageByPaint is armed — arming it alone would be a silent no-op,
  # so it is refused loudly, the same "requires X" shape as every fence
  # above. (zoneDamageByPaint already requires zonePhases, so this
  # transitively requires a schedule too.)
  if config.zoneBlocksRevive and not config.zoneDamageByPaint:
    raise newException(CtfError,
      "Config field zoneBlocksRevive requires zoneDamageByPaint.")
  # SITECLASS: a per-mille, and only meaningful while there are fallback
  # hopper crates to re-site — so it rides lootStart the same way the seed
  # counts do, refused loudly instead of parsing into a silent no-op.
  if config.hopperSiteTrafficPermille < 0 or
      config.hopperSiteTrafficPermille > 1000:
    raise newException(CtfError,
      "Config field hopperSiteTrafficPermille must be 0..1000.")
  if config.hopperSiteTrafficPermille > 0 and not config.lootStart:
    raise newException(CtfError,
      "Config field hopperSiteTrafficPermille requires lootStart.")

proc update*(config: var GameConfig, jsonText: string) =
  ## Updates a gameplay config from a JSON object.
  if jsonText.len == 0:
    return
  var node: JsonNode
  try:
    node = fromJson(jsonText)
  except jsony.JsonError as e:
    raise newException(CtfError, "Could not parse config JSON: " & e.msg)
  if node.kind != JObject:
    raise newException(CtfError, "Config must be a JSON object.")
  node.readConfigInt("motionScale", config.motionScale)
  node.readConfigInt("accel", config.accel)
  node.readConfigInt("frictionNum", config.frictionNum)
  node.readConfigInt("frictionDen", config.frictionDen)
  node.readConfigInt("maxSpeed", config.maxSpeed)
  node.readConfigInt("stopThreshold", config.stopThreshold)
  node.readConfigInt("playerBouncePct", config.playerBouncePct)
  node.readConfigInt("seed", config.seed)
  node.readConfigInt("speed", config.speed)
  node.readConfigInt("lives", config.lives)
  node.readConfigInt("hitPoints", config.hitPoints)
  node.readConfigInt("respawnTicks", config.respawnTicks)
  node.readConfigInt("gunRange", config.gunRange)
  node.readConfigInt("fireCooldownTicks", config.fireCooldownTicks)
  node.readConfigInt("fireWindupTicks", config.fireWindupTicks)
  node.readConfigInt("carrierSpeedPct", config.carrierSpeedPct)
  node.readConfigInt("aimTurnRate", config.aimTurnRate)
  node.readConfigInt("visionConeDeg", config.visionConeDeg)
  node.readConfigInt("visionBubble", config.visionBubble)
  node.readConfigInt("minPlayers", config.minPlayers)
  node.readConfigInt("startWaitTicks", config.startWaitTicks)
  node.readConfigInt("gameStartWaitTicks", config.startWaitTicks)
  node.readConfigInt("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  node.readConfigInt("gameOverTicks", config.gameOverTicks)
  node.readConfigInt("maxTicks", config.maxTicks)
  node.readConfigInt("maxGameTicks", config.maxTicks)
  node.readConfigInt("maxGames", config.maxGames)
  node.readConfigInt("barrageMaxPerSec", config.barrageMaxPerSec)
  node.readConfigInt("barrageStartPerSec", config.barrageStartPerSec)
  node.readConfigInt("barrageStartSec", config.barrageStartSec)
  node.readConfigInt("barrageSaturateSec", config.barrageSaturateSec)
  node.readConfigBool("showPlayerLabels", config.showPlayerLabels)
  node.readConfigBool("fastMode", config.fastMode)
  node.readConfigInt("teams", config.teams)
  node.readConfigString("scoring", config.scoring)
  node.readConfigString("map", config.mapPath)
  node.readConfigString("mapPath", config.mapPath)
  node.readConfigInt("mapSeed", config.mapSeed)
  node.readConfigInt("mapPoolIndex", config.mapPoolIndex)
  node.readConfigString("mapSize", config.mapGen.size)
  node.readConfigString("mapSymmetry", config.mapGen.symmetry)
  node.readConfigInt("mapColumns", config.mapGen.columns)
  node.readConfigInt("mapWindows", config.mapGen.windows)
  node.readConfigInt("mapPits", config.mapGen.pits)
  node.readConfigInt("mapPitDensity", config.mapGen.pitDensity)
  node.readConfigInt("mapPuddles", config.mapGen.puddles)
  node.readConfigInt("puddleDamagePct", config.puddleDamagePct)
  node.readConfigInt("barrierPickups", config.barrierPickups)
  node.readConfigString("mapCenterFeature", config.mapGen.centerFeature)
  node.readConfigString("mapLayout", config.mapGen.layout)
  node.readConfigString("mapEndzone", config.mapGen.endzone)
  node.readConfigInt("mapEndzoneRadius", config.mapGen.endzoneRadius)
  node.readConfigInt("mapBaseDepth", config.mapGen.baseDepth)
  node.readConfigInt("num_agents", config.numAgents)
  node.readConfigInt("numAgents", config.numAgents)
  node.readConfigInt("cogsPerTeam", config.cogsPerTeam)
  node.readConfigString("loadout", config.loadout)
  node.readConfigBool("floorPaint", config.floorPaint)
  node.readConfigBool("paintBuff", config.paintBuff)
  node.readConfigBool("hill", config.hill)
  node.readConfigInt("paintTile", config.paintTile)
  node.readConfigInt("hillRadiusTiles", config.hillRadiusTiles)
  node.readConfigInt("hillOwnPermille", config.hillOwnPermille)
  node.readConfigInt("hillDecisiveTicks", config.hillDecisiveTicks)
  node.readConfigInt("paintSpeedOwnPct", config.paintSpeedOwnPct)
  node.readConfigInt("paintSpeedEnemyPct", config.paintSpeedEnemyPct)
  node.readConfigInt("paintHealTicks", config.paintHealTicks)
  node.readConfigInt("sprayDamage", config.sprayDamage)
  node.readConfigInt("turnTicks", config.turnTicks)
  node.readConfigInt("turnBudgetMs", config.turnBudgetMs)
  node.readConfigInt("attempt1Ms", config.attempt1Ms)
  node.readConfigInt("retryMs", config.retryMs)
  node.readConfigInt("turnSpacingMs", config.turnSpacingMs)
  node.readConfigInt("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  node.readConfigString("model", config.model)
  node.readConfigInt("maxOutputTokens", config.maxOutputTokens)
  node.readConfigRegimes(config)
  if node.hasKey("mapSpec"):
    if node["mapSpec"].kind != JObject:
      raise newException(CtfError, "Config field mapSpec must be an object.")
    config.mapSpec = $node["mapSpec"]
  ## BR S2 (#354 follow-up): mapPath "brpool" gives every episode a FRESH
  ## certified map — selected deterministically from the episode seed over
  ## data/br_s2_map_pool.json (see br_map_pool.nim's s2 section) and pinned
  ## as mapSpec RIGHT HERE, before the resolve below, so the replay carries
  ## the exact geometry. Playback re-parses a config that already HAS a
  ## mapSpec, so the explicit branch above wins and the pool is never
  ## consulted again: a recorded episode stays loadable forever, even after
  ## its map rotates OUT of the pool. An unpinned hosted seed is randomized
  ## per boot BEFORE update (ctf.nim), which is exactly what makes the
  ## selection per-episode.
  ## MAP VOTE (S2): the pre-match ballot's 4 candidates ride the config the
  ## same way mapSpec does — pinned FULL specs, so the replay header names
  ## every candidate's exact geometry and playback never consults the
  ## rotating pool. Two sources, mirroring mapSpec's own two branches:
  ## an explicit "voteMapSpecs" key (a replay re-parse — the recorded
  ## ballot, taken verbatim) or, absent that, a fresh seed-deterministic
  ## draw when this parse is arming a brpool episode's vote (voteTicks > 0
  ## — read EARLY here for exactly this gate; the tail-position GVNEXT read
  ## below re-reads the same key idempotently). voteTicks == 0 (the
  ## default) leaves voteMapSpecs empty and this whole block byte-inert:
  ## the #355 single-pick branch below runs unchanged.
  if node.hasKey("voteMapSpecs"):
    if node["voteMapSpecs"].kind != JArray:
      raise newException(
        CtfError, "Config field voteMapSpecs must be an array of objects.")
    config.voteMapSpecs = @[]
    for item in node["voteMapSpecs"]:
      if item.kind != JObject:
        raise newException(
          CtfError, "Config field voteMapSpecs must be an array of objects.")
      config.voteMapSpecs.add $item
  node.readConfigInt("voteTicks", config.voteTicks)
  ## S2 simplification, 16-solo-team shape (PKG-B, elif below): mapPath
  ## "brpool16" mirrors the "brpool" branch's single-pick path, but draws
  ## from the 16-group pool (data/br_map_pool.json, the pre-#355 classic
  ## pool — see br_map_pool.nim's "solo pool" doc comment) instead of the
  ## 8-duo s2 pool. No vote-ballot support yet (pickBrS2VoteBallotSpecJsons
  ## is s2-pool-specific) — single-pick only, additive alongside the
  ## branch above it.
  if config.mapSpec.len == 0 and config.mapPath == BrPoolMapName:
    if config.voteTicks > 0 and config.voteMapSpecs.len == 0:
      config.voteMapSpecs = pickBrS2VoteBallotSpecJsons(config.seed)
      config.mapSpec = config.voteMapSpecs[0]
    else:
      config.mapSpec = pickBrS2SpecJson(config.seed)
  elif config.mapSpec.len == 0 and config.mapPath == BrPoolMapName16:
    config.mapSpec = pickBrPoolSpecJson(config.seed)
  ## Resolve the effective map ONCE: a generated map is expanded and pinned
  ## as mapSpec here, so the replay carries the exact geometry and playback
  ## never re-runs the generator. The gun range follows the selected map
  ## unless the config sets it explicitly: each map def carries its own
  ## map-wide default.
  let mapMeta = resolveCtfMapMetadata(config)
  if config.mapSpec.len == 0 and mapMeta.path == GenMapName:
    config.mapSpec = mapSpecJson(mapMeta)
  if not node.hasKey("gunRange"):
    config.gunRange = mapMeta.gunRange
  node.readConfigSlots(config.slots)
  node.readConfigHandicaps(config)
  node.readConfigPerks(config)
  node.readConfigPerkMods(config)
  node.readConfigZonePhases(config)
  node.readConfigZoneCenter(config, mapMeta)
  node.readConfigBool("closedRoster", config.closedRoster)
  node.readConfigBool("allowSeatTakeover", config.allowSeatTakeover)
  node.readConfigBool("allowDirectAim", config.allowDirectAim)
  node.readConfigBool("allowAimAssist", config.allowAimAssist)
  node.readConfigInt("aimAssistConeBrads", config.aimAssistConeBrads)
  node.readConfigBool("allowCallouts", config.allowCallouts)
  node.readConfigBool("allowPolicyReflash", config.allowPolicyReflash)
  node.readConfigTokens(config.slots, config.closedRoster)
  node.readConfigPlayers(config.slots)
  # GVNEXT(elim): appended read for the appended brMode field (sim_types.nim).
  node.readConfigBool("brMode", config.brMode)
  # GVNEXT(shell): appended reads for the play-calling shell's root fields
  # (sim_types.nim). Season 2 defaults on; allowDeprecatedModes is the live
  # legacy-mode boot override.
  node.readConfigBool("season2Shell", config.season2Shell)
  node.readConfigBool("allowDeprecatedModes", config.allowDeprecatedModes)
  node.readConfigInt("viewIntervalTicks", config.viewIntervalTicks)
  node.readConfigInt("lobbyChatTicks", config.lobbyChatTicks)
  node.readConfigInt("playSeatBindTicks", config.playSeatBindTicks)
  # GVNEXT(shotfeedback): appended read for the appended allowShotFeedback
  # field (sim_types.nim) — same tail-append rule as brMode above.
  node.readConfigBool("allowShotFeedback", config.allowShotFeedback)
  # GVNEXT(cosmeticfx): appended read for the appended allowCosmeticFx field
  # (sim_types.nim) — same tail-append rule as allowShotFeedback above.
  node.readConfigBool("allowCosmeticFx", config.allowCosmeticFx)
  # GVNEXT(vote): appended read for the appended voteTicks field
  # (sim_types.nim) — same tail-append rule as allowCosmeticFx above.
  node.readConfigInt("voteTicks", config.voteTicks)
  # LOOT(s2): appended reads for the loot-rework fields (sim_types.nim) —
  # same tail-append rule as everything above. Absent keys leave the
  # dark defaults, so an existing config JSON parses to an unchanged config.
  node.readConfigInt("medKitCount", config.medKitCount)
  node.readConfigInt("bandagePickups", config.bandagePickups)
  node.readConfigBool("lootStart", config.lootStart)
  node.readConfigBool("downedMode", config.downedMode)
  node.readConfigInt("downedBleedOutTicks", config.downedBleedOutTicks)
  node.readConfigInt("downedReviveTicks", config.downedReviveTicks)
  node.readConfigBool("downedEscalation", config.downedEscalation)
  # GIVE(s2): appended read for the appended giveItem field (sim_types.nim)
  # — same tail-append rule as everything above. An absent key leaves the
  # dark default, so an existing config JSON parses to an unchanged config.
  node.readConfigBool("giveItem", config.giveItem)
  # DROP(s2): appended read for the appended dropItem field (sim_types.nim)
  # — same tail-append rule as everything above. An absent key leaves the
  # dark default, so an existing config JSON parses to an unchanged config.
  node.readConfigBool("dropItem", config.dropItem)
  # RECUT(v13): appended reads for the multiplier-recut fields
  # (sim_types.nim) — same tail-append rule as everything above. Absent
  # keys leave the dark defaults, so an existing config JSON parses to an
  # unchanged config. Each is its OWN key on purpose (per-flag activation,
  # recut contract Amendment 2 §1): the economy, the stamp and the variant
  # label stage independently — of each other AND of lootStart/downedMode.
  node.readConfigBool("gloryMultiplierRecut", config.gloryMultiplierRecut)
  node.readConfigBool("winAsMultiplier", config.winAsMultiplier)
  node.readConfigBool("deedMintCaps", config.deedMintCaps)
  node.readConfigBool("stampRealizedConfig", config.stampRealizedConfig)
  node.readConfigString("variantId", config.variantId)
  # SPAWNLOOT: appended reads for the appended spawn-loot-seeding fields
  # (sim_types.nim) — same tail-append rule as everything above. Absent
  # keys leave the dark defaults, so an existing config JSON parses to an
  # unchanged config.
  node.readConfigInt("lootSpawnSeedGuns", config.lootSpawnSeedGuns)
  node.readConfigInt("lootSpawnSeedHoppers", config.lootSpawnSeedHoppers)
  node.readConfigInt("lootSpawnSeedRadius", config.lootSpawnSeedRadius)
  # SITECLASS: appended read for the appended hopper site-class field —
  # same tail-append rule; absent leaves the dark default.
  node.readConfigInt(
    "hopperSiteTrafficPermille", config.hopperSiteTrafficPermille)
  # PERCEPTION(glory-2 §17): appended read for the appended
  # frameLoadoutFlags field (sim_types.nim) — same tail-append rule as
  # everything above. An absent key leaves the dark default, so an
  # existing config JSON parses to an unchanged config.
  node.readConfigBool("frameLoadoutFlags", config.frameLoadoutFlags)
  # ZONEPAINT: appended reads for the appended zone-paint-damage fields
  # (sim_types.nim) — same tail-append rule as everything above. Absent
  # keys leave the dark defaults, so an existing config JSON parses to an
  # unchanged config.
  node.readConfigBool("zoneDamageByPaint", config.zoneDamageByPaint)
  node.readConfigInt("zonePaintDownedBleedPermille",
    config.zonePaintDownedBleedPermille)
  node.readConfigBool("zoneBlocksRevive", config.zoneBlocksRevive)
  config.validate()

proc slotTeamText(slot: PlayerSlotConfig): string =
  ## Returns a JSON team string for one slot.
  if not slot.hasTeam:
    return ""
  teamText(slot.team)

proc slotColorText(slot: PlayerSlotConfig): string =
  ## Returns a JSON color string for one slot.
  if not slot.hasColor:
    return ""
  playerColorText(slot.color)

proc skinText(skin: Skin): string =
  ## Returns a JSON skin string.
  case skin
  of DefaultSkin:
    "default"
  of CrownSkin:
    "crown"

proc echoPuddleKeys(config: GameConfig, node: JsonNode) =
  ## Echo the puddle keys only when the mode departs from the default, so a
  ## puddle-free game's replay config stays byte-identical to pre-puddle
  ## builds (same rule as echoHandicapKeys below).
  if config.mapGen.puddles > 0:
    node["mapPuddles"] = %config.mapGen.puddles
  if config.mapGen.puddles > 0 or
      config.puddleDamagePct != DefaultPuddleDamagePct:
    node["puddleDamagePct"] = %config.puddleDamagePct

proc echoBarrierKeys(config: GameConfig, node: JsonNode) =
  ## Same rule for the barrier knob: echoed only when the mode is on, so a
  ## barrier-free game's replay config stays byte-identical to older builds.
  if config.barrierPickups > 0:
    node["barrierPickups"] = %config.barrierPickups

proc echoHandicapKeys(config: GameConfig, node: JsonNode) =
  ## Echo only the handicapped teams, as their authored 0..1 floats, so a
  ## default (unhandicapped) game's replay config carries no handicaps key.
  var handicaps = newJObject()
  for team in Red .. Yellow:
    if config.handicaps[team] > 0:
      handicaps[teamText(team)] = %(config.handicaps[team].float / 1000.0)
  if handicaps.len > 0:
    node["handicaps"] = handicaps

proc echoPerkKeys(config: GameConfig, node: JsonNode) =
  ## Echo only the perked teams, in their authored shape — a policy-name
  ## object for named (pinned) groups, one flat name array for a single
  ## unnamed group, nested arrays for several — so a default (perk-free)
  ## game's replay config carries no perks key.
  var perks = newJObject()
  for team in Red .. Yellow:
    if config.perks[team].len == 0:
      continue
    proc groupNames(group: PerkGroup): JsonNode =
      result = newJArray()
      for perk in Perk:
        if perk in group.perks:
          result.add(%perkText(perk))
    if config.perks[team][0].pol.len > 0:
      var named = newJObject()
      for group in config.perks[team]:
        named[group.pol] = groupNames(group)
      perks[teamText(team)] = named
    else:
      var groups = newJArray()
      for group in config.perks[team]:
        groups.add(groupNames(group))
      perks[teamText(team)] =
        if config.perks[team].len == 1: groups[0] else: groups
  if perks.len > 0:
    node["perks"] = perks

proc echoPerkModKeys(config: GameConfig, node: JsonNode) =
  ## Echo perkMods only when some magnitude differs from its default, as the
  ## authored shapes (fractions as 0..1 floats, counts as integers).
  if config.perkMods != DefaultPerkMods:
    node["perkMods"] = %*{
      "armorHp": config.perkMods.armorHp,
      "scopeAim": config.perkMods.scopeAim.float / 1000.0,
      "grenadeRange": config.perkMods.grenadeRange.float / 1000.0,
      "thrusterSpeed": config.perkMods.thrusterSpeed.float / 1000.0,
      "luckChance": config.perkMods.luckChance.float / 1000.0,
      "luckDamage": config.perkMods.luckDamage
    }

proc echoBarrageKeys(config: GameConfig, node: JsonNode) =
  ## Echo the barrage keys only when the mode is on, so a default game's
  ## replay config stays byte-identical to the pre-barrage echo.
  if config.barrageMaxPerSec > 0:
    node["barrageMaxPerSec"] = %config.barrageMaxPerSec
    node["barrageStartPerSec"] = %config.barrageStartPerSec
    node["barrageStartSec"] = %config.barrageStartSec
    node["barrageSaturateSec"] = %config.barrageSaturateSec

proc echoSeatCountKey(config: GameConfig, node: JsonNode) =
  ## Echo `num_agents` whenever a config sets it, paintball or not.
  ##
  ## The seat count is not just seating plumbing: gameHash keys the
  ## needsReregister mix on `numAgents == 0`, playback keys its leave
  ## handling and between-games archive on `numAgents > 0`, resetToLobby
  ## keys the tick-counter reset on it, and the per-seat results collapse
  ## folds cogs onto seats by it. Every hosted classic variant sets
  ## num_agents so the platform can seat policies, and until this echo
  ## existed the recording dropped it — playback rebuilt the config with
  ## numAgents == 0 and re-simulated a structurally different game, so every
  ## hosted replay failed its hash check at tick 1 (found on a Season 2
  ## league episode; reproduced by tests/fixtures/seats-numagents16.bitreplay).
  ## Default-only (numAgents == 0) configs echo nothing here, so the classic
  ## fixtures' headers stay byte-identical.
  if config.numAgents != 0:
    node["num_agents"] = %config.numAgents

proc echoPaintballKeys(config: GameConfig, node: JsonNode) =
  ## Echo the paintball keys only when the mode is engaged, so a classic
  ## game's replay config stays byte-identical to pre-paintball builds. When
  ## the mode IS on, echo every key: the wasm viewer re-derives the paint grid
  ## and the hill from this config, so a missing key would re-simulate a
  ## different game.
  ##
  ## NOT `numAgents > 0`: every flagship classic variant now sets num_agents
  ## to a nonzero seat count for an unrelated squad/seat-broadcast reason
  ## (see playerResultsJson's comment in roster.nim), so that term went from
  ## "paintball is on" to "any classic squad game" and started echoing the
  ## whole paintball key set into byte-identical-by-design classic replay
  ## configs. `loadout != LoadoutCtf` already covers every real paintball
  ## config (loadout is only ever LoadoutCtf or LoadoutPaintball), so the
  ## numAgents disjunct was always redundant for a genuine paintball game
  ## and only ever fired spuriously for a classic one — dropping it changes
  ## nothing for paintball and restores the byte-identical guarantee for
  ## classic squad games. The seat count itself still has to reach the
  ## recording: echoSeatCountKey below carries `num_agents` on its own,
  ## because playback semantics depend on it (see that proc).
  let paintballOn = config.loadout != LoadoutCtf or config.floorPaint or
    config.hill
  if paintballOn:
    node["num_agents"] = %config.numAgents
    node["cogsPerTeam"] = %config.cogsPerTeam
    node["loadout"] = %config.loadout
    node["floorPaint"] = %config.floorPaint
    node["paintBuff"] = %config.paintBuff
    node["hill"] = %config.hill
    node["paintTile"] = %config.paintTile
    node["hillRadiusTiles"] = %config.hillRadiusTiles
    node["hillOwnPermille"] = %config.hillOwnPermille
    node["hillDecisiveTicks"] = %config.hillDecisiveTicks
    node["paintSpeedOwnPct"] = %config.paintSpeedOwnPct
    node["paintSpeedEnemyPct"] = %config.paintSpeedEnemyPct
    node["paintHealTicks"] = %config.paintHealTicks
    node["turnTicks"] = %config.turnTicks
    node["turnBudgetMs"] = %config.turnBudgetMs
    node["attempt1Ms"] = %config.attempt1Ms
    node["retryMs"] = %config.retryMs
    node["turnSpacingMs"] = %config.turnSpacingMs
    node["wallClockBudgetSeconds"] = %config.wallClockBudgetSeconds
    node["maxOutputTokens"] = %config.maxOutputTokens
    node["regimes"] = (block:
      var arr = newJArray()
      for regime in config.regimes:
        arr.add(%regimeText(regime))
      arr)
    if config.model.len > 0:
      node["model"] = %config.model
  # sprayDamage acts in every mode (the spray cone reads it wherever it
  # fires), so like puddleDamagePct it is pinned whenever it departs from
  # its default even with the paintball gates off.
  if paintballOn or config.sprayDamage != SprayPaintDamage:
    node["sprayDamage"] = %config.sprayDamage

proc echoZonePhaseKeys(config: GameConfig, node: JsonNode) =
  ## Echo the zone schedule only when configured, so a zone-free game's
  ## replay config stays byte-identical to a build without the field — the
  ## same rule as echoBarrageKeys above. z is echoed back in its authored
  ## 0..1 float form (permille / 1000.0), not the internal permille.
  if config.zonePhases.len > 0:
    var zonePhases = newJArray()
    for phase in config.zonePhases:
      zonePhases.add(%*{
        "z": phase.zPermille.float / 1000.0,
        "waitTicks": phase.waitTicks,
        "shrinkTicks": phase.shrinkTicks,
        "dps": phase.dps
      })
    node["zonePhases"] = zonePhases

proc echoZoneCenterKeys(config: GameConfig, node: JsonNode) =
  ## Echo the authored center only when configured, so a random-draw game's
  ## replay config stays byte-identical to a build without the field — same
  ## rule as echoZonePhaseKeys/echoBarrageKeys above.
  if config.zoneCenterConfigured:
    node["zoneCenter"] = %*[config.zoneCenterX, config.zoneCenterY]

proc echoMapSpecKeys(config: GameConfig, node: JsonNode) =
  ## Echo the expanded map geometry only when one was pinned at config
  ## parse (generated maps only — see `update`'s mapSpec resolution).
  if config.mapSpec.len > 0:
    node["mapSpec"] = fromJson(config.mapSpec)

proc echoBrModeKeys(config: GameConfig, node: JsonNode) =
  ## GVNEXT(elim): echo only when on, so an off (default) game's replay
  ## config stays byte-identical to a pre-BR build's echo.
  if config.brMode:
    node["brMode"] = %config.brMode

proc echoSeatTakeoverKeys(config: GameConfig, node: JsonNode) =
  ## Same rule for seat takeover: echoed only when the freeplay mode is on,
  ## so a league game's replay config stays byte-identical to pre-takeover
  ## builds.
  if config.allowSeatTakeover:
    node["allowSeatTakeover"] = %config.allowSeatTakeover

proc echoAimKeys(config: GameConfig, node: JsonNode) =
  ## Direct aim moves what the ENGINE does with a human's packets, so a
  ## replay that contains it must say so in its own header: this key is how
  ## a PLAY replay self-identifies as one no policy could have produced.
  ## Off, the key is absent and a league replay's config stays
  ## byte-identical.
  if config.allowDirectAim:
    node["allowDirectAim"] = %config.allowDirectAim
  # Same rule for aim assist: echoed (both keys, so a replay never has to
  # guess the cone width the mode ran with) only when the mode is on, so a
  # league — or an assist-free freeplay — replay's config stays
  # byte-identical to a pre-assist build.
  if config.allowAimAssist:
    node["allowAimAssist"] = %config.allowAimAssist
    node["aimAssistConeBrads"] = %config.aimAssistConeBrads

# ---------------------------------------------------------------------------
# echoCalloutKeys — deliberately its OWN named proc, not a tail-appended
# `if` inline in configJson below. sim_config.nim's tail-append style has
# silently lost adjacent lines in conflict resolutions before; a sibling
# lane (maxwell/configjson-harden) is mid-refactor turning every optional
# echo into exactly this named-proc shape (echoBarrageKeys, echoZonePhase-
# Keys, echoSeatTakeoverKeys, ...) so a new feature's diff is "add a proc +
# one call line", never an edit squeezed into another feature's tail. This
# one is written in that target shape now so the eventual rebase onto
# maxwell/br-demo-assembly is a pure move, not a rewrite.
# ---------------------------------------------------------------------------
proc echoCalloutKeys(config: GameConfig, node: JsonNode) =
  ## Echo the callout gate only when it is on, so an allowCallouts-off
  ## game's replay config stays byte-identical to a build without the
  ## field — same rule as echoSeatTakeoverKeys/echoBrModeKeys above.
  if config.allowCallouts:
    node["allowCallouts"] = %config.allowCallouts

proc echoPolicyReflashKeys(config: GameConfig, node: JsonNode) =
  ## Echo the one-page-policy reflash gate only when it is on.
  ##
  ## The header config IS the provenance, exactly as it is for direct aim
  ## (echoAimKeys): a replay whose cogs were re-strategized mid-episode has
  ## to be readable as one without trusting the filename or the fleet that
  ## made it — and, just as load-bearing, gate-OFF the key is absent, so a
  ## league replay's config JSON stays byte-identical to a build that never
  ## had the field.
  ##
  ## This is also the whole of the "version bump": the replay FORMAT version
  ## is deliberately NOT bumped (see replays.nim's reflash-record block for
  ## why a bump would destroy every archived replay), so a reader tells a
  ## reflash-carrying replay from a plain one by this key, not by a number
  ## in the header.
  if config.allowPolicyReflash:
    node["allowPolicyReflash"] = %config.allowPolicyReflash

proc echoShellKeys(config: GameConfig, node: JsonNode) =
  ## Echo the play-calling shell keys only when they depart from their defaults.
  ## `season2Shell` is now default-on and echoes only when explicitly false;
  ## `allowDeprecatedModes` echoes only when true. This keeps existing replay
  ## headers byte-identical until a live legacy recorder intentionally opts in.
  ## `voteTicks`'s OWN default is 0 (unlike the other three, whose shipped
  ## defaults are nonzero) — see VoteTicksDefault's comment (sim_types.nim)
  ## for why the vote phase does not mirror lobbyChatTicks's always-on
  ## default; the `!= 0` comparison below is therefore comparing against
  ## this field's true zero value in both branches, not a shipped constant.
  if not config.season2Shell:
    node["season2Shell"] = %false
  if config.allowDeprecatedModes:
    node["allowDeprecatedModes"] = %true
  if config.viewIntervalTicks != ViewIntervalTicksDefault:
    node["viewIntervalTicks"] = %config.viewIntervalTicks
  if config.lobbyChatTicks != LobbyChatTicksDefault:
    node["lobbyChatTicks"] = %config.lobbyChatTicks
  if config.playSeatBindTicks != PlaySeatBindTicksDefault:
    node["playSeatBindTicks"] = %config.playSeatBindTicks
  if config.voteTicks != 0:
    node["voteTicks"] = %config.voteTicks
  ## MAP VOTE (S2): the pinned ballot candidates, echoed only when the
  ## ballot exists at all — a voteTicks-off (or non-brpool) game's replay
  ## config stays byte-identical to a build without the field.
  if config.voteMapSpecs.len > 0:
    let specs = newJArray()
    for spec in config.voteMapSpecs:
      specs.add fromJson(spec)
    node["voteMapSpecs"] = specs

proc echoShotFeedbackKeys(config: GameConfig, node: JsonNode) =
  ## Echo the shot-feedback gate only when it is on, so an
  ## allowShotFeedback-off game's replay config stays byte-identical to a
  ## build without the field — same rule as echoCalloutKeys/
  ## echoSeatTakeoverKeys above. Own named proc (not a tail-append inline in
  ## configJson), for the same conflict-safety reason echoCalloutKeys is —
  ## the echo-drop hazard this file's history already hit twice.
  if config.allowShotFeedback:
    node["allowShotFeedback"] = %config.allowShotFeedback

proc echoCosmeticFxKeys(config: GameConfig, node: JsonNode) =
  ## Echo the cosmetic-fx gate only when it is on, so an allowCosmeticFx-off
  ## game's replay config stays byte-identical to a build without the field
  ## — same rule as echoShotFeedbackKeys/echoCalloutKeys above.
  if config.allowCosmeticFx:
    node["allowCosmeticFx"] = %config.allowCosmeticFx

proc echoHealingKeys(config: GameConfig, node: JsonNode) =
  ## LOOT(s2): the healing-item knobs, echoed only when they depart from
  ## their dark defaults — same byte-identity rule as every echo above.
  if config.medKitCount != -1:
    node["medKitCount"] = %config.medKitCount
  if config.bandagePickups > 0:
    node["bandagePickups"] = %config.bandagePickups

proc echoLootStartKeys(config: GameConfig, node: JsonNode) =
  ## LOOT(s2): the unarmed-spawn gate, echoed only when on.
  if config.lootStart:
    node["lootStart"] = %config.lootStart

proc echoDownedKeys(config: GameConfig, node: JsonNode) =
  ## LOOT(s2): the downed-state gate and its timing knobs. The knobs ride
  ## the gate: a downedMode-off game echoes none of them (they are also only
  ## READ under the gate), so the dark echo stays byte-identical while an
  ## armed replay pins the exact windows it played under.
  if config.downedMode:
    node["downedMode"] = %config.downedMode
    node["downedBleedOutTicks"] = %config.downedBleedOutTicks
    node["downedReviveTicks"] = %config.downedReviveTicks
    node["downedEscalation"] = %config.downedEscalation

proc echoGiveItemKeys(config: GameConfig, node: JsonNode) =
  ## GIVE(s2): the play-called exchange gate, echoed only when on — same
  ## byte-identity rule as every echo above. The channel's range and length
  ## are compile-time derivations of the revive channel's constants
  ## (GiveItemRange/GiveChannelTicks, sim_types.nim), not knobs, so the
  ## gate is the only key.
  if config.giveItem:
    node["giveItem"] = %config.giveItem

proc echoDropItemKeys(config: GameConfig, node: JsonNode) =
  ## DROP(s2): the button-chord item-drop gate, echoed only when on — same
  ## byte-identity rule as every echo above. The chord length, pickup radius
  ## and re-grab delay are compile-time constants (DropChordTicks /
  ## DroppedPickupRange / DropperRegrabTicks, sim_types.nim), not knobs, so
  ## the gate is the only key.
  if config.dropItem:
    node["dropItem"] = %config.dropItem

proc echoRecutKeys(config: GameConfig, node: JsonNode) =
  ## RECUT(v13): the multiplier-recut gate, echoed only when armed — same
  ## byte-identity rule as every echo above. An armed replay's header pins
  ## the economy it actually played under; a dark echo carries nothing.
  if config.gloryMultiplierRecut:
    node["gloryMultiplierRecut"] = %config.gloryMultiplierRecut
  # §A6 (winAsMultiplier): same armed-only echo rule — a dark echo
  # carries nothing; an armed replay's header pins the win-factor world.
  if config.winAsMultiplier:
    node["winAsMultiplier"] = %config.winAsMultiplier
  # MINTCAP: same armed-only echo rule — an armed replay's header pins
  # whether the episode played under bounded mints, which is the one fact
  # an offline audit of a suspicious score needs first.
  if config.deedMintCaps:
    node["deedMintCaps"] = %config.deedMintCaps

proc echoStampKeys(config: GameConfig, node: JsonNode) =
  ## STAMP(recut contract Amendment 2 §2): the stamp gate and the variant
  ## label, echoed only on departure from their dark defaults. The
  ## variantId echoes on its own (a labelled-but-unstamped config still
  ## records which variant published it — the label is observability
  ## either way, and byte-identity only requires ABSENT keys to stay
  ## absent).
  if config.stampRealizedConfig:
    node["stampRealizedConfig"] = %config.stampRealizedConfig
  if config.variantId.len > 0:
    node["variantId"] = %config.variantId

proc echoSpawnLootSeedKeys(config: GameConfig, node: JsonNode) =
  ## SPAWNLOOT: the spawn-cluster crate-seeding knobs, echoed only when at
  ## least one count departs from its dark default — same byte-identity
  ## rule as every echo above. The radius rides the counts (only echoed
  ## alongside them, matching the "knobs ride the gate" idiom
  ## echoDownedKeys already uses): it is also only READ while a count is
  ## positive, so a dark echo never carries it either.
  if config.lootSpawnSeedGuns > 0 or config.lootSpawnSeedHoppers > 0:
    node["lootSpawnSeedGuns"] = %config.lootSpawnSeedGuns
    node["lootSpawnSeedHoppers"] = %config.lootSpawnSeedHoppers
    node["lootSpawnSeedRadius"] = %config.lootSpawnSeedRadius

proc echoHopperSiteKeys(config: GameConfig, node: JsonNode) =
  ## SITECLASS: the hopper fallback's site-class weighting, echoed only when
  ## it departs from the dark default — same byte-identity rule as every
  ## echo above, so a dark config's JSON is unchanged.
  if config.hopperSiteTrafficPermille > 0:
    node["hopperSiteTrafficPermille"] = %config.hopperSiteTrafficPermille

proc echoFrameLoadoutKeys(config: GameConfig, node: JsonNode) =
  ## PERCEPTION(glory-2 §17): the frame loadout-flag exposure gate, echoed
  ## only when armed — same byte-identity rule as every echo above.
  if config.frameLoadoutFlags:
    node["frameLoadoutFlags"] = %config.frameLoadoutFlags
proc echoZonePaintKeys(config: GameConfig, node: JsonNode) =
  ## ZONEPAINT: the paint-damage gate and its downed-bleed knob. The knob
  ## rides the gate (echoDownedKeys' idiom — it is also only READ under the
  ## gate): a flag-off game echoes neither key, so the dark echo stays
  ## byte-identical while an armed replay pins the exact acceleration it
  ## played under.
  if config.zoneDamageByPaint:
    node["zoneDamageByPaint"] = %config.zoneDamageByPaint
    node["zonePaintDownedBleedPermille"] =
      %config.zonePaintDownedBleedPermille
  # PAINTDEATH: echoed only when armed (it rides zoneDamageByPaint by
  # validation, but the echo names it on its own so a replay pins WHICH of
  # the two paint-on-ghost rules it played under).
  if config.zoneBlocksRevive:
    node["zoneBlocksRevive"] = %config.zoneBlocksRevive

proc configJson*(config: GameConfig): string =
  ## Returns the complete replay JSON for a gameplay config: the always-
  ## present base keys, built as one object literal below, followed by one
  ## call per OPTIONAL feature's echo (each a small named proc above, so a
  ## new feature's diff is a new proc + one call line here, never an edit
  ## squeezed into this shared tail alongside an unrelated feature's own
  ## edit). `result = $node` is the very last line ON PURPOSE: an explicit,
  ## marked assignment — not a bare trailing expression — so it reads as
  ## this function's return in a diff/merge, not as one more tail line.
  var
    players = newJArray()
    slots = newJArray()
    tokens = newJArray()
    includePlayers = false
  for slot in config.slots:
    var item = newJObject()
    if slot.name.len > 0:
      includePlayers = true
    tokens.add(%slot.token)
    players.add(%*{"name": slot.name})
    if slot.hasTeam:
      item["team"] = %slot.slotTeamText()
    if slot.hasColor:
      item["color"] = %slot.slotColorText()
    if slot.skin != DefaultSkin:
      item["skin"] = %slot.skin.skinText()
    if slot.control == scPlay:
      item["control"] = %"play"
    slots.add(item)
  var node = %*{
    "motionScale": config.motionScale,
    "accel": config.accel,
    "frictionNum": config.frictionNum,
    "frictionDen": config.frictionDen,
    "maxSpeed": config.maxSpeed,
    "stopThreshold": config.stopThreshold,
    "playerBouncePct": config.playerBouncePct,
    "seed": config.seed,
    "speed": config.speed,
    "lives": config.lives,
    "hitPoints": config.hitPoints,
    "respawnTicks": config.respawnTicks,
    "gunRange": config.gunRange,
    "fireCooldownTicks": config.fireCooldownTicks,
    "fireWindupTicks": config.fireWindupTicks,
    "carrierSpeedPct": config.carrierSpeedPct,
    "aimTurnRate": config.aimTurnRate,
    "visionConeDeg": config.visionConeDeg,
    "visionBubble": config.visionBubble,
    "minPlayers": config.minPlayers,
    "startWaitTicks": config.startWaitTicks,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "gameOverTicks": config.gameOverTicks,
    "maxTicks": config.maxTicks,
    "maxGameTicks": config.maxTicks,
    "maxGames": config.maxGames,
    "mapPath": config.mapPath,
    "mapSeed": config.mapSeed,
    "mapPoolIndex": config.mapPoolIndex,
    "mapSize": config.mapGen.size,
    "mapSymmetry": config.mapGen.symmetry,
    "mapColumns": config.mapGen.columns,
    "mapWindows": config.mapGen.windows,
    "mapPits": config.mapGen.pits,
    "mapPitDensity": config.mapGen.pitDensity,
    "mapCenterFeature": config.mapGen.centerFeature,
    "mapLayout": config.mapGen.layout,
    "mapEndzone": config.mapGen.endzone,
    "mapEndzoneRadius": config.mapGen.endzoneRadius,
    "mapBaseDepth": config.mapGen.baseDepth,
    "closedRoster": config.closedRoster,
    "showPlayerLabels": config.showPlayerLabels,
    "fastMode": config.fastMode,
    "teams": config.teams,
    "scoring": config.scoring,
    "tokens": tokens,
    "slots": slots
  }
  if includePlayers:
    node["players"] = players
  echoPuddleKeys(config, node)
  echoBarrierKeys(config, node)
  echoSeatCountKey(config, node)
  echoPaintballKeys(config, node)
  echoHandicapKeys(config, node)
  echoPerkKeys(config, node)
  echoPerkModKeys(config, node)
  echoBarrageKeys(config, node)
  echoZonePhaseKeys(config, node)
  echoZoneCenterKeys(config, node)
  echoMapSpecKeys(config, node)
  echoBrModeKeys(config, node)
  echoSeatTakeoverKeys(config, node)
  echoAimKeys(config, node)
  echoCalloutKeys(config, node)
  echoPolicyReflashKeys(config, node)
  echoShellKeys(config, node)
  echoShotFeedbackKeys(config, node)
  echoCosmeticFxKeys(config, node)
  echoHealingKeys(config, node)
  echoLootStartKeys(config, node)
  echoDownedKeys(config, node)
  echoGiveItemKeys(config, node)
  echoDropItemKeys(config, node)
  echoRecutKeys(config, node)
  echoStampKeys(config, node)
  echoSpawnLootSeedKeys(config, node)
  echoHopperSiteKeys(config, node)
  echoFrameLoadoutKeys(config, node)
  echoZonePaintKeys(config, node)
  result = $node

proc realizedConfigStampJson*(config: GameConfig): string =
  ## STAMP (recut contract AMENDMENT 2 §2): the per-episode realized-config
  ## stamp — {realizedBuild, flagSet as SORTED key=value pairs, variantId,
  ## stampVersion}. This is the machine-readable answer to the live hazard
  ## the directive recorded (realized builds/flags oscillating under a
  ## pinned canonical): every consumer reads what ACTUALLY ran, never
  ## assumes canonical (the §7c pinning rule).
  ##
  ## realizedBuild carries BOTH version layers: the hand-bumped GameVersion
  ## and the machine-derived source stamp (`ctfSimSourcesStamp`, empty in
  ## builds that never passed the define — an empty stamp claims nothing,
  ## same rule as build_stamp.nim), plus GloryVersion (the economy table
  ## the episode priced under). flagSet pins the S2 dark-flag family
  ## EXPLICITLY, false values included — a dark episode positively records
  ## its darkness, which is the whole point.
  ##
  ## Engine-side homes (emitted at finalize when `stampRealizedConfig` is
  ## armed): the events sink and the game-over log line (server.nim/
  ## sim.nim). The episode-attributes API upload is the league-side
  ## reporter's to make from those homes — the engine has no attributes
  ## channel (bitworld runtime carries results/replay/log only) and the
  ## results document is schema-closed. The replay header already pins the
  ## same facts through the config echo + engineStamp (replay_codec.nim),
  ## which serves as the amendment's replay-manifest secondary copy.
  var flags: seq[string] = @[
    "bandagePickups=" & $config.bandagePickups,
    "brMode=" & $config.brMode,
    "deedMintCaps=" & $config.deedMintCaps,
    "downedEscalation=" & $config.downedEscalation,
    "downedMode=" & $config.downedMode,
    "frameLoadoutFlags=" & $config.frameLoadoutFlags,
    "gloryMultiplierRecut=" & $config.gloryMultiplierRecut,
    "hopperSiteTrafficPermille=" & $config.hopperSiteTrafficPermille,
    "lootStart=" & $config.lootStart,
    "winAsMultiplier=" & $config.winAsMultiplier,
    "medKitCount=" & $config.medKitCount,
    "stampRealizedConfig=" & $config.stampRealizedConfig,
    "zoneBlocksRevive=" & $config.zoneBlocksRevive,
    "zoneDamageByPaint=" & $config.zoneDamageByPaint,
  ]
  flags.sort()
  var flagSet = newJArray()
  for f in flags:
    flagSet.add(%f)
  let node = %*{
    "stampVersion": 1,
    "realizedBuild": {
      "gameVersion": GameVersion,
      "gloryVersion": GloryVersion,
      "engineStamp": ctfSimSourcesStamp
    },
    "variantId": config.variantId,
    "flagSet": flagSet
  }
  $node
