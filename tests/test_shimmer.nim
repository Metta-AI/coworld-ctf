import
  helpers,
  std/[sets, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, shimmer, sim, team_colors]

# Metallic-paint shimmer: the PER-AGENT overlay that marks the ONE league #1's
# cogs — at most one policy in the whole lobby, usually none (src/ctf/shimmer.nim,
# docs/COLOR_CONTRACT.md §5).
#
# The thing worth testing here is not that a sprite draws — it is the GATE, and
# the gate has two halves that pull in opposite directions:
#
#  - It is per AGENT, not per team: two seats on the SAME team, in the same
#    frame, must disagree. A test that only checked "shimmer on ⇒ something
#    renders" would pass just as happily on a per-team implementation.
#  - It is SINGULAR and team-INDEPENDENT: one policy lobby-wide, shimmering on
#    every team it holds a seat on. The failure this file exists to catch is the
#    old per-team schema coming back — a stale payload lighting up four policies
#    at once, which turns the rarest mark on the board into wallpaper.
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
  ## Six seats, two teams, mixed policies — the CTF-Doubles shape the shimmer
  ## channel renders into. Seats deal round the teams in enum order
  ## (roster.teamForSlot), so evens are Red and odds are Blue:
  ##   Red:  0 picasso, 2 picasso, 4 focusfire
  ##   Blue: 1 jordan,  3 baseline, 5 picasso
  ## `picasso` deliberately straddles BOTH teams: the flag is a league standing,
  ## not a team property, and the platform seats one policy wherever it likes.
  ## `focusfire` sits alone on Red as the one-seat control.
  ## Names carry the hosted per-connection seat suffix, so the stripping is
  ## exercised on the real path rather than in isolation.
  var config = defaultGameConfig()
  config.slots.setLen(6)
  result = initCtfForTest(config)
  for (i, name) in [(0, "picasso_(0)"), (1, "jordan (1)"), (2, "picasso_(2)"),
                    (3, "baseline_(3)"), (4, "focusfire_(4)"),
                    (5, "picasso_(5)")]:
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
    setShimmerPolicy("")
    resetTeamDisplayColorsForTests()

  teardown:
    setShimmerPolicy("")
    resetTeamDisplayColorsForTests()

  test "no shimmer policy means no shimmer sprite anywhere":
    # The off case is the one that has to be airtight: every stock episode, and
    # every episode whose payload carried no `shimmer` field — which is MOST of
    # them, since the #1 is in only a slice of the league's matches — renders
    # through this path. If the default leaked, every league replay would change.
    var game = mixedTeamGame()
    let messages = game.fullFrame()
    check messages.shimmerSpriteIds().len == 0
    check messages.shimmerCentres().len == 0
    check not anyShimmer()

  test "only the flagged policy's seats shimmer, teammates render stock":
    var game = mixedTeamGame()
    setShimmerPolicy("focusfire")
    let frame = game.fullFrame()
    # focusfire holds exactly one seat in this episode, so exactly one cog in
    # the whole frame wears the sheen. Seats 0 and 2 are its own TEAMMATES and
    # must render stock — the single pair of lines that separates a per-AGENT
    # flag from a per-team one.
    check game.shimmersOnSeat(frame, 4)
    check not game.shimmersOnSeat(frame, 0)
    check not game.shimmersOnSeat(frame, 2)
    check not game.shimmersOnSeat(frame, 1)
    check not game.shimmersOnSeat(frame, 3)
    check not game.shimmersOnSeat(frame, 5)
    # Exactly one overlay in the frame, so nothing is being drawn off-cog.
    check frame.shimmerCentres().len == 1

  test "one policy seated on two teams shimmers on BOTH":
    # The flag is a league standing, not a team property. picasso holds seats 0
    # and 2 on Red and seat 5 on Blue; all three are the #1's agents, so all
    # three wear the sheen while their respective teammates do not.
    var game = mixedTeamGame()
    setShimmerPolicy("picasso")
    let frame = game.fullFrame()
    check game.shimmersOnSeat(frame, 0)      # Red picasso
    check game.shimmersOnSeat(frame, 2)      # Red picasso
    check game.shimmersOnSeat(frame, 5)      # Blue picasso — the cross-team half
    check not game.shimmersOnSeat(frame, 4)  # Red focusfire
    check not game.shimmersOnSeat(frame, 1)  # Blue jordan
    check not game.shimmersOnSeat(frame, 3)  # Blue baseline
    check frame.shimmerCentres().len == 3

  test "a flagged policy that is not in this episode shimmers nobody":
    # The NORMAL case for a real payload: the league #1 is not in most matches,
    # so the viewer is handed a name no seat answers to. That must render a
    # stock board in silence — not raise, not fall back to marking somebody.
    var game = mixedTeamGame()
    setShimmerPolicy("ctf-nemesis:v9")
    let frame = game.fullFrame()
    check anyShimmer()                       # a policy IS flagged...
    check shimmerPolicy() == "ctf-nemesis:v9"
    check frame.shimmerSpriteIds().len == 0  # ...and nothing draws.
    check frame.shimmerCentres().len == 0
    for seat in 0 ..< 6:
      check not game.shimmersOnSeat(frame, seat)

  test "a root-level payload shimmer installs the one flagged policy":
    # The seam the platform actually drives, end to end: raw payload JSON in,
    # sheen on the right cogs out.
    # No `teams` key at all: a shimmer-only payload is legal (§5), so the root
    # field has to be read BEFORE the color half's gate, not after it.
    setTeamDisplayColors("""{"v":1,"shimmer":"picasso"}""")
    installPayloadShimmer()
    check payloadShimmerPolicy() == "picasso"
    check shimmerPolicy() == "picasso"
    var game = mixedTeamGame()
    let frame = game.fullFrame()
    check frame.shimmerCentres().len == 3    # seats 0, 2 (Red) and 5 (Blue)

  test "a STALE per-team shimmer payload shimmers nobody":
    # The regression this change exists to prevent. `shimmer` used to live
    # inside each `teams` entry; an old platform build still sending that shape
    # must mark NOBODY, because honoring it would light up one policy per team —
    # up to four in a 4-team match, which is the opposite of a singular mark.
    # Note this payload names two policies that ARE in the episode, so a parser
    # that still read the per-team key would light up five of the six seats.
    setTeamDisplayColors(
      """{"v":1,"teams":{"red":{"shimmer":"picasso"},""" &
      """"blue":{"shimmer":"baseline"}}}""")
    installPayloadShimmer()
    check payloadShimmerPolicy() == ""
    check shimmerPolicy() == ""
    check not anyShimmer()
    var game = mixedTeamGame()
    let frame = game.fullFrame()
    check frame.shimmerSpriteIds().len == 0
    check frame.shimmerCentres().len == 0
    for seat in 0 ..< 6:
      check not game.shimmersOnSeat(frame, seat)

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
    setShimmerPolicy("jordan")
    check game.shimmersOnSeat(game.fullFrame(), 1)
    # The platform sending an already-stripped name is the documented case, but
    # a suffixed one still resolves: the seam strips whatever it is handed, so
    # one half forgetting cannot silently un-mark the #1.
    setShimmerPolicy("jordan_(9)")
    check shimmerPolicy() == "jordan"
    check game.shimmersOnSeat(game.fullFrame(), 1)

  test "the sweep advances with the tick and differs by seat":
    # The animation is derived from tickCount alone, so every viewer of a replay
    # agrees on the frame with no animation state to sync. Two seats of the same
    # policy must be out of phase (ShimmerSeatStride), or a squad glints in
    # unison and reads as a UI blink instead of light.
    var game = mixedTeamGame()
    setShimmerPolicy("picasso")
    let atStart = game.fullFrame().shimmerSpriteIds()
    check atStart.len == 3          # seats 0, 2, 5 — three DIFFERENT sweep frames
    check atStart[0] != atStart[1]
    check atStart[1] != atStart[2]
    # Far enough ahead that the frame index must have moved for every seat.
    game.tickCount += 40
    let later = game.fullFrame().shimmerSpriteIds()
    check later.len == 3
    check later.toHashSet() != atStart.toHashSet()
    # Both seats stepped by the same amount, so the phase GAP is preserved:
    # they never converge onto one frame and start glinting in unison.
    check later[1] - later[0] == atStart[1] - atStart[0]

  test "a dead seat wears no sheen":
    var game = mixedTeamGame()
    setShimmerPolicy("picasso")
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
    proc runHashes(policy: string): seq[uint64] =
      setShimmerPolicy(policy)
      var game = mixedTeamGame()
      let none = newSeq[InputState](game.players.len)
      for _ in 0 ..< 12:
        discard game.fullFrame()                  # render, exactly as a viewer
        game.step(none, none)
        result.add game.gameHash()
    let
      off = runHashes("")
      on = runHashes("picasso")                   # three shimmering seats
    check off.len == 12
    check on == off

  test "the dev env stub takes a plain policy name":
    # CTF_SHIMMER is scaffolding, but its shape still teaches the schema: one
    # policy for the whole lobby (docs/COLOR_CONTRACT.md §5), so the stub takes
    # `CTF_SHIMMER=picasso` and not the `red:x,blue:y` pairs the per-team schema
    # used to need.
    check parseShimmerSpec("picasso") == "picasso"
    check parseShimmerSpec("  picasso  ") == "picasso"
    check parseShimmerSpec("jordan_(3)") == "jordan"   # suffix stripped
    # A colon is now part of the NAME — hosted policy names genuinely contain
    # one, and the old parser would have eaten `ctf-focusfire` as a team word.
    check parseShimmerSpec("ctf-focusfire:v62") == "ctf-focusfire:v62"
    # Nothing to fail at: blank means nobody, exactly like an absent value.
    check parseShimmerSpec("") == ""
    check parseShimmerSpec("   ") == ""
