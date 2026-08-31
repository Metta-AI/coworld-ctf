## Test-only WASM probe for the allocation-free SDK view reader.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"overlay\",\"doc\":\"test-only SDK view reader probe\",\"modes\":[\"br\"],\"name\":\"view_probe\",\"params\":{},\"retune\":true}"

var decodedOk: bool

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc teamOk(value: SdkTeam; expected: SdkTeam): bool =
  value == expected

proc goldenOk(v: SdkView): bool =
  result = v.valid and v.tickPresent and v.tick == 1441 and
    v.epochPresent and v.epoch == 4 and
    v.self.pos.present and v.self.pos.x == 512 and v.self.pos.y == 288 and
    v.self.hpPresent and v.self.hp == 2 and
    v.self.hpFracPresent and v.self.hpFracScaled == 666666 and
    v.self.aimPresent and v.self.aimBrads == 32 and
    v.self.alivePresent and v.self.alive and
    v.world.aliveTeamsPresent and v.world.aliveTeams == 9 and
    v.world.zone.phasePresent and v.world.zone.phase == 2 and
    v.world.zone.current.present and v.world.zone.current.x1 == 400 and
    v.world.zone.current.y1 == 200 and v.world.zone.current.x2 == 1600 and
    v.world.zone.current.y2 == 900 and
    v.world.zone.ticksToShrinkPresent and
    v.world.zone.ticksToShrink == 240 and
    v.trackCount == 2 and
    v.tracks[0].seatPresent and v.tracks[0].seat == 0 and
    v.tracks[0].teamPresent and teamOk(v.tracks[0].team, stNavy) and
    v.tracks[0].pos.present and v.tracks[0].pos.x == 520 and
    v.tracks[0].pos.y == 300 and
    v.tracks[0].freshTickPresent and v.tracks[0].freshTick == 1441 and
    v.tracks[0].hpPresent and v.tracks[0].hp == 3 and
    v.tracks[0].aimPresent and v.tracks[0].aimBrads == 96 and
    not v.tracks[0].bountyPresent and
    v.tracks[1].seatPresent and v.tracks[1].seat == 7 and
    v.tracks[1].teamPresent and teamOk(v.tracks[1].team, stRust) and
    v.tracks[1].pos.present and v.tracks[1].pos.x == 900 and
    v.tracks[1].pos.y == 400 and
    v.tracks[1].freshTickPresent and v.tracks[1].freshTick == 1380 and
    not v.tracks[1].hpPresent and not v.tracks[1].aimPresent and
    v.tracks[1].bountyPresent and v.tracks[1].bounty and
    v.aggressorCount == 1 and v.aggressors[0].tickPresent and
    v.aggressors[0].tick == 1400 and v.aggressors[0].dirPresent and
    v.aggressors[0].dirBrads == 64 and not v.aggressors[0].seatPresent and
    v.killFeedCount == 1 and v.killFeed[0].tickPresent and
    v.killFeed[0].tick == 1390 and v.killFeed[0].killerTeamPresent and
    teamOk(v.killFeed[0].killerTeam, stRust) and
    v.killFeed[0].victimSeatPresent and v.killFeed[0].victimSeat == 12

proc absentOk(v: SdkView): bool =
  result = v.valid and v.aggressorCount == 2 and
    v.aggressors[0].seatPresent and v.aggressors[0].seat == 0 and
    not v.aggressors[1].seatPresent and
    v.trackCount == 1 and not v.tracks[0].hpPresent and
    not v.tracks[0].bountyPresent

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  discard ctxPtr
  discard ctxLen
  resetArena()
  var decoded: SdkView
  decodedOk = readViewInto(view(paramsPtr, paramsLen), decoded) and
    (goldenOk(decoded) or absentOk(decoded))
  if decodedOk: 0 else: 2

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  discard viewPtr
  discard viewLen
  if decodedOk:
    let code = emitHoldFireOverlay()
    if code < 0:
      return code
    return 0
  2

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  discard newPtr
  discard newLen
  resetArena()
  0
