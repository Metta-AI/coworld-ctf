## One-page-policy REFLASH (`allowPolicyReflash`): Season 2 flashes a cog a
## JSON strategy page mid-episode — at an ARBITRARY tick in Battle Royale
## (BR cogs have one life, so there is no spawn edge to hang it on) and on
## each respawn in CTF. A page swap is an out-of-band input to the episode:
## nothing in the recorded button masks witnesses it, so a replay that does
## not carry it re-simulates the match under a strategy it never played.
##
## This suite is the determinism contract for that record, in both
## directions — because a determinism test that still passes when the
## mechanism is broken proves nothing:
##
##   POSITIVE  a recorded episode containing three mid-episode flashes
##             re-simulates from its own bytes to an identical hash chain
##             AND identical per-seat page state.
##   NEGATIVE  the SAME recording, with only the reflash records removed,
##             diverges — at the exact tick of the first dropped flash.
##   NEGATIVE  the SAME recording, with every reflash record intact but
##             shifted ONE TICK later, also diverges. Carrying the event is
##             not enough; it has to land on the same tick boundary.
##
## Both negatives are run through `expandReplayTimeline` — the shipped
## divergence instrument — as well as through the player directly, so the
## verdict is the tool's and not the test's.

import
  helpers,
  std/[json, os, sequtils, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, labels, replays, sim],
  "../tools/expand_replay"

const
  # Three real one-page policies, in the shape the Season 2 runner flashes:
  # a small JSON object. Page B differs from A only in its stance, which is
  # the realistic case — an LLM re-strategizing rarely rewrites the sheet.
  PageA = """{"stance":"push","focus":"flag","risk":0.7}"""
  PageB = """{"stance":"hold","focus":"flag","risk":0.2}"""

  # The flash ticks straddle ReplayKeyframeTicks (100) on purpose: the seek
  # test below has to restore a keyframe that already CARRIES a flashed
  # page, which is the only way to exercise the page through the keyframe's
  # flatty round trip rather than through a re-walk from tick 0.
  FlashTickA = 40    ## cog 0 re-strategizes mid-episode
  FlashTickB = 120   ## cog 1 too, at a different tick, past a keyframe
  FlashTickC = 200   ## cog 0 RE-flashes the page it is already running
  TotalTicks = 240

proc reflashConfig(armed: bool): GameConfig =
  ## A two-cog scripted scene with the reflash channel armed or not. Nothing
  ## else differs between the two arms.
  result = defaultGameConfig()
  result.allowPolicyReflash = armed
  # A 2-player scene: the lobby would otherwise wait for the default
  # 16-player roster, and startWaitTicks would delay the start.
  result.minPlayers = 2
  result.startWaitTicks = 0

proc twoCogReflashGame(armed: bool): SimServer =
  ## A started Red-vs-Blue game with the reflash gate in a known position.
  result = initCtfForTest(reflashConfig(armed))
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()

# ---------------------------------------------------------------------------
# The record shape
# ---------------------------------------------------------------------------

