import
  helpers,
  std/[sets, strutils, tables, unittest],
  bitworld/spriteprotocol,
  ctf/[global, shimmer, sim]

# Metallic-paint shimmer: the PER-AGENT overlay that marks one policy's cogs
# inside an otherwise uniformly colored team (src/ctf/shimmer.nim,
# docs/COLOR_CONTRACT.md §5).
#
# The thing worth testing here is not that a sprite draws — it is the GATE. The
# feature's whole reason to exist is that two seats on the SAME team, in the
# same frame, must disagree: one wears the sheen and one does not. A test that
# only checked "shimmer on ⇒ something renders" would pass just as happily on a
# per-TEAM implementation, which is the bug this channel exists to avoid.
#
# So every check below is a control as much as an assertion: the seats that must
# NOT shimmer are named explicitly, and the off-by-default case is asserted
# before anything is turned on.
#
# Detection is deliberately BLACK-BOX — find the sprite ids whose label is the
# shimmer family, then find the objects drawn with them — rather than reading
# global.nim's private id pools. A regression that moved the overlay to another
# pool while keeping the label, or renamed the label while keeping the pool,
# should fail this file, and mirroring the constants here would hide one of
# those.

const ShimmerLabelPrefix = "metal shimmer "

proc shimmerSpriteIds(
  messages: openArray[SpritePacketMessage]
): seq[int] =
  ## Every sprite id defined in this packet under the shimmer label family.
  for message in messages:
    if message.kind == spkSprite and
        message.sprite.label.startsWith(ShimmerLabelPrefix):
      result.add message.sprite.id

proc shimmerCentres(
  messages: openArray[SpritePacketMessage]
): seq[(int, int)] =
  ## The CENTER of every shimmer overlay placed in this packet, in wire
  ## (board-scaled) pixels. Objects carry the sprite id they draw with, so the
  ## label lookup above is what identifies them.
  let ids = messages.shimmerSpriteIds()
  var size = 0
  for message in messages:
    if message.kind == spkSprite and message.sprite.id in ids:
      size = message.sprite.width
  for message in messages:
    if message.kind == spkObject and message.objectDef.spriteId in ids:
      result.add (message.objectDef.x + size div 2,
                  message.objectDef.y + size div 2)

proc fullFrame(sim: var SimServer): seq[SpritePacketMessage] =
  ## ONE complete board frame, built against a FRESH viewer state.
  ##
  ## The wire is a DELTA protocol: a second build against the same state sends
  ## only what changed, so a posed frame's second read is legitimately empty.
  ## Asserting per seat against a shared, mutating state therefore "loses" every
  ## seat after the first — a test artifact that looks exactly like a per-agent
  ## gate bug. Every check below reads one full frame instead.
  var state = initGlobalViewerState()
  sim.buildGlobalMessages(state)

proc shimmersOnSeat(
  sim: SimServer,
  messages: openArray[SpritePacketMessage],
  seat: int
): bool =
  ## Whether a shimmer overlay is centered on one seat's cog in this frame.
  ## Positional rather than id-based on purpose: it proves the sheen landed on
  ## the RIGHT agent, which an object-id check would take on faith.
  let
    scale = boardRenderScaleFor(sim.gameMap.width, sim.gameMap.height)
    px = sim.players[seat].x * scale
    py = sim.players[seat].y * scale
  for (cx, cy) in messages.shimmerCentres():
    # The overlay rides a few px back along the aim (ShimmerBackPx), so this is
    # a proximity test, not an equality one. The tolerance is far tighter than
    # the gap between any two posed cogs below.
    if abs(cx - px) <= 8 * scale and abs(cy - py) <= 8 * scale:
      return true
  false

proc mixedTeamGame(): SimServer =
  ## Six seats, two teams, TWO policies per team — the CTF-Doubles shape the
  ## shimmer channel is for. Seats deal round the teams in enum order
  ## (roster.teamForSlot), so evens are Red and odds are Blue:
  ##   Red:  0 picasso, 2 picasso, 4 focusfire
  ##   Blue: 1 jordan,  3 baseline, 5 baseline
  ## Names carry the hosted per-connection seat suffix, so the stripping is
  ## exercised on the real path rather than in isolation.
  var config = defaultGameConfig()
  config.slots.setLen(6)
  result = initCtfForTest(config)
  for (i, name) in [(0, "picasso_(0)"), (1, "jordan (1)"), (2, "picasso_(2)"),
                    (3, "baseline_(3)"), (4, "focusfire_(4)"),
                    (5, "baseline_(5)")]:
    discard result.addPlayer(name)
  result.startGame()
  # Spread them out so a positional hit can only belong to one seat.
  let
    cx = result.gameMap.center.x
    cy = result.gameMap.center.y
  for i in 0 ..< result.players.len:
    result.players[i].x = cx - 100 + i * 40
    result.players[i].y = cy
    result.players[i].aimBrads = 0
    result.players[i].alive = true

