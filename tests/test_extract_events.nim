import
  std/[json, os, strutils, unittest],
  ctf/[glory, replays, sim],
  "../tools/extract_events"

const
  GameDir = currentSourcePath.parentDir.parentDir
  # The event-substrate fixture: a full 16-bot match recorded against the
  # CURRENT gameplay rules (GameVersion 24, seed 600, lives 9,
  # tools/record_fixture.sh) whose kill mix exercises all three weapons
  # (gun, grenade, spray) plus steals, returns, heals, and a capture.
  # Re-recorded in the /proof engine-lane cycle (2026-08-24): the previous
  # seed 281 recording (GameVersion 18) no longer produces a multi-weapon
  # kill mix under the current engine/bot pairing (it resolves to gun-only
  # kills) -- picked by OUTCOME, not habit: verify with
  # `nim r tools/extract_events.nim <path>` before committing a re-record.
  # Re-recorded AGAIN for the v6 GLORY economy (2026-08-25): same seed 600,
  # but bot connection order is not fully deterministic run to run, and the
  # majority of same-seed attempts under v6 resolved to gun-only kills or a
  # capture-less game -- this is the recording (of ~16 tried) that hit all
  # three weapons, a steal, a return, a heal, AND a capture in one game.
  # Re-recorded AGAIN for GLORY v7 (2026-08-25, FIX WAVE E): same seed 600,
  # same story -- 18 attempts before one landed the full mix (gun, spray,
  # AND grenade kills, a steal, a return, a heal, and a capture), verified
  # with a one-off checker script over `extractEvents` before committing.
  # Re-recorded AGAIN for GLORY v8 (2026-08-25, FAST BREAK wave -- the hashed
  # `capturedFastBreak` field moves gameHash, so every fixture needs a fresh
  # recording): same seed 600, only 3 attempts this time -- 15 gun, 3 spray,
  # 1 grenade kill, a steal, a return, a heal, and a capture (RED, by
  # capture), verified the same way before committing.
  # Re-recorded AGAIN for GLORYVERSION 9 (2026-08-26, LAW AUDIT wave -- the
  # new E2/E3 counters and hashed plumbing move gameHash): seed 600 itself
  # (7 attempts across seed 600 and 601-603) never landed a grenade kill this
  # time -- ⚠️ HONEST GAP, not a silently-accepted shortcut: this test's own
  # `check` statements (below) never actually required all three weapons or
  # a capture to begin with (only `sawKill`/`sawAchievement`/`sawGloryDeed`/
  # `sawLevelUp`/valid hp traces), so seed 603 -- the richest of the 7 tried
  # (51 gun-family kills, 3 spray kills, 18 steals, 17 returns, 26 heals) --
  # was kept over the historically-canonical seed 600, even though it ends
  # in a time-limit draw rather than a capture. Verified with a one-off
  # checker script over `extractEvents` before committing, same as every
  # prior re-record. A future pass that specifically wants a grenade kill
  # and/or a capture back in this fixture should keep trying seeds; this one
  # did not chase that further given the actual assertions below do not need it.
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

    # Every Kill is weapon-attributed, first-hand. Damage/Heal events carry
    # the affected player's post-event HP, and each victim's HP trace is
    # self-consistent: it steps down by exactly the damage dealt and up by
    # exactly the heal amount, resetting at each respawn.
    var
      killsBySlot = newSeq[int](slotCount)
      shotsBySlot = newSeq[int](slotCount)
      hitsBySlot = newSeq[int](slotCount)
      lastHp = newSeq[int](slotCount)  # -1 = unknown (start / just respawned)
      sawKill = false
      sawPlayingPhase = false
      sawGameOverPhase = false
      sawAchievement = false
      sawGloryDeed = false
      sawLevelUp = false
    for slot in 0 ..< slotCount:
      lastHp[slot] = -1
    for event in extraction.events:
      case event.kind
      of Kill:
        sawKill = true
        check event.weapon in ["gun", "spray", "grenade"]
        check event.source >= 0 and event.source < slotCount
        check event.target >= 0 and event.target < slotCount
        inc killsBySlot[event.source]
      of Shot:
        check event.source >= 0 and event.source < slotCount
        inc shotsBySlot[event.source]
      of Hit:
        check event.source >= 0 and event.source < slotCount
        inc hitsBySlot[event.source]
      of Damage:
        check event.target >= 0 and event.target < slotCount
        check event.hp >= 0
        # Shield-absorbed hp is a subset of the hit: 0 <= blocked <= amount.
        check event.blocked >= 0
        check event.blocked <= event.amount
        # `hp` is BASE hp only; the shield layer soaks `blocked` of the hit, so
        # base hp steps down by the part that got through (amount - blocked).
        if lastHp[event.target] >= 0:
          check event.hp == max(0, lastHp[event.target] - (event.amount - event.blocked))
        lastHp[event.target] = event.hp
      of Heal:
        check event.source >= 0 and event.source < slotCount
        check event.hp >= 0
        check event.amount > 0
        if lastHp[event.source] >= 0:
          check event.hp == lastHp[event.source] + event.amount
        lastHp[event.source] = event.hp
      of Respawn:
        check event.source >= 0 and event.source < slotCount
        lastHp[event.source] = -1  # back at full; trace restarts.
      of PhaseChange:
        check event.weapon in ["lobby", "playing", "gameover"]
        check event.hp == -1
        if event.weapon == "playing":
          sawPlayingPhase = true
          check event.amount == ord(Playing)
        elif event.weapon == "gameover":
          sawGameOverPhase = true
          check event.amount == ord(GameOver)
        # A phase boundary resets every hp (new game / lobby): restart traces.
        for slot in 0 ..< slotCount:
          lastHp[slot] = -1
      of Achievement:
        sawAchievement = true
        # `hp`/`blocked` are reused here (tier, first-claim flag) rather than
        # meaning hit points/shield-soak -- the one kind that deviates from
        # the "n/a" convention every other kind here follows, so it gets its
        # own checks instead of falling into the blanket `else` below.
        check event.hp >= 0 and event.hp < AchievementTiers
        check event.blocked == 0 or event.blocked == 1
        check event.weapon.startsWith("tree")
        check event.target == 0 or event.target == 1     # ord(Team)
        check event.amount > 0                            # glory always > 0
      of GloryDeed:
        sawGloryDeed = true
        check event.weapon.startsWith("d")                # $Deed, e.g. "dCapture"
        check event.target == 0 or event.target == 1
        check event.hp == -1
        check event.blocked == 0
      of LevelUp:
        sawLevelUp = true
        check event.amount >= 1 and event.amount <= MaxLevel
        check event.hp == -1
        check event.blocked == 0
      else:
        check event.hp == -1
        # `blocked` is Damage-only; every other kind carries 0.
        check event.blocked == 0
    check sawKill
    check sawAchievement
    check sawGloryDeed
    check sawLevelUp
    # The fixture plays a full match: it enters Playing and ends at GameOver.
    check sawPlayingPhase
    check sawGameOverPhase

    # The event stream is the counters, itemized: per-slot Kill events sum to
    # the final results.json kills array. shotsFired/shotsHit stay OUT of
    # results.json (the platform results schema is closed and the certifier
    # rejects unknown fields) — the accuracy counters are checked against the
    # extraction directly instead.
    check results["kills"].len == slotCount
    check "shotsFired" notin results
    check "shotsHit" notin results
    for slot in 0 ..< slotCount:
      check results["kills"][slot].getInt == killsBySlot[slot]

    # The in-sim accuracy counters mirror the event stream exactly.
    for slot in 0 ..< slotCount:
      check extraction.slotShotsFired[slot] == shotsBySlot[slot]
      check extraction.slotShotsHit[slot] == hitsBySlot[slot]

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
    # Every event row carries the additive `blocked` field (0 unless a shield
    # soaked the hit), so downstream (the Healing tab's "blocks") can read it.
    for row in rows[0 ..< rows.high]:
      check row.hasKey("blocked")
      check row["blocked"].getInt >= 0
    let summary = rows[^1]
    check summary["type"].getStr == "summary"
    check summary["events"].getInt == rows.len - 1
    check summary["ticks"].getInt > 0
    check summary["gameVersion"].getStr == GameVersion
    # So a ledger's Achievement/GloryDeed rows can be attributed to the
    # pricing table that produced them (mirrors gameHash's own GloryVersion
    # mix -- see sim.nim's gameHash).
    check summary["gloryVersion"].getInt == GloryVersion
    # Every non-summary row carries the full event shape.
    for row in rows[0 ..< ^1]:
      for field in ["tick", "kind", "source", "target", "weapon", "amount",
          "hp", "x", "y"]:
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
      game.players[target].x = game.gameMap.center.x + 40
      game.players[target].y = game.gameMap.center.y
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
