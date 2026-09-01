## The pre-match vote phase v1 (docs/designs/prematch-vote-phase-2026-08-31.md,
## docs/designs/prematch-vote-wire-2026-08-31.md): the `voting` substate of
## the lobby phase, the 0xA4/0xB3 wire codecs, record `0x17`, and ballot
## candidate generation (ctf/ballot.nim). Plain `import`, matching
## test_lobby_chat.nim (#321) — nothing here needs a real or fake WebSocket.
##
## OWNERSHIP SPLIT (ratified; follows #321's own precedent exactly): this
## lane owns stepLobby's `voting` substate, applyBallotCast, resolveVote,
## ballot candidate generation, and it EMITS replay record `0x17`
## (RecVoteReserved, src/shell/types.nim) — it does NOT own the play-seat
## receive-arm SOCKET WIRING, the classifier/dispatch switch
## (`classifyPlaySeatMessage`, src/shell/dispatch.nim), or the wire codecs
## in src/shell/packets.nim's `ClientPacketKind`/`ServerPacketKind`
## switches. UNLIKE #321, this lane does NOT call a landed
## `encodePacket`/`decodeClientPacket` arm for 0xA4/0xB3 — none exists yet
## (`decodeClientPacket`/`decodeServerPacket` in packets.nim do not admit
## OpBallotCastReserved/OpVoteStateReserved today; that switch is their
## sequenced work, not built here). Instead src/shell/vote_packets.nim is a
## STANDALONE codec module, mirroring packets.nim's conventions exactly, so
## lifting it into packets.nim's real switch is mechanical once that lane
## lands — this suite's "wire codec" section proves THAT module's bytes
## match the doc, not a live socket path. `applyBallotCast` is the handler
## that plugs into the seam (a future `cpkBallotCast`/`prBallot` arm) once
## that wiring lands, exactly the role applyLobbyChat plays for 0xA3 today.
##
## The central darkness claim this suite has to prove, not just assert:
## `voteTicks` defaults to 0 REGARDLESS of hasPlaySeat — unlike
## lobbyChatTicks, whose darkness relies ENTIRELY on the hasPlaySeat gate
## because huddle-v1 (#321) landed the classifier arms too. This lane does
## NOT land 0xA4/0xB3's classifier arms, so a live client can never cast —
## if voteTicks defaulted nonzero the way lobbyChatTicks does, every
## existing play-seat episode (including every test_lobby_chat.nim case)
## would gain an un-castable, un-skippable wait before chat could ever
## start. The first suite below proves this explicitly.

import
  helpers,
  std/[unittest],
  bitworld/spriteprotocol,
  ctf/[replays, sim],
  shell/[replay_records, vote_packets]

proc voteConfig(
  voteTicks: int,
  numPlaySeats = 1,
  minPlayers = 1,
  startWaitTicks = 0,
  lobbyChatTicks = 0,
  seed = 0xA6019
): GameConfig =
  ## The one config shape the voting substate runs under at all: N "play"
  ## control slots, with season2Shell on (required by validation).
  result = defaultGameConfig()
  result.season2Shell = true
  result.slots = @[]
  for _ in 0 ..< numPlaySeats:
    result.slots.add PlayerSlotConfig(control: scPlay)
  result.minPlayers = minPlayers
  result.startWaitTicks = startWaitTicks
  result.voteTicks = voteTicks
  result.lobbyChatTicks = lobbyChatTicks
  result.seed = seed

proc noPlaySeatVoteConfig(voteTicks: int, minPlayers = 1): GameConfig =
  ## The SAME shape with no play seat — the gate this suite's first test
  ## proves by disabling.
  result = defaultGameConfig()
  result.minPlayers = minPlayers
  result.startWaitTicks = 0
  result.voteTicks = voteTicks

proc addPlayers(sim: var SimServer, n: int) =
  for i in 0 ..< n:
    discard sim.addPlayer("seat" & $i)