suite "metal shimmer":
  setup:
    setTeamShimmerPolicies(initTable[Team, string]())

  teardown:
    setTeamShimmerPolicies(initTable[Team, string]())

  test "no shimmer policy means no shimmer sprite anywhere":
    # The off case is the one that has to be airtight: every stock episode, and
    # every episode whose payload carried no `shimmer` field, renders through
    # this path. If the default leaked, every league replay would change.
    var game = mixedTeamGame()
    let messages = game.fullFrame()
    check messages.shimmerSpriteIds().len == 0
    check messages.shimmerCentres().len == 0
    check not anyShimmer()

  test "only the flagged policy's seats shimmer, on the flagged team only":
    var game = mixedTeamGame()
    setTeamShimmerPolicies({Red: "picasso"}.toTable)
    let frame = game.fullFrame()
    # Red picasso: yes. Red focusfire: no — same team, same frame, and this
    # single line is what separates a per-AGENT flag from a per-TEAM one.
    check game.shimmersOnSeat(frame, 0)
    check game.shimmersOnSeat(frame, 2)
    check not game.shimmersOnSeat(frame, 4)
    # Blue has no shimmer policy at all, so no Blue seat may shimmer — not even
    # one whose policy name happens to be flagged on the other team.
    check not game.shimmersOnSeat(frame, 1)
    check not game.shimmersOnSeat(frame, 3)
    check not game.shimmersOnSeat(frame, 5)
    # Exactly two overlays in the frame, so nothing is being drawn off-cog.
    check frame.shimmerCentres().len == 2

  test "both teams can carry their own shimmer policy at once":
    var game = mixedTeamGame()
    setTeamShimmerPolicies({Red: "focusfire", Blue: "baseline"}.toTable)
    let frame = game.fullFrame()
    check game.shimmersOnSeat(frame, 4)      # Red focusfire
    check game.shimmersOnSeat(frame, 3)      # Blue baseline
    check game.shimmersOnSeat(frame, 5)      # Blue baseline
    check not game.shimmersOnSeat(frame, 0)  # Red picasso is not flagged now
    check not game.shimmersOnSeat(frame, 1)  # Blue jordan is not flagged
    check frame.shimmerCentres().len == 3

  test "the hosted seat suffix is stripped on both spellings":
    # "jordan (1)" keeps a space in config but the join path underscores it
    # (server.cleanPlayerName), so BOTH spellings have to collapse to the same
    # policy — a mismatch here would shimmer some seats of a policy and not
    # others, which looks like a rendering glitch rather than a naming bug.
    check policyName("jordan (1)") == "jordan"
    check policyName("jordan_(1)") == "jordan"
    check policyName("ctf-focusfire:v62_(4)") == "ctf-focusfire:v62"
    check policyName("Player1") == "Player1"
    var game = mixedTeamGame()
    setTeamShimmerPolicies({Blue: "jordan"}.toTable)
    check game.shimmersOnSeat(game.fullFrame(), 1)
    # And the platform sending an already-stripped name is the documented case,
    # while sending a suffixed one still resolves — the viewer strips too.
    setTeamShimmerPolicies({Blue: policyName("jordan_(9)")}.toTable)
    check game.shimmersOnSeat(game.fullFrame(), 1)

  test "the sweep advances with the tick and differs by seat":
    # The animation is derived from tickCount alone, so every viewer of a replay
    # agrees on the frame with no animation state to sync. Two seats of the same
    # policy must be out of phase (ShimmerSeatStride), or a squad glints in
    # unison and reads as a UI blink instead of light.
    var game = mixedTeamGame()
    setTeamShimmerPolicies({Red: "picasso"}.toTable)
    let atStart = game.fullFrame().shimmerSpriteIds()
    check atStart.len == 2          # seats 0 and 2, two DIFFERENT sweep frames
    check atStart[0] != atStart[1]
    # Far enough ahead that the frame index must have moved for both seats.
    game.tickCount += 40
    let later = game.fullFrame().shimmerSpriteIds()
    check later.len == 2
    check later.toHashSet() != atStart.toHashSet()
    # Both seats stepped by the same amount, so the phase GAP is preserved:
    # they never converge onto one frame and start glinting in unison.
    check later[1] - later[0] == atStart[1] - atStart[0]

  test "a dead seat wears no sheen":
    var game = mixedTeamGame()
    setTeamShimmerPolicies({Red: "picasso"}.toTable)
    check game.shimmersOnSeat(game.fullFrame(), 0)
    game.players[0].alive = false
    let frame = game.fullFrame()
    check not game.shimmersOnSeat(frame, 0)
    check game.shimmersOnSeat(frame, 2)

  test "shimmer is display-only: the game hash is untouched":
    # The one property that makes this safe to ship: it must not be able to
    # change a replay. Same seed, same inputs, one run with the sheen on and one
    # with it off — the recorded hash has to agree tick for tick, or a replay
    # recorded on a shimmering viewer would fail its own mismatch check.
    proc runHashes(policies: Table[Team, string]): seq[uint64] =
      setTeamShimmerPolicies(policies)
      var game = mixedTeamGame()
      let none = newSeq[InputState](game.players.len)
      for _ in 0 ..< 12:
        discard game.fullFrame()                  # render, exactly as a viewer
        game.step(none, none)
        result.add game.gameHash()
    let
      off = runHashes(initTable[Team, string]())
      on = runHashes({Red: "picasso", Blue: "baseline"}.toTable)
    check off.len == 12
    check on == off

  test "the dev env stub parses wire team words, not display slugs":
    # CTF_SHIMMER is scaffolding, but its vocabulary still matters: the payload
    # keys teams by WIRE word (docs/COLOR_CONTRACT.md §5), and a stub that
    # accepted display slugs would teach the wrong shape to whoever reads it.
    let spec = parseShimmerSpec("red:picasso, blue:jordan_(3);green: focusfire")
    check spec[Red] == "picasso"
    check spec[Blue] == "jordan"          # suffix stripped on the way in
    check spec[Green] == "focusfire"
    check Yellow notin spec
    # Junk is skipped, never raised on — a typo must not take a server down.
    let junk = parseShimmerSpec("nonsense,,red:,:orphan,vermillion:picasso")
    check junk.len == 0
