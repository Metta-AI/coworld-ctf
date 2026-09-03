## The HANDOFF DECLARATION record's determinism contract (S2 give-item,
## §4.1 amendment). Same shape and same reasoning as
## `tests/test_policy_reflash.nim`'s reflash suite, which
## `replays.nim:806-841`'s own comments name as the pattern to mirror:
## `sim.declareHandoff` is an out-of-band input to the episode — nothing in
## the recorded button masks witnesses a declaration — so a replay that
## drops the record re-simulates a match where the exchange never happened.
##
## UNLIKE the reflash record, the declared item itself (`giveDeclItem`,
## `giveProgress`) is deliberately OUTSIDE `gameHash` (sim_types.nim's own
## "GIVE(s2): none of the three fields below enters gameHash" comment, the
## same puddleTicks/hasBarrier rule `hasGun`/`hasHopper`/`bandages` already
## follow) — the design bets that the CONSEQUENCE of holding an item always
## reaches already-hashed state (who can fire, who takes damage) before the
## declaration itself would need to. This suite tests exactly that bet, on
## the real replay codec: a giver loots a marker and a hopper crate (real
## touch pickups, LOOT(s2)), declares both to its duo partner over the real
## `0xc0` chat-stream record, and once the transfer completes the partner's
## first attack press is the observable, HASHED fork point — `canFire`
## (lootStart-gated) flips only if the declaration actually landed.
##
##   POSITIVE  a recorded episode carrying two handoff declarations
##             re-simulates from its own bytes to an identical hash chain.
##   NEGATIVE  the SAME recording, with only the handoff records removed,
##             diverges — at the tick the recipient's first attack press
##             resolves differently (armed vs. still bare-handed).
##
## Position/inventory setup (which crate, which duo partner) is not itself
## a replay-visible event — `centerOn` teleports outside the codec, the
## same convenience `test_loot_rework.nim` uses for every pickup test in
## this codebase (nobody hand-navigates a cog around map geometry for a
## pickup test here). So both the live recording and the resimulation call
## the IDENTICAL scaffolding at the IDENTICAL tick, isolating the one thing
## actually under test — whether the DECLARATION round-trips through the
## real `.bitreplay` codec — from map/collision geometry, which is not this
## suite's concern.

import
  helpers,
  std/[os, sequtils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, replays, sim]

proc centerOn(sim: var SimServer, playerIndex, x, y: int) =
  ## Places one player so its collision CENTER sits at (x, y). Test-only
  ## convenience (arrangement, not mechanism) — the same helper
  ## `test_give_item.nim`/`test_loot_rework.nim` already define locally.
  sim.players[playerIndex].x = x - CollisionW div 2
  sim.players[playerIndex].y = y - CollisionH div 2

proc handoffConfig(): GameConfig =
  result = defaultGameConfig()
  result.brMode = true
  result.giveItem = true
  result.lootStart = true    ## required for a "gun"/"hopper" handoff to
                              ## have anything to transfer — without it
                              ## every seat already holds both, and the
                              ## channel can never find a lacking partner
                              ## (see test_give_item's "full recipient
                              ## blocks the channel").
  result.minPlayers = 4
  result.startWaitTicks = 0

const
  # Generous spacing: real value only matters relative to GiveChannelTicks,
  # which this file does not hardcode (constants derive from the engine
  # seam per PR #379, not from a guess re-typed here).
  PickupWeaponTick = 5   ## giver (0) stands on the marker crate
  PickupHopperTick = 6   ## giver (0) stands on the hopper crate
  ReturnTick = 7         ## giver (0) returns adjacent to its duo partner
  DeclareGunTick = 8     ## declares the marker to the partner
  DeclareHopperTick = DeclareGunTick + GiveChannelTicks + 2
                          ## declared once the gun channel has had time to
                          ## fully complete (interruptible channels need
                          ## the whole span held; +2 is slack, not tuning)
  FireTick = DeclareHopperTick + GiveChannelTicks + 20
                          ## well past the hopper channel's own completion
  TotalTicks = FireTick + 10

proc applyHandoffScaffold(sim: var SimServer, tick: int) =
  ## The non-replay-visible scenario scaffolding, shared byte-for-byte
  ## between the live recording and resimulation passes (see the file
  ## comment): WHERE the giver stands. Called at the identical tick on
  ## both sides, immediately before that tick's `sim.step` — the same
  ## "declare/place before step" ordering the live server and
  ## `applyReplayEvents` both already use for the reflash and (now)
  ## handoff records.
  case tick
  of PickupWeaponTick:
    sim.centerOn(0, sim.weaponSpawns[0].x, sim.weaponSpawns[0].y)
  of PickupHopperTick:
    sim.centerOn(0, sim.hopperSpawns[0].x, sim.hopperSpawns[0].y)
  of ReturnTick:
    let partner = sim.duoPartnerIndex(0)
    sim.centerOn(0, sim.players[partner].x + 15, sim.players[partner].y)
  else:
    discard

type RecordedHandoffEpisode = object
  ## One real recorded episode plus the live-side facts a faithful replay
  ## has to reproduce.
  data: ReplayData
  ticks: int
  finalHash: uint64
  gunTransferred: bool
  hopperTransferred: bool

