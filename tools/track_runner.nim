import
  std/[json, os, strformat, strutils, tables],
  ../src/ctf/replays,
  ../src/ctf/sim

const GameDir = currentSourcePath().parentDir().parentDir()

proc replayConfig(data: ReplayData): GameConfig =
  result = defaultGameConfig()
  result.update(data.configJson)

proc slotLabel(sim: SimServer, slot: int): string =
  for p in sim.players:
    if p.joinOrder == slot:
      return $p.team & " " & p.address
  "slot" & $slot

proc trackRunner(path: string, targetSlot: int) =
  if not fileExists(path):
    quit("File does not exist: " & path)

  let data = loadReplay(path)
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)

  try:
    var
      sim = initSimServer(data.replayConfig())
      replay = initReplayPlayer(data)
      slotToIndex: Table[int, int]
      playingStart = -1
      stealTick = -1
      runnerCarries = false
      prevCaps = 0

    sim.gameEventLoggingEnabled = false
    replay.looping = false
    replay.mismatchQuit = false

    echo &"# Tracking {path}"
    echo &"# Target slot: {targetSlot}"
    echo ""

    while replay.playing:
      let tick = sim.tickCount + 1
      try:
        replay.stepReplay(sim)
      except ReplayError:
        break

      # Build slot→index mapping
      for i, p in sim.players:
        slotToIndex[p.joinOrder] = i

      # Mark Playing start
      if playingStart < 0 and sim.phase == Playing:
        playingStart = tick
        let label = slotLabel(sim, targetSlot)
        echo &"# Playing starts at tick {tick}"
        echo &"# Runner: {label}"
        echo &"# tick\tx\ty\tcarrying\talive"
        echo ""

      # Track target slot
      if targetSlot notin slotToIndex:
        continue

      let idx = slotToIndex[targetSlot]
      let p = sim.players[idx]

      # Detect steal/cap
      let nowCarries = p.carryingFlag
      if nowCarries and not runnerCarries:
        stealTick = tick
        echo &"# STEAL at tick {tick} (Playing+{tick - playingStart})"

      if p.captures > prevCaps:
        echo &"# CAPTURE at tick {tick} (Playing+{tick - playingStart}, steal→cap {tick - stealTick}t)"
      prevCaps = p.captures

      if not nowCarries and runnerCarries and stealTick > 0 and prevCaps == 0:
        echo &"# FLAG LOST at tick {tick} (carrier killed)"
        stealTick = -1

      runnerCarries = nowCarries

      # Emit position every 12 ticks (0.5s) after Playing starts
      if playingStart > 0 and (tick - playingStart) mod 12 == 0:
        let carryLabel = if nowCarries: "YES" else: "NO"
        let aliveLabel = if p.alive: "alive" else: "dead"
        echo &"{tick}\t{p.x}\t{p.y}\t{carryLabel}\t{aliveLabel}"

  finally:
    setCurrentDir(previousDir)

when isMainModule:
  if paramCount() < 2:
    quit("Usage: track_runner <replay> <slot>")
  let path = paramStr(1)
  let slot = parseInt(paramStr(2))
  trackRunner(path, slot)