suite "policy reflash: the record can never be read as a shout":
  test "no cog index can set the reflash flag":
    # The record rides the CHAT record under a player byte no cog index can
    # produce (MaxPlayers is 32), exactly as a direct-aim record rides the
    # input record — so a reflash-blind reader cannot mistake one for a
    # shout, and this build intercepts it before applyShout ever sees it.
    for cog in 0 ..< MaxPlayers:
      check (uint8(cog) and ReplayReflashRecordFlag) == 0
      check not ReplayChat(player: uint8(cog), message: "go").isPolicyPageRecord()

  test "a reflash record decodes back to its cog and its page":
    let record = ReplayChat(
      player: 5'u8 or ReplayReflashRecordFlag,
      message: encodePolicyPageRecord(PageA)
    )
    check record.isPolicyPageRecord()
    check record.policyPageRecordPlayer() == 5
    check record.decodePolicyPageRecord() == PageA

  test "the record carries the page CONTENT, not only its hash":
    # The deliberate size trade: a replay that can prove which strategy ran
    # but cannot show it is much less useful to the broadcast and forum
    # surfaces Season 2 is building. The page is present verbatim.
    let body = encodePolicyPageRecord(PageA)
    check PageA in body
    check body.len == PageA.len + ReplayReflashHashChars + 1

  test "a tampered page is refused by its own recorded content hash":
    # The hash is not decoration: it is an integrity check independent of
    # the transport, and it names the bad RECORD rather than only the tick.
    var record = ReplayChat(
      player: ReplayReflashRecordFlag,
      message: encodePolicyPageRecord(PageA)
    )
    check record.decodePolicyPageRecord() == PageA
    record.message = record.message[0 ..< ReplayReflashHashChars + 1] & PageB
    expect ReplayError:
      discard record.decodePolicyPageRecord()

  test "a malformed record is refused rather than half-read":
    for junk in ["", "short", "zzzzzzzzzzzzzzzz " & PageA,
        "0123456789abcdef" & PageA]:
      expect ReplayError:
        discard ReplayChat(
          player: ReplayReflashRecordFlag, message: junk
        ).decodePolicyPageRecord()

  test "every seat on the board fits the record's six-bit cog field":
    # The writer doAsserts on a cog it cannot address rather than returning
    # quietly, because the caller has already applied the page — so this is
    # the invariant that keeps that assert unreachable.
    check MaxPlayers - 1 <= int(ReplayReflashPlayerMask)

  test "two different pages hash differently; the same page hashes the same":
    check policyPageHash(PageA) == policyPageHash(PageA)
    check policyPageHash(PageA) != policyPageHash(PageB)
    check policyPageHash("") != policyPageHash(PageA)

# ---------------------------------------------------------------------------
# The gate discriminates, and OFF costs the archive nothing
# ---------------------------------------------------------------------------

suite "policy reflash: the config gate is real":
  test "off by default, and a league config's replay JSON gains no byte":
    check not defaultGameConfig().allowPolicyReflash
    check not parseJson(defaultGameConfig().configJson())
      .hasKey("allowPolicyReflash")

  test "a reflash replay self-identifies through its header config":
    # The header config IS the provenance: the replay FORMAT version does
    # not move (bumping it would reject every archived replay outright —
    # the codec's version check is strict equality), so a reader tells a
    # reflash-carrying replay from a plain one by this key.
    var config = reflashConfig(armed = true)
    let header = config.configJson()
    check parseJson(header).hasKey("allowPolicyReflash")
    var reread = defaultGameConfig()
    reread.update(header)
    check reread.allowPolicyReflash

  test "gate OFF: a flash is refused and nothing in the sim moves":
    var sim = twoCogReflashGame(armed = false)
    let before = sim.gameHash()
    check not sim.applyPolicyPage(0, PageA)
    check sim.players[0].policyPage == ""
    check sim.players[0].policyPageEpoch == 0
    # ...and the hash is untouched, which is the whole no-GameVersion-bump
    # argument: a gate-off game's hash trajectory is byte-identical to a
    # build that never had these fields.
    check sim.gameHash() == before

  test "gate ON: a flash lands, and MOVES the hash":
    var sim = twoCogReflashGame(armed = true)
    let before = sim.gameHash()
    check sim.applyPolicyPage(0, PageA)
    check sim.players[0].policyPage == PageA
    check sim.players[0].policyPageHash == policyPageHash(PageA)
    check sim.players[0].policyPageEpoch == 1
    check sim.players[0].policyPageTick == sim.tickCount
    check sim.gameHash() != before

  test "re-flashing the SAME page is still a distinguishable event":
    # The case an LLM produces most: reasserting the current plan. With the
    # content hash alone this would be invisible, and a lost record for it
    # would replay clean. The epoch is what makes it detectable.
    var sim = twoCogReflashGame(armed = true)
    check sim.applyPolicyPage(0, PageA)
    let afterFirst = sim.gameHash()
    check sim.applyPolicyPage(0, PageA)
    check sim.players[0].policyPageEpoch == 2
    check sim.gameHash() != afterFirst

  test "an empty page, a phantom seat, and an oversize page are all refused":
    var sim = twoCogReflashGame(armed = true)
    check not sim.applyPolicyPage(0, "")
    check not sim.applyPolicyPage(-1, PageA)
    check not sim.applyPolicyPage(sim.players.len, PageA)
    # The load-bearing refusal: a page past the record's uint16 length
    # prefix would apply live and then be unwritable to the replay — an
    # applied-but-unrecorded input. Refused before any state moves.
    let before = sim.gameHash()
    check not sim.applyPolicyPage(0, 'x'.repeat(MaxPolicyPageBytes + 1))
    check sim.players[0].policyPageEpoch == 0
    check sim.gameHash() == before
    check sim.applyPolicyPage(0, 'x'.repeat(MaxPolicyPageBytes))

  test "every archived replay still loads and still re-simulates clean":
    # The backward-compatibility half of "handle the version bump properly",
    # asserted here rather than assumed: the committed fixtures were
    # recorded by a build that had none of these fields, and they must load
    # (no format-version move) and hash-verify end to end (no GameVersion
    # move) against THIS build.
    let timeline = expandReplayTimeline(
      loadReplay(GameDir / "tests" / "fixtures" / "capture-seed1.bitreplay"))
    check not timeline.hashFailed
    check timeline.tickCount > 100

