## The tier-2 events artifact contract (src/ctf/events.nim): the serializer both
## producers share, and the truncation guard the live emitter relies on.
##
## The live-emitter == resim equivalence is proven end-to-end by
## tools/verify_events_producer.sh (it records a real 16-bot episode with
## COGAME_EVENTS_URI set, then resims that replay and diffs the two artifacts);
## this suite covers the format itself, which is cheap enough to run in CI.

import
  std/[json, os, strutils, unittest],
  ctf/[events, sim]

const GameDir = currentSourcePath.parentDir.parentDir

proc rows(artifact: string): seq[JsonNode] =
  ## Parses a JSON-lines artifact into its rows.
  for line in artifact.splitLines():
    if line.len > 0:
      result.add(parseJson(line))

suite "tier-2 events artifact (src/ctf/events)":
  test "every event kind has a distinct, stable wire key":
    # The keys are the platform's channel `eventKind` contract: a collision
    # would silently merge two channels, a rename would blank a tab.
    var seen: seq[string]
    for kind in SimEventKind:
      let key = kind.key()
      check key.len > 0
      check key notin seen
      seen.add(key)
    # Spot-check the exact spellings the checked-in logs manifest maps to.
    check Kill.key() == "kill"
    check Death.key() == "death"
    check Capture.key() == "capture"
    check FlagSteal.key() == "flag_steal"
    check PhaseChange.key() == "phase"

  test "a row carries every field, always":
    let row = SimEvent(
      tick: 42, kind: Damage, source: 3, target: 7, weapon: "gun",
      amount: 2, hp: 1, blocked: 1, x: 12.5, y: 90.25
    ).jsonRow()
    for field in ["tick", "kind", "source", "target", "weapon", "amount",
        "hp", "blocked", "x", "y"]:
      check row.hasKey(field)
    check row["tick"].getInt == 42
    check row["kind"].getStr == "damage"
    check row["source"].getInt == 3
    check row["target"].getInt == 7
    check row["weapon"].getStr == "gun"
    check row["amount"].getInt == 2
    check row["hp"].getInt == 1
    check row["blocked"].getInt == 1
    check row["x"].getFloat == 12.5
    check row["y"].getFloat == 90.25

  test "the artifact is one row per event plus an honest summary":
    let
      sample = @[
        SimEvent(tick: 1, kind: Shot, source: 0, target: -1, weapon: "gun"),
        SimEvent(tick: 2, kind: Kill, source: 0, target: 1, weapon: "gun"),
      ]
      parsed = rows(eventsJsonl(sample, ticks = 99))
    check parsed.len == sample.len + 1
    check parsed[0]["kind"].getStr == "shot"
    check parsed[1]["kind"].getStr == "kill"
    let summary = parsed[^1]
    check summary["type"].getStr == "summary"
    check summary["events"].getInt == sample.len
    check summary["ticks"].getInt == 99
    check summary["gameVersion"].getStr == GameVersion
    # `truncated` is present even when false, so a reader never guesses.
    check summary.hasKey("truncated")
    check summary["truncated"].getBool == false

  test "an empty episode still writes a parseable, self-describing artifact":
    # A game that ended before anything happened must not produce a file the
    # ingest chokes on: the platform parser reads this as an empty stream.
    let parsed = rows(eventsJsonl(@[], ticks = 0))
    check parsed.len == 1
    check parsed[0]["type"].getStr == "summary"
    check parsed[0]["events"].getInt == 0

  test "truncation is recorded in the summary, not hidden":
    let parsed = rows(eventsJsonl(
      @[SimEvent(tick: 1, kind: Shot)], ticks = 5, truncated = true
    ))
    check parsed[^1]["truncated"].getBool == true

  test "the artifact always ends in a newline, so appends stay line-safe":
    check eventsJsonl(@[], ticks = 0).endsWith("\n")
    check eventsJsonl(@[SimEvent(tick: 1, kind: Shot)], ticks = 1).endsWith("\n")

  test "the sink stays off by default and never enters the game hash":
    # The live emitter turns collectEvents on only when COGAME_EVENTS_URI is
    # set; a plain live server must pay nothing and hash identically.
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      var game = initSimServer(defaultGameConfig())
      check game.collectEvents == false
      let hashBefore = game.gameHash()
      game.collectEvents = true
      game.events.add SimEvent(tick: 1, kind: Shot, source: 0)
      check game.gameHash() == hashBefore
    finally:
      setCurrentDir(previousDir)