const NoInput: seq[InputState] = @[]

proc runVotingToResolution(sim: var SimServer, maxTicks: int) =
  ## Steps until `voteResolved` or `maxTicks` steps have run, whichever
  ## comes first — robust to the exact "entry tick arms but does not
  ## decrement" shape (mirrors stepLobby's own `lobbyChatActive` precedent)
  ## rather than assuming a caller has hand-counted ticks exactly.
  for _ in 0 ..< maxTicks:
    if sim.voteResolved:
      break
    sim.step(NoInput, NoInput)

suite "vote phase: darkness — voteTicks defaults to 0 regardless of hasPlaySeat":
  test "RED-PROVEN: no play seat, voteTicks=10 explicitly set, phase never engages":
    var sim = initCtfForTest(noPlaySeatVoteConfig(voteTicks = 10))
    discard sim.addPlayer("red0")
    check sim.phase == Lobby
    sim.step(NoInput, NoInput)
    check sim.phase == Playing          # no vote delay introduced
    check not sim.inVoting()
    let rejected = sim.applyBallotCast(0, 1'u64, 0'u8)
    check not rejected.ok
    check rejected.reason == bcrClosed

  test "GREEN: the SAME voteTicks, with a play seat, actually opens the phase":
    var sim = initCtfForTest(voteConfig(voteTicks = 10))
    discard sim.addPlayer("red0")
    check sim.phase == Lobby
    sim.step(NoInput, NoInput)          # roster becomes sufficient THIS tick
    check sim.phase == Lobby
    check sim.inVoting()
    let accepted = sim.applyBallotCast(0, 1'u64, 0'u8)
    check accepted.ok
    check accepted.ordinal == 1'u64

  test "THE DIVERGENCE FROM #321: an untouched default config, even WITH a play seat, stays dark":
    ## lobbyChatTicks's own default is nonzero (720) and darkness relies
    ## solely on hasPlaySeat, because #321 landed the 0xA3/0xB2 classifier
    ## too. This lane does not land 0xA4/0xB3's classifier — so voteTicks
    ## must default to 0 even under hasPlaySeat, or every existing
    ## play-seat episode would gain an un-castable wait with no way to
    ## skip it. Proven directly: a config that only sets a play seat.
    var config = defaultGameConfig()
    config.season2Shell = true
    config.slots = @[PlayerSlotConfig(control: scPlay)]
    config.minPlayers = 1
    config.startWaitTicks = 0
    config.lobbyChatTicks = 0  # isolate voting's own darkness from chat's
    check config.voteTicks == 0
    var sim = initCtfForTest(config)
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    check sim.phase == Playing
    check not sim.inVoting()

  test "voteTicks == 0 skips the phase even WITH a play seat (the gate-off shape)":
    var sim = initCtfForTest(voteConfig(voteTicks = 0))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    check sim.phase == Playing
    check not sim.inVoting()

  test "voting precedes chatting: voting runs and closes BEFORE chat ever opens":
    var sim = initCtfForTest(voteConfig(voteTicks = 5, lobbyChatTicks = 5))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    check sim.inVoting()
    check not sim.inLobbyChat()
    for _ in 0 ..< 4:
      sim.step(NoInput, NoInput)
    check sim.inVoting()                # still inside the 5-tick vote phase
    sim.step(NoInput, NoInput)          # 5th tick: voteTicksLeft hits 0
    check not sim.inVoting()
    check sim.voteResolved
    check not sim.inLobbyChat()         # not yet — arms on the NEXT tick,
                                         # exactly like chat's own closing
                                         # tick never falls through to
                                         # countdown in the SAME step
    sim.step(NoInput, NoInput)          # the tick after voting closes
    check sim.inLobbyChat()             # chat now open, resolved bundle
                                         # already known (§1's ordering)

  test "the phase runs exactly its configured length when nobody casts, then closes":
    var sim = initCtfForTest(voteConfig(voteTicks = 5))
    discard sim.addPlayer("red0")
    var sawVoting = false
    var ticksInVoting = 0
    for _ in 0 ..< 40:
      sim.step(NoInput, NoInput)
      if sim.phase == Playing:
        break
      if sim.inVoting():
        sawVoting = true
        inc ticksInVoting
    check sawVoting
    check ticksInVoting == 5
    check sim.phase == Playing
    check sim.voteResolved
    # Closed again once concluded — a cast sent after the phase ends is
    # rejected exactly like one sent before it ever opened.
    let late = sim.applyBallotCast(0, 1'u64, 0'u8)
    check not late.ok
    check late.reason == bcrClosed