# ---------------------------------------------------------------------------
# The determinism proof
# ---------------------------------------------------------------------------

type RecordedEpisode = object
  ## One real recorded episode plus the live-side facts a faithful replay
  ## has to reproduce.
  data: ReplayData
  ticks: int
  finalHash: uint64
  pages: seq[string]
  epochs: seq[int]

proc recordReflashEpisode(path: string): RecordedEpisode =
  ## Records a real .bitreplay of a scripted two-cog episode containing
  ## three mid-episode reflashes, writing every stream exactly the way
  ## server.nim's tick loop does: masks and the accepted page BEFORE the
  ## step, the hash after it.
  var
    config = reflashConfig(armed = true)
    sim = initCtfForTest(config)
    writer = openReplayWriter(path, config.configJson())
  defer: writer.closeReplayWriter()
  discard sim.addPlayer("red0")
  discard sim.addPlayer("blue0")
  for i in 0 ..< sim.players.len:
    writer.writeJoin(tickTime(sim.tickCount), i, sim.players[i].address, i, "")
    writer.lastMasks.add(0)

  var prev = sim.none()
  for tick in 0 ..< TotalTicks:
    # The reflash drain, in the live server's own order: the page is applied
    # at this tick boundary and recorded with THIS tick's timestamp, and
    # only what the sim accepted is written.
    if tick == FlashTickA and sim.applyPolicyPage(0, PageA):
      writer.writePolicyPageFlash(tickTime(sim.tickCount), 0, PageA)
    if tick == FlashTickB and sim.applyPolicyPage(1, PageB):
      writer.writePolicyPageFlash(tickTime(sim.tickCount), 1, PageB)
    if tick == FlashTickC and sim.applyPolicyPage(0, PageA):
      writer.writePolicyPageFlash(tickTime(sim.tickCount), 0, PageA)
    # A cog that walks, so the episode has real gameplay state moving
    # underneath the strategy swaps rather than a frozen board.
    let cur = @[
      InputState(right: tick mod 4 < 2, up: tick mod 3 == 0),
      InputState(left: tick mod 5 < 2, down: tick mod 2 == 0)
    ]
    for i in 0 ..< cur.len:
      writer.writeInputMaskChange(
        tickTime(sim.tickCount), i, cur[i].encodeInputMask())
    sim.step(cur, prev)
    prev = cur
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
    inc result.ticks

  # The live-side truth a faithful replay has to reproduce.
  result.finalHash = sim.gameHash()
  for player in sim.players:
    result.pages.add(player.policyPage)
    result.epochs.add(player.policyPageEpoch)
  writer.closeReplayWriter()
  result.data = parseReplayBytes(readFile(path))

