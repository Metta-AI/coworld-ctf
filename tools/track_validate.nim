## track_validate — does the track_census sighting model match the REAL wire?
##
## track_census derives each seat's sighting stream from `sim.playerVisibleTo`.
## The policy derives it from `player <color> <side>` sprite LABELS on the wire.
## This tool builds the ACTUAL per-player sprite packet (a fresh viewer state
## each sampled tick, so every packet is FULL rather than a delta), parses it,
## and compares the label-derived enemy count against the playerVisibleTo count
## on the same tick. It also counts `corpse ` labels, to settle whether a LIVE
## viewer ever receives one (the v48 kill-release reads them).
import
  std/[json, os, strutils],
  ../src/ctf/[sim, sim_types, sim_state, global],
  toolutil

proc runOne(path: string, sampleEvery: int): JsonNode =
  var (game, replay) = openReplay(path.absolutePath(), mismatchQuit = false)
  var slotCount = game.config.slots.len
  if slotCount == 0: slotCount = game.config.playerSlotLimit()
  var
    checks = 0
    agree = 0
    labelSum = 0
    modelSum = 0
    corpseLiveViewer = 0
    corpseGhostViewer = 0
    liveViewerTicks = 0
    ghostViewerTicks = 0
    worstDiff = 0
  while replay.playing:
    replay.stepReplay(game)
    if game.phase != Playing: continue
    if game.tickCount mod sampleEvery != 0: continue
    for index in 0 ..< game.players.len:
      if game.players[index].joinOrder < 0: continue
      let ghost = not game.players[index].alive
      # --- the model ----------------------------------------------------
      if not ghost: discard game.refreshPlayerFov(index)
      var model = 0
      for o in 0 ..< game.players.len:
        if o == index or not game.players[o].alive: continue
        if game.players[o].team == game.players[index].team: continue
        if ghost or game.playerVisibleTo(index, o): inc model
      # --- the wire -----------------------------------------------------
      var st = initPlayerViewerState()
      var nxt: PlayerViewerState
      new(nxt)
      let msgs = game.buildSpriteProtocolPlayerUpdates(index, st, nxt, true)
        .parseSpritePacket()
      var labelById: seq[tuple[id: int, label: string]]
      for m in msgs:
        if m.kind == spkSprite:
          labelById.add((m.sprite.id, m.sprite.label))
      proc labelOf(id: int): string =
        for l in labelById:
          if l.id == id: return l.label
        ""
      var wire = 0
      var corpses = 0
      let myColor = teamText(game.players[index].team)
      for m in msgs:
        if m.kind != spkObject: continue
        let lbl = labelOf(m.objectDef.spriteId)
        if lbl.startsWith("corpse "): inc corpses
        elif lbl.startsWith("player "):
          let toks = lbl.split(' ')
          if toks.len >= 2 and toks[1] != myColor: inc wire
      if ghost:
        inc ghostViewerTicks
        corpseGhostViewer += corpses
      else:
        inc liveViewerTicks
        corpseLiveViewer += corpses
        inc checks
        labelSum += wire
        modelSum += model
        if wire == model: inc agree
        elif abs(wire - model) > worstDiff: worstDiff = abs(wire - model)
  %*{
    "replay": path.extractFilename(),
    "checks": checks, "agree": agree,
    "label_sum": labelSum, "model_sum": modelSum, "worst_diff": worstDiff,
    "live_viewer_ticks": liveViewerTicks, "corpse_labels_live_viewer": corpseLiveViewer,
    "ghost_viewer_ticks": ghostViewerTicks, "corpse_labels_ghost_viewer": corpseGhostViewer
  }

when isMainModule:
  chdirGameDir()
  let every = if existsEnv("SAMPLE"): parseInt(getEnv("SAMPLE")) else: 37
  for i in 1 .. paramCount():
    echo $runOne(paramStr(i), every)
