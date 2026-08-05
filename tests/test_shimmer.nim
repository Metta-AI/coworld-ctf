import
  helpers,
  std/[algorithm, sets, strutils, tables, unittest],
  bitworld/spriteprotocol,
  supersnappy,
  ctf/[global, labels, shimmer, sim, team_colors]

# Metallic paint: the PER-AGENT re-bake that marks the ONE league #1's cogs — at
# most one policy in the whole lobby, usually none (src/ctf/shimmer.nim,
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
# DETECTION IS BY PIXELS, and it has to be. The mark used to be its own overlay
# sprite with its own label, which made it trivial to find; it is now a metallic
# re-bake of the cog's own head art, and that bake keeps the STOCK head's label
# by contract — a label scanner must still read the league #1's cog as
# `player <color>`, or flagging a policy would blind every bot to it. So there is
# no label and no id to look for, and the only honest question left is the one a
# spectator asks: does THIS cog's shell look like metal? `metalOnSeat` answers it
# from the decoded sprite, which also means these tests fail if the material ever
# stops producing a specular — a stricter promise than the old label check made.

const MetalPeakLuma = 235.0
  ## Rec.709 luma a head bake must reach to count as metal. The stock bakes top
  ## out at ~221 on every palette slug (their own brightest painted pixel) and
  ## the material's blown specular lands at ~251, so this threshold sits in a
  ## ~30-luma gap. It is deliberately an ABSOLUTE brightness rather than a
  ## difference: "the flagged cog owns the top of the luminance distribution" is
  ## the property that keeps the trophy mark from reading as a dirty cog, and it
  ## is worth failing on.

proc headBakes(
  messages: openArray[SpritePacketMessage]
): Table[int, tuple[label: string, peak: float]] =
  ## Peak luminance of every RIG HEAD sprite defined in this packet, by sprite
  ## id. The rig head is the sprite carrying the bare `player <color>` contract
  ## label; the POV soldier pool shares the prefix but carries a `<side>` tail,
  ## which is the only difference that does not move with the board scale.
  for message in messages:
    if message.kind != spkSprite:
      continue
    let sprite = message.sprite
    if not sprite.label.startsWith(LabelPrefixPlayer) or
        sprite.label.split(' ').len != 2:
      continue
    let raw = supersnappy.uncompress(sprite.compressedPixels)
    var peak = 0.0
    var i = 0
    while i + 3 < raw.len:
      if raw[i + 3] > 200'u8:
        peak = max(peak, 0.2126 * float(raw[i]) + 0.7152 * float(raw[i + 1]) +
          0.0722 * float(raw[i + 2]))
      i += 4
    result[sprite.id] = (label: sprite.label, peak: peak)

proc metalSpriteIds(messages: openArray[SpritePacketMessage]): seq[int] =
  ## Every head sprite in this packet baked in the metallic material.
  for id, bake in messages.headBakes():
    if bake.peak >= MetalPeakLuma:
      result.add id
  result.sort()

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

proc metalOnSeat(
  sim: SimServer,
  messages: openArray[SpritePacketMessage],
  seat: int
): bool =
  ## Whether the cog at `seat` is drawn with the METALLIC bake of its head.
  ## Positional rather than id-based on purpose: it proves the material landed on
  ## the RIGHT agent, which an object-id check would take on faith.
  let
    scale = boardRenderScaleFor(sim.gameMap.width, sim.gameMap.height)
    metals = messages.metalSpriteIds()
    # Rig segment sprites are HUB-centered in a RigCanvas square, so the object's
    # top-left plus half the canvas is the cog itself.
    half = RigCanvas * scale div 2
    px = sim.players[seat].x * scale
    py = sim.players[seat].y * scale
  for message in messages:
    if message.kind != spkObject or message.objectDef.spriteId notin metals:
      continue
    if abs(message.objectDef.x + half - px) <= 2 * scale and
        abs(message.objectDef.y + half - py) <= 2 * scale:
      return true
  false