proc resimulate(data: ReplayData): tuple[
  failed: bool, failTick: int, ticks: int, hash: uint64,
  pages: seq[string], epochs: seq[int]
] =
  ## Re-simulates one replay from its own recorded config and streams,
  ## reporting where (if anywhere) the hash chain broke.
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
      player.stepReplay(sim)
      inc result.ticks
    result.failed = player.hashValidationFailed
    result.failTick = player.hashMismatchTick
    result.hash = sim.gameHash()
    for p in sim.players:
      result.pages.add(p.policyPage)
      result.epochs.add(p.policyPageEpoch)
  finally:
    setCurrentDir(previousDir)

proc withoutReflashRecords(data: ReplayData): ReplayData =
  ## The same recording with ONLY the reflash records dropped — the exact
  ## replay a build that never recorded the event would have produced.
  result = data
  result.chats = data.chats.filterIt(not it.isPolicyPageRecord())

proc tickOfTime(time: uint32): int =
  ## The tick a recorded timestamp was stamped at (tickTime is monotone, so
  ## the first tick that reaches it IS it).
  result = -1
  for tick in 0 .. TotalTicks:
    if tickTime(tick) == time:
      return tick

proc withReflashOneTickLate(data: ReplayData): ReplayData =
  ## The same recording with every reflash record intact but stamped one
  ## tick later. Carrying the event is not the requirement; landing it on
  ## the identical tick boundary is.
  result = data
  result.chats = @[]
  for chat in data.chats:
    var shifted = chat
    if chat.isPolicyPageRecord():
      let tick = tickOfTime(chat.time)
      doAssert tick >= 0
      shifted.time = tickTime(tick + 1)
    result.chats.add(shifted)

suite "policy reflash: a recorded episode re-simulates bit-identically":
  test "POSITIVE: three mid-episode flashes, zero divergence":
    let path = getTempDir() / "policy-reflash-roundtrip.bitreplay"
    let live = recordReflashEpisode(path)

    # Scenario sanity, before any verdict: the recording really does carry
    # three reflash records and a real hash chain.
    let flashes = live.data.chats.filterIt(it.isPolicyPageRecord())
    check flashes.len == 3
    check live.data.hashes.len == live.ticks
    check live.ticks == TotalTicks
    check live.pages[0] == PageA
    check live.pages[1] == PageB
    check live.epochs == @[2, 1]

    # ...and now forget everything above except the bytes on disk.
    let played = resimulate(live.data)
    check not played.failed
    check played.failTick == -1
    check played.ticks == live.ticks
    check played.hash == live.finalHash      # the real hash comparison
    check played.pages == live.pages          # the strategy, reproduced
    check played.epochs == live.epochs

    # The shipped divergence instrument agrees (it chdirs itself).
    check not expandReplayTimeline(live.data).hashFailed

  test "NEGATIVE: drop the reflash records and the SAME replay diverges":
    # The control that makes the positive mean something. Nothing changes
    # but the presence of the three records.
    let path = getTempDir() / "policy-reflash-negative.bitreplay"
    let live = recordReflashEpisode(path)
    let stripped = live.data.withoutReflashRecords()
    check stripped.chats.len == live.data.chats.len - 3
    check stripped.hashes == live.data.hashes
    check stripped.inputs == live.data.inputs

    let played = resimulate(stripped)
    check played.failed
    # It breaks at the FIRST dropped flash, not somewhere downstream: the
    # tick after FlashTickA is the first hash taken with the page missing.
    check played.failTick == FlashTickA + 1
    check played.pages == @["", ""]

    let timeline = expandReplayTimeline(stripped)
    check timeline.hashFailed
    check timeline.failTick == FlashTickA + 1
    # ...and the failure lands on a tick with NOTHING else to print, which
    # is precisely the case `expand_replay`'s CLI printer used to `continue`
    # past — printing "done" and exiting 0 on a diverging replay. A lost
    # reflash is a quiet-tick divergence by nature, so this test would have
    # been green through the tool while the mechanism was broken.
    check timeline.eventsAt(timeline.failTick).len == 0

  test "NEGATIVE: the same records, one tick late, also diverge":
    # Recording the event is necessary but not sufficient — the swap has to
    # land on the identical tick boundary live and on playback.
    let path = getTempDir() / "policy-reflash-late.bitreplay"
    let live = recordReflashEpisode(path)
    let late = live.data.withReflashOneTickLate()
    check late.chats.len == live.data.chats.len
    check late.chats.filterIt(it.isPolicyPageRecord()).len == 3

    # Every page is still present and still verifies — only its tick moved.
    check late.chats.filterIt(it.isPolicyPageRecord())
      .mapIt(tickOfTime(it.time)) ==
      @[FlashTickA + 1, FlashTickB + 1, FlashTickC + 1]
    for chat in late.chats.filterIt(it.isPolicyPageRecord()):
      check chat.decodePolicyPageRecord().len > 0

    let played = resimulate(late)
    check played.failed
    check played.failTick == FlashTickA + 1

    # ...and it broke for the RIGHT reason: at the tick the live hash was
    # taken, the page had not landed yet. A record that is present, intact,
    # and one tick off is as fatal as a missing one.
    check played.pages == @["", ""]
    check expandReplayTimeline(late).hashFailed

