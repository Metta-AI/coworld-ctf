## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with (playback speeds, fps, the chrome sprite id, shot
## FX tuning). Historically each HTML client re-typed these as literals and
## nothing enforced agreement — a retuned PlaybackSpeeds would silently
## desync every client. This module renders them ONCE, from the same Nim
## consts the engine runs on; server.nim splices the block into every served
## client page, and tools/gen_wire_constants.nim emits it for the static
## wasm bundle. Clients read `window.CTF_WIRE` and keep their old literals
## only as fallbacks for raw file:// opens of the un-spliced sources.

import std/strutils
import sim, global, sim_types

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

proc hex2(v: uint8): string =
  const Digits = "0123456789abcdef"
  result = newString(2)
  result[0] = Digits[int(v shr 4)]
  result[1] = Digits[int(v and 0x0f'u8)]

const TeamColorsJs = block:
  ## Every team's chip colour, DERIVED from the enum rather than re-typed in
  ## each chrome. The browser chromes carried a 4-entry literal table and
  ## returned null for anything else, so on a 16-team BR board twelve teams
  ## drew with the fallback amber and the scoreboard could not tell plum from
  ## azure from lime — the BR_MAPGEN.md §6.2 "literal 4-multiplier" hazard,
  ## in the one place §6.2 did not look (the JS chrome, not the sprite pools).
  ##
  ## teamEndzoneColor is the right source: it is already the single collapsed
  ## team->tint anchor (map_art, global and sim_state all read it), and for
  ## red/blue/green/yellow it returns EXACTLY the four hex literals the
  ## chromes used, so the classic chrome is unchanged to the byte.
  var s = "{"
  for team in Team:
    if ord(team) > 0: s.add ","
    let c = teamEndzoneColor(team)
    s.add teamText(team) & ":\"#" & hex2(c.r) & hex2(c.g) & hex2(c.b) & "\""
  s.add "}"
  s

const WireConstantsJs* =
  "window.CTF_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
  ",teamColors:" & TeamColorsJs &
  ",teamOrder:[" & (block:
    var s = ""
    for team in Team:
      if ord(team) > 0: s.add ","
      s.add "\"" & teamText(team) & "\""
    s) & "]" &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",shotFxTicks:" & $ShotFxTicks &
  ",shotTrailFalloff:" & $TrailFalloff &
  ",zoneArrivalFieldSpriteId:" & $ZoneArrivalFieldSpriteId &
  ",zoneClockObjectId:" & $ZoneClockObjectId &
  ",zoneFieldCellPx:" & $ZoneFieldCellPx &
  ",zonePaintBody:\"#" & hex2(ZonePaintBody.r) & hex2(ZonePaintBody.g) &
    hex2(ZonePaintBody.b) & "\"" &
  # SEASON 2: the glory cosmetic-pop lifetimes (`gloryPopsJson`'s "t"/"delay"
  # are engine ticks; a client fading a pop by age needs these to never
  # drift from `pruneAgedFx`'s own call site, sim.nim) and the achievement
  # curriculum's total tier count (Tree.len * AchievementTiers), so the
  # endcard's "N/40" denominator can never go stale against a future
  # curriculum change without a client rebuild picking it back up.
  ",gloryFxTicks:" & $GloryFxTicks &
  ",achievementFxTicks:" & $AchievementFxTicks &
  ",achievementTotal:" & $((ord(high(Tree)) + 1) * AchievementTiers) &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder both client HTML files carry where the block belongs
  ## (before any script that reads window.CTF_WIRE).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
