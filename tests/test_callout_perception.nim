## Discriminating pair for the engine half of the callout/ping system
## (~/.ctf/knowledge/callout-spec.md §4/§5): gate OFF, a `!<id>[ <cell>]`
## chat message must be completely indistinguishable from ordinary chat at
## every layer a policy can observe (gameplay state, gameHash, and the
## sprite-label wire); gate ON, it must decode as a structured CALLOUT a
## policy can perceive by label PREFIX instead of re-parsing raw text, while
## the human-visible bubble (buildShoutBubble, which always draws the raw
## text) stays exactly what it was.
##
## Asserted against the SOURCE contract (Shout.isCallout/calloutId/
## calloutCell in sim_types.nim, parseCallout in sim.nim, labelCallout in
## labels.nim) — not against this file's own prose.

import
  helpers,
  std/[os, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, labels, sim]

proc calloutGame(seats: int, allowCallouts: bool): SimServer =
  ## `seats` named players (see helpers.namedGame) on a config whose
  ## allowCallouts gate is set explicitly, so a test can hold every other
  ## default fixed and vary only the one flag under test.
  var config = defaultGameConfig()
  config.allowCallouts = allowCallouts
  result = initCtfForTest(config)
  for i in 0 ..< seats:
    discard result.addPlayer("policy" & $i)
  result.startGame()

proc standOn(sim: var SimServer, viewer, target: int) =
  sim.players[viewer].x = sim.players[target].x
  sim.players[viewer].y = sim.players[target].y

proc pingLabels(sim: var SimServer, viewerIndex: int): seq[string] =
  ## Every shout-OR-callout bubble label one viewer receives — the same
  ## build path test_shouts.nim's shoutLabels uses, widened to also catch
  ## the new `<color> callout ` family (which does not contain " shout ").
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  var packet: seq[uint8]
  try:
    var
      state: PlayerViewerState
      nextState: PlayerViewerState
    packet = sim.buildSpriteProtocolPlayerUpdates(viewerIndex, state, nextState)
  finally:
    setCurrentDir(previousDir)
  for message in packet.parseSpritePacket():
    if message.kind == spkSprite and
        (" shout " in message.sprite.label or
         " callout " in message.sprite.label):
      result.add message.sprite.label

suite "callout gate off: byte-identical to plain chat":
  test "a bang message parses to zero-value callout fields":
    var sim = calloutGame(2, allowCallouts = false)
    check sim.applyShout(0, "!3")
    let shout = sim.recentShouts[0]
    check shout.isCallout == false
    check shout.calloutId == 0
    check shout.calloutCell == ""
    # The raw text — what buildShoutBubble draws for a HUMAN — is untouched.
    check shout.text == "!3"

  test "the perceived label is the ordinary shout label, not the callout one":
    var sim = calloutGame(2, allowCallouts = false)
    check sim.applyShout(0, "!1 F9")
    sim.standOn(viewer = 1, target = 0)
    let heard = sim.pingLabels(viewerIndex = 1)
    check heard == @[labelShout("red", "alpha", "!1 F9")]

  test "gameHash is unaffected by callout parsing when the gate is off":
    # Same scenario run twice, once through a bang message and once through
    # plain text of equal weight; the ONLY thing gameHash may depend on here
    # is shout.text's bytes (already true pre-callout) — never
    # isCallout/calloutId/calloutCell, which is exactly what stays gated in
    # sim_state.nim's gameHash.
    var sim1 = calloutGame(2, allowCallouts = false)
    var sim2 = calloutGame(2, allowCallouts = false)
    check sim1.gameHash == sim2.gameHash
    check sim1.applyShout(0, "!3")
    check sim2.applyShout(0, "!3")
    check sim1.gameHash == sim2.gameHash

suite "callout gate on: a ping is a distinct, perceivable event":
  test "a bare id parses to a callout with no cell":
    var sim = calloutGame(2, allowCallouts = true)
    check sim.applyShout(0, "!3")
    let shout = sim.recentShouts[0]
    check shout.isCallout == true
    check shout.calloutId == 3
    check shout.calloutCell == ""
    check shout.text == "!3"          # human-visible bubble text unchanged

  test "an id plus a grid cell parses both fields":
    var sim = calloutGame(2, allowCallouts = true)
    check sim.applyShout(0, "!1 F9")
    let shout = sim.recentShouts[0]
    check shout.isCallout == true
    check shout.calloutId == 1
    check shout.calloutCell == "F9"

  test "the perceived label switches to the callout prefix, by the source contract":
    var sim = calloutGame(2, allowCallouts = true)
    check sim.applyShout(0, "!1 F9")
    sim.standOn(viewer = 1, target = 0)
    let heard = sim.pingLabels(viewerIndex = 1)
    check heard == @[labelCallout("red", "alpha", 1, "F9")]
    check heard == @["red callout alpha: 1 F9"]
    # A policy scanning by PREFIX (callout-spec.md's "labels are the API,
    # read by PREFIX") finds it under the NEW family, not the old one.
    check heard[0].startsWith(labelCalloutPrefix("red"))
    check not heard[0].startsWith(labelShoutPrefix("red"))

  test "malformed bang text falls through to plain chat even with the gate on":
    var sim = calloutGame(2, allowCallouts = true)
    for badText in ["!", "!9", "!12", "!3x", "!7 A5"]:
      sim.players[0].lastShoutTick = -1
      check sim.applyShout(0, badText)
      let shout = sim.recentShouts[0]
      check shout.isCallout == false
      check shout.calloutId == 0
      check shout.calloutCell == ""
      check shout.text == badText

  test "ordinary chat (no bang) is still an ordinary shout":
    var sim = calloutGame(2, allowCallouts = true)
    check sim.applyShout(0, "push mid")
    let shout = sim.recentShouts[0]
    check shout.isCallout == false
    sim.standOn(viewer = 1, target = 0)
    check sim.pingLabels(viewerIndex = 1) == @[labelShout("red", "alpha", "push mid")]

  test "determinism: two identical runs with the gate on hash identically":
    var sim1 = calloutGame(2, allowCallouts = true)
    var sim2 = calloutGame(2, allowCallouts = true)
    check sim1.gameHash == sim2.gameHash
    check sim1.applyShout(0, "!2 A5")
    check sim2.applyShout(0, "!2 A5")
    check sim1.gameHash == sim2.gameHash
    let none = newSeq[InputState](sim1.players.len)
    for _ in 0 ..< 30:
      sim1.step(none, none)
      sim2.step(none, none)
      check sim1.gameHash == sim2.gameHash

  test "a callout is proximity-gated exactly like a shout: in range heard, out of range not":
    var sim = calloutGame(2, allowCallouts = true)
    check sim.applyShout(0, "!4")
    let shout = sim.recentShouts[0]
    sim.players[1].x = shout.x + ShoutRange - 1 - CollisionW div 2
    sim.players[1].y = shout.y - CollisionH div 2
    check sim.pingLabels(viewerIndex = 1).len == 1
    check sim.pingLabels(viewerIndex = 1)[0].startsWith(labelCalloutPrefix("red"))
    sim.players[1].x = shout.x + ShoutRange + 1 - CollisionW div 2
    check sim.pingLabels(viewerIndex = 1).len == 0