proc metalCogCount(
  sim: SimServer,
  messages: openArray[SpritePacketMessage]
): int =
  ## How many of this frame's cogs wear the material — the "nothing is being
  ## drawn off-cog / on too many cogs" counterpart to the per-seat check.
  for seat in 0 ..< sim.players.len:
    if sim.metalOnSeat(messages, seat):
      inc result

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
    check messages.metalSpriteIds().len == 0
    check game.metalCogCount(messages) == 0
    check not anyShimmer()

  test "only the flagged policy's seats shimmer, teammates render stock":
    var game = mixedTeamGame()
    setShimmerPolicy("focusfire")
    let frame = game.fullFrame()
    # focusfire holds exactly one seat in this episode, so exactly one cog in
    # the whole frame wears the sheen. Seats 0 and 2 are its own TEAMMATES and
    # must render stock — the single pair of lines that separates a per-AGENT
    # flag from a per-team one.
    check game.metalOnSeat(frame, 4)
    check not game.metalOnSeat(frame, 0)
    check not game.metalOnSeat(frame, 2)
    check not game.metalOnSeat(frame, 1)
    check not game.metalOnSeat(frame, 3)
    check not game.metalOnSeat(frame, 5)
    # Exactly one overlay in the frame, so nothing is being drawn off-cog.
    check game.metalCogCount(frame) == 1

  test "one policy seated on two teams shimmers on BOTH":
    # The flag is a league standing, not a team property. picasso holds seats 0
    # and 2 on Red and seat 5 on Blue; all three are the #1's agents, so all
    # three wear the sheen while their respective teammates do not.
    var game = mixedTeamGame()
    setShimmerPolicy("picasso")
    let frame = game.fullFrame()
    check game.metalOnSeat(frame, 0)      # Red picasso
    check game.metalOnSeat(frame, 2)      # Red picasso
    check game.metalOnSeat(frame, 5)      # Blue picasso — the cross-team half
    check not game.metalOnSeat(frame, 4)  # Red focusfire
    check not game.metalOnSeat(frame, 1)  # Blue jordan
    check not game.metalOnSeat(frame, 3)  # Blue baseline
    check game.metalCogCount(frame) == 3

  test "a flagged policy that is not in this episode shimmers nobody":
    # The NORMAL case for a real payload: the league #1 is not in most matches,
    # so the viewer is handed a name no seat answers to. That must render a
    # stock board in silence — not raise, not fall back to marking somebody.
    var game = mixedTeamGame()
    setShimmerPolicy("ctf-nemesis:v9")
    let frame = game.fullFrame()
    check anyShimmer()                       # a policy IS flagged...
    check shimmerPolicy() == "ctf-nemesis:v9"
    check frame.metalSpriteIds().len == 0  # ...and nothing draws.
    check game.metalCogCount(frame) == 0
    for seat in 0 ..< 6:
      check not game.metalOnSeat(frame, seat)

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
    check game.metalCogCount(frame) == 3    # seats 0, 2 (Red) and 5 (Blue)

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
    check frame.metalSpriteIds().len == 0
    check game.metalCogCount(frame) == 0
    for seat in 0 ..< 6:
      check not game.metalOnSeat(frame, seat)

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
    check game.metalOnSeat(game.fullFrame(), 1)
    # The platform sending an already-stripped name is the documented case, but
    # a suffixed one still resolves: the seam strips whatever it is handed, so
    # one half forgetting cannot silently un-mark the #1.
    setShimmerPolicy("jordan_(9)")
    check shimmerPolicy() == "jordan"
    check game.metalOnSeat(game.fullFrame(), 1)

  test "the glint advances with the tick and differs by seat":
    # The animation is derived from tickCount alone, so every viewer of a replay
    # agrees on the frame with no animation state to sync — scrubbing backwards
    # lands on exactly the pixels the forward pass showed.
    check cogMetalPhase(0, 0) == cogMetalPhase(0, 0)
    check cogMetalPhase(0, 0) != cogMetalPhase(CogMetalTicksPerFrame, 0)
    # Two seats of the same policy must be out of phase (CogMetalSeatStride is
    # coprime with the frame count), or a squad glints in unison and reads as a
    # UI blink instead of light on a surface.
    check cogMetalPhase(0, 0) != cogMetalPhase(0, 1)
    check cogMetalPhase(0, 1) != cogMetalPhase(0, 2)
    var game = mixedTeamGame()
    setShimmerPolicy("picasso")
    # Seats 0 and 2 are the same TEAM at different phases and seat 5 is another
    # team, so three metallic head bakes, all distinct.
    let atStart = game.fullFrame().metalSpriteIds()
    check atStart.len == 3
    check atStart.toHashSet().len == 3
    # Far enough ahead that the phase must have moved for every seat.
    game.tickCount += 5 * CogMetalTicksPerFrame
    let later = game.fullFrame().metalSpriteIds()
    check later.len == 3
    check later.toHashSet() != atStart.toHashSet()

  test "the material rides the cog's ORIENTATION, not just the clock":
    # The headline property, and the one the retired overlay structurally could
    # not have: turn the cog and the highlight moves, because the facets are
    # anchored in the cog's own frame while the light is anchored in the world.
    # Asserted on the BAKES rather than on a sprite id, because an id changing
    # only proves the cache key has an aim in it — this proves the PIXELS differ.
    var seen: HashSet[string]
    for aim in 0 ..< RigSteps:
      let pixels = rigMetalSegPixels(Red, rsHead, aim, 0, 2)
      var digest = ""
      for i in countup(0, pixels.len - 4, 997):
        digest.add char(pixels[i])
      seen.incl digest
    # Every aim step is its own bake. (The stock art already differs per aim, so
    # the real content of this check is the pair of asserts below.)
    check seen.len == RigSteps
    # At ONE aim, the material still differs from the stock bake — it is not a
    # pass-through — and it is BRIGHTER at the peak, so the trophy mark can never
    # read as a cog sitting in shadow.
    proc peak(px: seq[uint8]): float =
      var i = 0
      while i + 3 < px.len:
        if px[i + 3] > 200'u8:
          result = max(result, 0.2126 * float(px[i]) + 0.7152 * float(px[i + 1]) +
            0.0722 * float(px[i + 2]))
        i += 4
    let
      stock = rigSegPixels(Red, rsHead, 3, 0, 0, 2)
      metal = rigMetalSegPixels(Red, rsHead, 3, 0, 2)
    check metal != stock
    check peak(metal) > peak(stock)
    # ...and the silhouette is untouched: the material may only repaint pixels
    # the cog art already owns, so a label scanner sees the same shape it always
    # did and the mark cannot change what a bot can see.
    for i in countup(3, stock.len - 1, 4):
      check metal[i] == stock[i]

  test "a dead seat wears no sheen":
    var game = mixedTeamGame()
    setShimmerPolicy("picasso")
    check game.metalOnSeat(game.fullFrame(), 0)
    game.players[0].alive = false
    let frame = game.fullFrame()
    check not game.metalOnSeat(frame, 0)
    check game.metalOnSeat(frame, 2)

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