suite "policy reflash: a flashed page survives a keyframe seek":
  test "the sim snapshot a keyframe stores round-trips the page":
    # Keyframes are flatty snapshots of the sim, and the active page lives
    # IN the sim rather than beside it precisely so a scrub restores the
    # strategy that was live at that tick for free. If it did not survive
    # this round trip, every seek past a flash would resume the match on the
    # wrong page and desync the hash chain from the keyframe onward.
    var sim = twoCogReflashGame(armed = true)
    check sim.applyPolicyPage(0, PageA)
    check sim.applyPolicyPage(1, PageB)
    let
      before = sim.gameHash()
      bytes = serializeReplaySim(sim)
    var restored = deserializeReplaySim(bytes, sim)
    check restored.players[0].policyPage == PageA
    check restored.players[1].policyPage == PageB
    check restored.players[0].policyPageHash == policyPageHash(PageA)
    check restored.players[0].policyPageEpoch == 1
    check restored.gameHash() == before

  test "seeking backward and forward across a flash stays hash-clean":
    let path = getTempDir() / "policy-reflash-seek.bitreplay"
    let live = recordReflashEpisode(path)
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      var replayConfig = defaultGameConfig()
      replayConfig.update(live.data.configJson)
      var sim = initSimServer(replayConfig)
      sim.gameEventLoggingEnabled = false
      var player = initReplayPlayer(live.data)
      player.looping = false
      player.mismatchQuit = true
      player.buildReplayKeyframes(sim)
      # Scenario sanity: there IS a keyframe past a flash, so the seeks
      # below restore a snapshot that already carries a page.
      check player.keyframes.len >= 3
      check player.keyframes[^1].tick > FlashTickB

      # Forward to the end, back to before the first flash, forward again.
      # mismatchQuit is on, so any of these three walks re-deriving a
      # different page raises rather than quietly scoring a mismatch.
      player.seekReplay(sim, live.ticks)
      check sim.players[0].policyPage == PageA
      check sim.players[1].policyPage == PageB
      check sim.gameHash() == live.finalHash

      player.seekReplay(sim, FlashTickA)
      check sim.players[0].policyPage == ""
      check sim.players[0].policyPageEpoch == 0

      player.seekReplay(sim, FlashTickB + 1)
      check sim.players[0].policyPage == PageA
      check sim.players[1].policyPage == PageB
      check sim.players[0].policyPageEpoch == 1   # the RE-flash is still ahead

      player.seekReplay(sim, live.ticks)
      check sim.players[0].policyPageEpoch == 2
      check sim.gameHash() == live.finalHash
      check not player.hashValidationFailed
    finally:
      setCurrentDir(previousDir)


