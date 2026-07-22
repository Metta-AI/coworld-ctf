import
  std/[json, os, unittest],
  ctf/[replays, sim],
  "../tools/extract_events"

const
  GameDir = currentSourcePath.parentDir.parentDir
  # The event-substrate fixture: a full 16-bot match recorded against the
  # CURRENT gameplay rules (GameVersion 18, seed 281, lives 9,
  # tools/record_fixture.sh) whose kill mix exercises all three weapons
  # (gun, grenade, plasma) plus steals, returns, heals, and a capture.
  EventsFixture = GameDir / "tests" / "replays" / "ctf.bitreplay"

suite "tier-2 event extraction (tools/extract_events)":
  test "the fixture extracts a rich, ordered, results-consistent event stream":
    let
      data = loadReplay(EventsFixture)
      extraction = extractEvents(data)
      results = parseJson(extraction.resultsJson)
      slotCount = results["names"].len

    # The walk finished (extractEvents raises ReplayError on any recorded
    # hash mismatch, so getting here also proves the fixture re-simulates
    # deterministically) and produced events.
    check extraction.ticks > 0
    check extraction.events.len > 0

    # Event ticks never go backwards.
    var lastTick = 0
    for event in extraction.events:
      check event.tick >= lastTick
      lastTick = event.tick

    # Every Kill is weapon-attributed, first-hand.
    var
      killsBySlot = newSeq[int](slotCount)
      shotsBySlot = newSeq[int](slotCount)
      hitsBySlot = newSeq[int](slotCount)
      sawKill = false
    for event in extraction.events:
      case event.kind
      of Kill:
        sawKill = true
        check event.weapon in ["gun", "plasma", "grenade"]
        check event.source >= 0 and event.source < slotCount
        check event.target >= 0 and event.target < slotCount
        inc killsBySlot[event.source]
      of Shot:
        check event.source >= 0 and event.source < slotCount
        inc shotsBySlot[event.source]
      of Hit:
        check event.source >= 0 and event.source < slotCount
        inc hitsBySlot[event.source]
      else:
        discard
    check sawKill

    # The event stream is the counters, itemized: per-slot Kill events sum to
    # the final results.json kills array, and Shot/Hit events sum to the new
    # tier-1 shotsFired/shotsHit arrays.
    check results["kills"].len == slotCount
    check results["shotsFired"].len == slotCount
    check results["shotsHit"].len == slotCount
    for slot in 0 ..< slotCount:
      check results["kills"][slot].getInt == killsBySlot[slot]
      check results["shotsFired"][slot].getInt == shotsBySlot[slot]
      check results["shotsHit"][slot].getInt == hitsBySlot[slot]

    # results.json mirrors the in-sim accuracy counters exactly.
    for slot in 0 ..< slotCount:
      check results["shotsFired"][slot].getInt == extraction.slotShotsFired[slot]
      check results["shotsHit"][slot].getInt == extraction.slotShotsHit[slot]

  test "the JSONL emitter ends with an honest summary row":
    let
      data = loadReplay(EventsFixture)
      output = extractEventsJsonl(data)
    var
      rows: seq[JsonNode]
      lineStart = 0
    for i in 0 .. output.len:
      if i == output.len or output[i] == '\n':
        if i > lineStart:
          rows.add(parseJson(output[lineStart ..< i]))
        lineStart = i + 1
    check rows.len >= 2
    let summary = rows[^1]
    check summary["type"].getStr == "summary"
    check summary["events"].getInt == rows.len - 1
    check summary["ticks"].getInt > 0
    check summary["gameVersion"].getStr == GameVersion
    # Every non-summary row carries the full event shape.
    for row in rows[0 ..< ^1]:
      for field in ["tick", "kind", "source", "target", "weapon", "amount",
          "x", "y"]:
        check row.hasKey(field)

  test "collectEvents defaults off: a live sim collects nothing":
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      var game = initSimServer(defaultGameConfig())
      let
        shooter = game.addPlayer("red0")
        target = game.addPlayer("blue0")
      game.startGame()
      check game.collectEvents == false
      game.players[shooter].team = Red
      game.players[target].team = Blue
      game.players[shooter].x = game.gameMap.center.x
      game.players[shooter].y = game.gameMap.center.y
      game.players[shooter].aimBrads = 0
      game.players[shooter].windupBrads = -1
      game.players[shooter].fireCooldown = 0
      game.players[shooter].spawnProtect = 0
      game.players[target].x = game.gameMap.center.x + 40
      game.players[target].y = game.gameMap.center.y
      game.players[target].spawnProtect = 0
      game.tryFire(shooter)
      check game.players[shooter].shotsFired == 1
      check game.events.len == 0

      # The sink (and its switch) never enters the game hash.
      let hashBefore = game.gameHash()
      game.collectEvents = true
      game.events.add SimEvent(tick: 1, kind: Shot, source: 0, target: -1)
      check game.gameHash() == hashBefore
    finally:
      setCurrentDir(previousDir)