proc recordHandoffEpisode(path: string): RecordedHandoffEpisode =
  ## Records a real .bitreplay of a scripted 4-seat BR episode: the giver
  ## (seat 0) loots a marker and a hopper crate, declares both to its duo
  ## partner (seat 2), and once both channels complete the partner presses
  ## attack once — written the same order the live server's tick loop
  ## uses: scaffolding/declare/masks BEFORE the step, the hash after it.
  var
    config = handoffConfig()
    sim = initCtfForTest(config)
    writer = openReplayWriter(path, config.configJson())
  defer: writer.closeReplayWriter()
  for i in 0 ..< 4:
    discard sim.addPlayer("p" & $i)
  let partner = sim.duoPartnerIndex(0)
  doAssert partner == 2, "the round-robin duo pairing this test assumes moved"
  for i in 0 ..< sim.players.len:
    writer.writeJoin(tickTime(sim.tickCount), i, sim.players[i].address, i, "")
    writer.lastMasks.add(0)

  var prev = sim.none()
  for tick in 0 ..< TotalTicks:
    applyHandoffScaffold(sim, tick)
    if tick == DeclareGunTick and sim.declareHandoff(0, "gun"):
      writer.writeHandoffDeclaration(tickTime(sim.tickCount), 0, "gun")
    if tick == DeclareHopperTick and sim.declareHandoff(0, "hopper"):
      writer.writeHandoffDeclaration(tickTime(sim.tickCount), 0, "hopper")
    var cur = sim.none()
    if tick == FireTick:
      cur[partner].attack = true
    for i in 0 ..< cur.len:
      writer.writeInputMaskChange(tickTime(sim.tickCount), i, cur[i].encodeInputMask())
    sim.step(cur, prev)
    prev = cur
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
    inc result.ticks

  result.finalHash = sim.gameHash()
  result.gunTransferred = sim.players[partner].hasGun and not sim.players[0].hasGun
  result.hopperTransferred =
    sim.players[partner].hasHopper and not sim.players[0].hasHopper
  writer.closeReplayWriter()
  result.data = parseReplayBytes(readFile(path))

proc resimulateHandoff(data: ReplayData): tuple[
  failed: bool, failTick: int, ticks: int, hash: uint64
] =
  ## Re-simulates one replay from its own recorded config and streams,
  ## applying the identical scaffolding (see applyHandoffScaffold) at the
  ## identical tick, and reporting where (if anywhere) the hash chain
  ## broke.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var replayConfig = defaultGameConfig()
    replayConfig.update(data.configJson)
    var sim = initSimServer(replayConfig)
    sim.gameEventLoggingEnabled = false
    var player = initReplayPlayer(data)
    player.looping = false
    player.mismatchQuit = false
    result.failTick = -1
    while sim.tickCount < player.replayMaxTick() and
        not player.hashValidationFailed:
      applyHandoffScaffold(sim, sim.tickCount)
      player.stepReplay(sim)
      inc result.ticks
    result.failed = player.hashValidationFailed
    result.failTick = player.hashMismatchTick
    result.hash = sim.gameHash()
  finally:
    setCurrentDir(previousDir)

proc withoutHandoffRecords(data: ReplayData): ReplayData =
  ## The same recording with ONLY the handoff declaration records dropped —
  ## the exact replay a build that never recorded the event would have
  ## produced.
  result = data
  result.chats = data.chats.filterIt(not it.isHandoffDeclarationRecord())

suite "handoff declaration: a recorded episode re-simulates bit-identically":
  test "POSITIVE: two declared handoffs, zero divergence":
    let path = getTempDir() / "handoff-declaration-roundtrip.bitreplay"
    let live = recordHandoffEpisode(path)

    # Scenario sanity, before any verdict: the recording really did carry
    # two handoff records and a real hash chain, AND the channel actually
    # completed both transfers (a test that never exercises the transfer
    # would prove nothing about the record being load-bearing).
    let declarations = live.data.chats.filterIt(it.isHandoffDeclarationRecord())
    check declarations.len == 2
    check live.data.hashes.len == live.ticks
    check live.ticks == TotalTicks
    check live.gunTransferred
    check live.hopperTransferred

    # ...and now forget everything above except the bytes on disk.
    let played = resimulateHandoff(live.data)
    check not played.failed
    check played.failTick == -1
    check played.ticks == live.ticks
    check played.hash == live.finalHash    # the real hash comparison

  test "NEGATIVE: drop the handoff records and the SAME replay diverges":
    # The control that makes the positive mean something. Nothing changes
    # but the presence of the two records — the recipient's own recorded
    # attack press is untouched, so any divergence traces to the missing
    # declaration and nothing else.
    let path = getTempDir() / "handoff-declaration-negative.bitreplay"
    let live = recordHandoffEpisode(path)
    let stripped = live.data.withoutHandoffRecords()
    check stripped.chats.len == live.data.chats.len - 2
    check stripped.hashes == live.data.hashes
    check stripped.inputs == live.data.inputs

    let played = resimulateHandoff(stripped)
    check played.failed
    check played.failTick >= 0
    # Bare-handed under lootStart, the recipient's attack press is a
    # total no-op live (canFire false) — so a build that dropped the
    # declaration record never even attempts a shot, and the divergence
    # traces to canFire's gate, not to a hit/miss RNG difference.
    check played.hash != live.finalHash