suite "policy reflash wire discrimination":
  ## The RECEIVE arm, which neither building lane could test: the runner's
  ## proposal and a real debug overlay ride the SAME 0x86 opcode, and the
  ## magic prefix is the only thing separating them. Both directions are
  ## asserted, because a check that only proves the reflash path fires would
  ## still pass if the arm swallowed every overlay packet in the game.

  proc feed(packet: seq[uint8]): (string, seq[seq[uint8]]) =
    ## Runs one 0x86 payload through the real server-side arm and reports
    ## which of the two channels it came out on.
    var
      state = initPlayerViewerState()
      inputMask = 0'u8
      pressedMask = 0'u8
      chatText = ""
      policyPage = ""
    state.applyPlayerViewerMessage(
      blobFromSpriteDebugSprites(packet),
      inputMask,
      pressedMask,
      chatText,
      policyPage
    )
    (policyPage, state.pendingDebugSprites)

  proc proposal(page: string): seq[uint8] =
    ## Byte-for-byte what players/onepage/onepage.nim puts on the wire.
    let raw = PolicyPageMagic & page
    result = newSeq[uint8](raw.len)
    for i, c in raw: result[i] = uint8(c)

  test "a magic-prefixed proposal reaches the reflash channel, prefix stripped":
    let (page, overlays) = feed(proposal(PageA))
    check page == PageA
    check overlays.len == 0

  test "a real overlay packet is untouched by the reflash arm":
    var packet: seq[uint8] = @[]
    packet.addClearObjects()
    packet.addObject(4, 5, 6, 7, 0, 8)
    let (page, overlays) = feed(packet)
    check page == ""
    check overlays == @[packet]

  test "a bare magic with no page stays on the overlay path":
    # STRICTLY longer than the magic: a bare prefix decodes to the empty
    # page `applyPolicyPage` refuses anyway, so routing it to the reflash
    # channel would eat an overlay packet and flash nothing.
    let bare = proposal("")
    let (page, overlays) = feed(bare)
    check page == ""
    check overlays == @[bare]

  test "a packet shorter than the magic cannot false-positive":
    let truncated = proposal(PageA)[0 ..< PolicyPageMagic.len - 1]
    let (page, overlays) = feed(truncated)
    check page == ""
    check overlays == @[truncated]

  test "the magic cannot collide with a real overlay opcode":
    # The forward guarantee, asserted rather than left as prose: every valid
    # debug-sprite payload begins with one of parseSpritePacket's six
    # opcodes, and the magic does not. Change the prefix to something in
    # that range and this goes red instead of silently eating overlays.
    check uint8(PolicyPageMagic[0]) notin {0x01'u8 .. 0x06'u8}

  test "one byte off the magic falls through to the overlay path":
    var nearMiss = proposal(PageA)
    nearMiss[PolicyPageMagic.len - 1] = uint8(ord('X'))   # the trailing \n
    let (page, overlays) = feed(nearMiss)
    check page == ""
    check overlays == @[nearMiss]

  test "a page the sim will refuse still arrives verbatim; the DRAIN judges":
    # The wire arm deliberately does not pre-screen: `applyPolicyPage` is the
    # single acceptance predicate, and duplicating any part of it here is how
    # live and playback come to disagree.
    let huge = "x".repeat(MaxPolicyPageBytes + 1)
    let (page, overlays) = feed(proposal(huge))
    check page == huge
    check overlays.len == 0

    var sim = twoCogReflashGame(armed = true)
    check not sim.applyPolicyPage(0, page)

  test "a page carrying the sprite protocol\'s own framing bytes survives":
    # The page is arbitrary JSON from an LLM. It must not be re-encoded or
    # scanned for anything on the way through, or the bytes the runner
    # hashed stop being the bytes the sim hashes.
    let gnarly = "{\"note\":\"\\u0000\\u0086 \\n\\t magic=CTFPOLICYPAGE1 \"}"
    let (page, overlays) = feed(proposal(gnarly))
    check page == gnarly
    check overlays.len == 0