suite "vote phase: applyBallotCast admission":
  test "bad seat index is refused":
    var sim = initCtfForTest(voteConfig(voteTicks = 50))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    let bad = sim.applyBallotCast(5, 1'u64, 0'u8)
    check not bad.ok
    check bad.reason == bcrBadSeat

  test "an option outside 0-3 is refused":
    var sim = initCtfForTest(voteConfig(voteTicks = 50))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    let bad = sim.applyBallotCast(0, 1'u64, 4'u8)
    check not bad.ok
    check bad.reason == bcrBadOption

  test "an exact resend (same castId, same option) is a silent no-op":
    var sim = initCtfForTest(voteConfig(voteTicks = 200))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    let first = sim.applyBallotCast(0, 1'u64, 1'u8)
    check first.ok
    check first.ordinal == 1'u64
    # Many resends, well past the rate cap, all succeed with the SAME
    # ordinal and never consume the rate budget.
    for _ in 0 ..< (BallotCastMaxPerSeatPerPhase + 5):
      let resend = sim.applyBallotCast(0, 1'u64, 1'u8)
      check resend.ok
      check resend.ordinal == 1'u64
      check not resend.fresh
    check sim.voteOrdinal == 1'u64   # no new ordinal was ever minted

  test "the same castId with a DIFFERENT option is a conflict, rejected":
    var sim = initCtfForTest(voteConfig(voteTicks = 50))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    check sim.applyBallotCast(0, 5'u64, 0'u8).ok
    let conflict = sim.applyBallotCast(0, 5'u64, 1'u8)
    check not conflict.ok
    check conflict.reason == bcrCastIdConflict

  test "a castId at or below the last accepted one is stale":
    var sim = initCtfForTest(voteConfig(voteTicks = 50))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    check sim.applyBallotCast(0, 5'u64, 0'u8).ok
    let stale = sim.applyBallotCast(0, 3'u64, 1'u8)
    check not stale.ok
    check stale.reason == bcrCastIdStale

  test "a re-vote (new castId, new option) replaces the seat's declared vote":
    # 2 configured seats, only seat 0 ever casts — seat 1's permanent
    # abstention keeps `voting` open across every step in this test, so
    # full turnout never triggers early resolution mid-test (a single-seat
    # config would auto-close as soon as the FIRST cast lands, closing the
    # window this test needs to exercise a re-vote in).
    var sim = initCtfForTest(voteConfig(voteTicks = 50, numPlaySeats = 2))
    sim.addPlayers(2)
    sim.step(NoInput, NoInput)
    check sim.applyBallotCast(0, 1'u64, 0'u8).ok      # votes A
    for _ in 0 ..< BallotCastMinSpacingTicks: sim.step(NoInput, NoInput)
    check sim.inVoting()
    let second = sim.applyBallotCast(0, 2'u64, 2'u8)  # changes to C
    check second.ok
    check second.fresh
    check sim.voteSeats[0].option == 2'u8             # only C is on record

  test "a seat is capped at BallotCastMaxPerSeatPerPhase fresh casts per phase":
    ## Same 2-seat shape as the re-vote test above, for the same reason:
    ## seat 1 never casts, so `voting` stays open long enough to exhaust
    ## seat 0's rate budget instead of auto-closing after its first cast.
    let phaseTicks =
      (BallotCastMaxPerSeatPerPhase + 2) * BallotCastMinSpacingTicks
    var sim = initCtfForTest(voteConfig(voteTicks = phaseTicks, numPlaySeats = 2))
    sim.addPlayers(2)
    sim.step(NoInput, NoInput)
    var accepted = 0
    for i in 0 ..< BallotCastMaxPerSeatPerPhase:
      let outcome = sim.applyBallotCast(0, uint64(i + 1), uint8(i mod 4))
      check outcome.ok
      inc accepted
      for _ in 0 ..< BallotCastMinSpacingTicks: sim.step(NoInput, NoInput)
    check accepted == BallotCastMaxPerSeatPerPhase
    check sim.inVoting()
    let overflow = sim.applyBallotCast(
      0, uint64(BallotCastMaxPerSeatPerPhase + 1), 0'u8)
    check not overflow.ok
    check overflow.reason == bcrRateLimited

  test "two fresh casts closer than BallotCastMinSpacingTicks: the second is refused":
    ## Same 2-seat shape, same reason: seat 1's abstention keeps `voting`
    ## open across the spacing wait.
    var sim = initCtfForTest(voteConfig(voteTicks = 50, numPlaySeats = 2))
    sim.addPlayers(2)
    sim.step(NoInput, NoInput)
    check sim.applyBallotCast(0, 1'u64, 0'u8).ok
    let tooSoon = sim.applyBallotCast(0, 2'u64, 1'u8)
    check not tooSoon.ok
    check tooSoon.reason == bcrTooSoon
    for _ in 0 ..< BallotCastMinSpacingTicks: sim.step(NoInput, NoInput)
    check sim.inVoting()
    let onTime = sim.applyBallotCast(0, 2'u64, 1'u8)
    check onTime.ok

suite "vote phase: tally, tie-break, and D-delegation":
  test "plurality with no tie resolves directly, no draw":
    var sim = initCtfForTest(voteConfig(voteTicks = 50, numPlaySeats = 3))
    sim.addPlayers(3)
    sim.step(NoInput, NoInput)
    check sim.applyBallotCast(0, 1'u64, 0'u8).ok   # A
    check sim.applyBallotCast(1, 1'u64, 0'u8).ok   # A
    check sim.applyBallotCast(2, 1'u64, 1'u8).ok   # B
    sim.runVotingToResolution(55)
    check sim.voteResolved
    check sim.voteCategory == 0'u8
    check not sim.voteTieBreakDrawn
    check sim.voteFinalOption == 0'u8

  test "a seat that never casts is an implicit D abstention":
    var sim = initCtfForTest(voteConfig(voteTicks = 50, numPlaySeats = 2))
    sim.addPlayers(2)
    sim.step(NoInput, NoInput)
    check sim.applyBallotCast(0, 1'u64, 0'u8).ok   # A; seat 1 abstains -> D
    sim.runVotingToResolution(55)                  # only the clock can close
    check sim.voteResolved                          # it (seat 1 never casts)
    # 1 vs 1 (A vs D): a tie, broken by the episode seed.
    check sim.voteTieBreakDrawn
    check sim.voteCategory in [0'u8, 3'u8]
    check sim.voteFinalOption in [0'u8, 1'u8, 2'u8]

  test "total silence resolves to D, then a second draw picks A/B/C":
    var sim = initCtfForTest(voteConfig(voteTicks = 10, numPlaySeats = 2))
    sim.addPlayers(2)
    sim.runVotingToResolution(15)
    check sim.voteResolved
    check sim.voteCategory == 3'u8
    check not sim.voteTieBreakDrawn      # no tie: D alone had the plurality
    check sim.voteFinalOption in [0'u8, 1'u8, 2'u8]

  test "determinism: identical seed and votes reproduce the identical result":
    proc runEpisode(): tuple[category, finalOption: uint8, tieBreak: bool] =
      var sim = initCtfForTest(voteConfig(
        voteTicks = 10, numPlaySeats = 2, seed = 424242))
      sim.addPlayers(2)
      sim.step(NoInput, NoInput)
      discard sim.applyBallotCast(0, 1'u64, 0'u8)
      # seat 1 abstains -> a tie, exercising BOTH draws deterministically.
      sim.runVotingToResolution(15)
      check sim.voteResolved
      (sim.voteCategory, sim.voteFinalOption, sim.voteTieBreakDrawn)
    let a = runEpisode()
    let b = runEpisode()
    check a == b

  test "the resolved bundle is always A/B/C, never D itself":
    for seed in [1, 2, 3, 4, 5, 424242, 0xA6019]:
      var sim = initCtfForTest(voteConfig(
        voteTicks = 10, numPlaySeats = 1, seed = seed))
      discard sim.addPlayer("red0")
      sim.runVotingToResolution(15)  # abstains -> D outright
      check sim.voteResolved
      check sim.voteCategory == 3'u8
      check sim.voteFinalOption in [0'u8, 1'u8, 2'u8]

suite "vote phase: a reconnectable tombstone holds early resolution":
  test "an un-cast, tombstoned configured seat blocks early resolution; voteTicks still bounds it":
    var sim = initCtfForTest(voteConfig(voteTicks = 20, numPlaySeats = 2))
    sim.addPlayers(2)
    sim.step(NoInput, NoInput)
    sim.setVoteSeatTombstoned(1, true)
    check sim.applyBallotCast(0, 1'u64, 0'u8).ok   # every OTHER seat cast
    for _ in 0 ..< 15:
      sim.step(NoInput, NoInput)
      check sim.inVoting()             # never resolves early around it
    for _ in 0 ..< 5: sim.step(NoInput, NoInput)    # voteTicks (20) elapses
    check sim.voteResolved             # the clock, not turnout, closed it

  test "once the tombstoned seat also casts, resolution proceeds normally (no longer blocked)":
    var sim = initCtfForTest(voteConfig(voteTicks = 20, numPlaySeats = 2))
    sim.addPlayers(2)
    sim.step(NoInput, NoInput)
    sim.setVoteSeatTombstoned(1, true)
    check sim.applyBallotCast(0, 1'u64, 0'u8).ok
    check sim.inVoting()
    check sim.applyBallotCast(1, 1'u64, 0'u8).ok    # the tombstoned seat casts
    sim.step(NoInput, NoInput)         # early resolution: full turnout now
    check sim.voteResolved
    check not sim.inVoting()

suite "vote phase: gameHash independence":
  test "vote activity never enters gameHash: cast vs. silent, identical chain":
    proc runEpisode(sendCast: bool): seq[uint64] =
      var sim = initCtfForTest(voteConfig(voteTicks = 20, numPlaySeats = 2))
      sim.addPlayers(2)
      for tick in 0 ..< 60:
        if sendCast and sim.inVoting() and tick == 2:
          discard sim.applyBallotCast(0, 1'u64, 1'u8)
        sim.step(sim.none(), sim.none())
        result.add sim.gameHash()
    let withCast = runEpisode(sendCast = true)
    let silent = runEpisode(sendCast = false)
    check withCast == silent

suite "vote phase: the 0xA4/0xB3 wire codec, byte for byte":
  ## NOT ours per the ownership split (see this file's header): a real
  ## classifier arm for 0xA4/0xB3 does not exist in packets.nim/dispatch.nim
  ## yet, so these prove src/shell/vote_packets.nim's OWN construction of
  ## the bytes matches the doc — nothing here drives a live socket.
  test "a 0xA4 BallotCast round-trips and lands at its documented offsets":
    let packet = encodePacket(BallotCastPacket(castId: 0x0102030405060708'u64,
      option: 2'u8))
    check packet.len == BallotCastPacketBytes
    check packet.len == 16
    check uint8(packet[0]) == BallotCastOp
    check uint8(packet[1]) == VoteWireVersion
    check uint8(packet[10]) == 2'u8          # option
    for i in 11 ..< 16:
      check uint8(packet[i]) == 0'u8         # reserved, zero
    let decoded = packet.decodeBallotCast()
    check decoded.castId == 0x0102030405060708'u64
    check decoded.option == 2'u8

  test "a 0xA4 with a nonzero reserved byte is refused":
    var bytes = encodePacket(BallotCastPacket(castId: 1'u64, option: 0'u8))
    bytes[12] = char(1'u8)
    expect PacketError:
      discard bytes.decodeBallotCast()

  test "a 0xA4 with the wrong length is refused":
    var bytes = encodePacket(BallotCastPacket(castId: 1'u64, option: 0'u8))
    bytes.setLen(bytes.len - 1)
    expect PacketError:
      discard bytes.decodeBallotCast()

  test "0xB3 kind-0 (cast) round-trips and lands at its documented offsets":
    let packet = encodePacket(VoteStatePacket(kind: vskCast, castInfo:
      VoteStateCastPacket(ordinal: 42'u64, tick: 1000'u32, seat: 3'u8,
        team: 1'u8, option: 2'u8)))
    check packet.len == VoteStatePacketBytes
    check packet.len == 18
    check uint8(packet[0]) == VoteStateOp
    check uint8(packet[1]) == VoteWireVersion
    check uint8(packet[2]) == 0'u8           # kind 0
    check uint8(packet[15]) == 3'u8          # seat
    check uint8(packet[16]) == 1'u8          # team
    check uint8(packet[17]) == 2'u8          # option
    let decoded = packet.decodeVoteState()
    check decoded.kind == vskCast
    check decoded.castInfo.ordinal == 42'u64
    check decoded.castInfo.tick == 1000'u32
    check decoded.castInfo.seat == 3'u8
    check decoded.castInfo.team == 1'u8
    check decoded.castInfo.option == 2'u8

  test "0xB3 kind-1 (resolved) round-trips and lands at its documented offsets":
    let packet = encodePacket(VoteStatePacket(kind: vskResolved, resolved:
      VoteStateResolvedPacket(ordinal: 7'u64, tick: 500'u32, category: 3'u8,
        tieBreakDrawn: 1'u8, finalOption: 1'u8)))
    check packet.len == 18
    check uint8(packet[2]) == 1'u8           # kind 1
    check uint8(packet[15]) == 3'u8          # category
    check uint8(packet[16]) == 1'u8          # tieBreakDrawn
    check uint8(packet[17]) == 1'u8          # finalOption
    let decoded = packet.decodeVoteState()
    check decoded.kind == vskResolved
    check decoded.resolved.category == 3'u8
    check decoded.resolved.tieBreakDrawn == 1'u8
    check decoded.resolved.finalOption == 1'u8

  test "an unknown 0xB3 kind byte is refused":
    var bytes = encodePacket(VoteStatePacket(kind: vskCast, castInfo:
      VoteStateCastPacket(ordinal: 1'u64, tick: 0'u32, seat: 0'u8, team: 0'u8,
        option: 0'u8)))
    bytes[2] = char(2'u8)
    expect PacketError:
      discard bytes.decodeVoteState()

suite "vote phase: record 0x17 (RecVoteReserved), EMIT side":
  ## Ownership split (see this file's header): this lane owns stepLobby's
  ## substate and applyBallotCast/resolveVote, and it EMITS record 0x17 —
  ## it does NOT own reading it back into a live .bitreplay stream or the
  ## manifest arm (there is none, by the hash-coupled ruling — see below).
  test "a cast (kind 0) record starts with the landed byte 0x17 and matches its layout":
    let bytes = encodeBallotRecord(BallotRecord(kind: brkCast,
      replayTimeMs: 1234'u32, ordinal: 7'u64, seat: 3'u8, team: 1'u8,
      option: 2'u8))
    check uint8(bytes[0]) == RecBallotType
    check uint8(bytes[0]) == 0x17'u8
    check bytes.len == RecBallotBytes
    check bytes.len == 17
    let decoded = bytes.decodeBallotRecord()
    check decoded.kind == brkCast
    check decoded.replayTimeMs == 1234'u32
    check decoded.ordinal == 7'u64
    check decoded.seat == 3'u8
    check decoded.team == 1'u8
    check decoded.option == 2'u8

  test "a resolved (kind 1) record matches its layout, also 17 bytes":
    let bytes = encodeBallotRecord(BallotRecord(kind: brkResolved,
      replayTimeMs: 999'u32, ordinal: 8'u64, category: 3'u8,
      tieBreakDrawn: 1'u8, finalOption: 2'u8))
    check bytes.len == 17
    let decoded = bytes.decodeBallotRecord()
    check decoded.kind == brkResolved
    check decoded.category == 3'u8
    check decoded.tieBreakDrawn == 1'u8
    check decoded.finalOption == 2'u8

  test "the record honors applyBallotCast's own admitted ordinal and option, verbatim":
    var sim = initCtfForTest(voteConfig(voteTicks = 50))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    let outcome = sim.applyBallotCast(0, 1'u64, 2'u8)
    check outcome.ok
    let team = sim.teamForSlot(0)
    let record = encodeBallotRecord(BallotRecord(kind: brkCast,
      replayTimeMs: tickTime(sim.tickCount), ordinal: outcome.ordinal,
      seat: 0'u8, team: uint8(ord(team)), option: 2'u8))
    let decoded = record.decodeBallotRecord()
    check decoded.ordinal == outcome.ordinal
    check decoded.option == 2'u8

  test "the resolved record honors resolveVote's own outputs, verbatim":
    var sim = initCtfForTest(voteConfig(voteTicks = 5, numPlaySeats = 1))
    discard sim.addPlayer("red0")
    sim.runVotingToResolution(10)
    check sim.voteResolved
    let record = encodeBallotRecord(BallotRecord(kind: brkResolved,
      replayTimeMs: tickTime(sim.voteResolutionTick),
      ordinal: sim.voteOrdinal + 1, category: sim.voteCategory,
      tieBreakDrawn: (if sim.voteTieBreakDrawn: 1'u8 else: 0'u8),
      finalOption: sim.voteFinalOption))
    let decoded = record.decodeBallotRecord()
    check decoded.category == sim.voteCategory
    check decoded.finalOption == sim.voteFinalOption

suite "vote phase: ballot candidate generation (ctf/ballot.nim)":
  test "the same seed produces the identical 3 candidates, every time":
    let a = defaultBallotCandidates(0xA6019)
    let b = defaultBallotCandidates(0xA6019)
    check a == b

  test "the 3 candidates on one ballot are distinct":
    let candidates = defaultBallotCandidates(424242)
    check candidates[0].mode != candidates[1].mode
    check candidates[1].mode != candidates[2].mode
    check candidates[0].mode != candidates[2].mode

  test "different seeds can draw a different ballot":
    var sawDifference = false
    let baseline = defaultBallotCandidates(1)
    for seed in 2 .. 30:
      if defaultBallotCandidates(seed) != baseline:
        sawDifference = true
        break
    check sawDifference

  test "wired into the episode: ballotCandidatesForEpisode matches the seed's own draw":
    var sim = initCtfForTest(voteConfig(voteTicks = 10, seed = 555))
    discard sim.addPlayer("red0")
    check sim.ballotCandidatesForEpisode() == defaultBallotCandidates(555)
