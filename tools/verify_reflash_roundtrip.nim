## The ROUND TRIP, on a real recorded match — the one thing neither building
## lane could run.
##
## The engine lane proved a synthesized episode re-simulates; the runner lane
## proved a page reaches the wire. Neither could prove that a page a REAL bot
## put on a REAL socket, drained by the REAL server at a REAL tick boundary,
## comes back out of the file. This runs both directions over one recorded
## `.bitreplay`, through `expandReplayTimeline` — the SHIPPED divergence
## instrument — so the verdict is the tool's and not this file's:
##
##   POSITIVE  the match as recorded re-simulates with zero divergence.
##   NEGATIVE  the SAME bytes with ONLY the reflash records dropped diverge,
##             at the tick immediately after the first dropped flash.
##
## The negative is what makes the positive mean anything. A replay with no
## flashes in it at all would pass the positive arm trivially, so this tool
## REFUSES a replay that carries no reflash records rather than reporting a
## vacuous success.

import
  std/[algorithm, os, sequtils, strformat, strutils],
  ../src/ctf/[replays, sim],
  expand_replay

proc reflashRecords(data: ReplayData): seq[ReplayChat] =
  data.chats.filterIt(it.isPolicyPageRecord())

proc withoutReflashRecords(data: ReplayData): ReplayData =
  ## The exact replay a build that never recorded the event would produce.
  result = data
  result.chats = data.chats.filterIt(not it.isPolicyPageRecord())

proc tickOfTime(time: uint32): int =
  ## The tick a recorded timestamp was stamped at (tickTime is monotone).
  result = -1
  for tick in 0 .. 200_000:
    if tickTime(tick) == time:
      return tick

const StartFlashSlackTicks = 60
  ## How far after the opening edge a flash still counts as "the starting
  ## page". The runner flashes on its OWN first live frame, which trails the
  ## sim's phase change by however long its socket takes to see the new
  ## phase — a handful of frames, not hundreds. Anything past this is a
  ## mid-episode flash.

when isMainModule:
  let requireMid = getEnv("REQUIRE_MID_FLASH", "1") != "0"
  if paramCount() < 1:
    quit("Usage: verify_reflash_roundtrip <replay.bitreplay>", 1)
  let
    path = paramStr(1)
    data = parseReplayBytes(readFile(path))
    flashes = data.reflashRecords()

  echo "replay: ", path
  echo "  ticks recorded : ", data.hashes.len
  echo "  chat records   : ", data.chats.len,
    "  (reflash ", flashes.len, ", shouts ", data.chats.len - flashes.len, ")"

  if flashes.len == 0:
    quit("FAIL: this replay carries NO reflash records — the positive arm " &
      "would pass vacuously and the negative arm has nothing to drop. " &
      "The receive arm did not deliver, or the gate was not armed.", 1)

  var flashTicks: seq[int] = @[]
  for chat in flashes:
    let
      tick = tickOfTime(chat.time)
      page = chat.decodePolicyPageRecord()
    flashTicks.add(tick)
    echo &"  FLASH tick={tick} cog={chat.policyPageRecordPlayer()} " &
      &"bytes={page.len} hash={toHex(policyPageHash(page), 16)}"
  flashTicks.sort()

  echo ""
  echo "POSITIVE: re-simulate the match exactly as recorded"
  let live = expandReplayTimeline(data)
  if live.hashFailed:
    quit(&"  FAIL: diverged at tick {live.failTick} — the recorded match " &
      "does not re-simulate. The round trip is BROKEN.", 1)
  echo &"  PASS: {live.tickCount} ticks re-simulated, ZERO divergence."

  # WHERE the flashes land, relative to the episode itself. The starting
  # page is the interesting one: it is delivered to the runner by an env
  # var, which is a hidden input the replay cannot witness — unless the
  # runner puts it on the wire like any other flash. So the FIRST flash
  # landing at the episode's opening edge is the proof that it did.
  var startTick = -1
  for event in live.events:
    if event.kind == PhaseChanged and event.phase == Playing:
      startTick = event.tick
      break
  echo ""
  echo "EPISODE-START FLASH"
  if startTick < 0:
    echo "  (no Playing phase change in the timeline; skipping the offset check)"
  else:
    echo &"  match went Playing at tick {startTick}"
    echo &"  first flash at tick {flashTicks[0]} " &
      &"(+{flashTicks[0] - startTick} ticks after the opening edge)"
    if flashTicks[0] < startTick:
      quit("  FAIL: a flash was recorded BEFORE the episode began.", 1)
    if flashTicks[0] - startTick > StartFlashSlackTicks:
      quit(&"  FAIL: the first flash is {flashTicks[0] - startTick} ticks " &
        &"after the opening edge, past the {StartFlashSlackTicks}-tick " &
        "slack. The starting page is NOT being flashed at episode start — " &
        "it is a hidden input.", 1)
    echo "  PASS: the STARTING page is a recorded event, not a hidden input."

  let midFlashes = flashTicks.filterIt(it - startTick > StartFlashSlackTicks)
  echo ""
  echo "MID-EPISODE REFLASH"
  if requireMid and midFlashes.len == 0:
    quit(&"  FAIL: all {flashTicks.len} flash(es) sit inside the " &
      "episode-start window. No MID-EPISODE reflash was recorded, so this " &
      "run only proves the opening flash.", 1)
  if midFlashes.len == 0:
    echo "  (none recorded on this run)"
  else:
    echo &"  {midFlashes.len} mid-episode flash(es) at ticks {midFlashes}"
    echo "  PASS: a page swapped UNDER a live cog and reached the file."

  echo ""
  echo "NEGATIVE: the same bytes with ONLY the reflash records dropped"
  let stripped = data.withoutReflashRecords()
  doAssert stripped.hashes == data.hashes, "control changed the hash stream"
  doAssert stripped.inputs == data.inputs, "control changed the input stream"
  doAssert stripped.chats.len == data.chats.len - flashes.len
  let dead = expandReplayTimeline(stripped)
  if not dead.hashFailed:
    quit(&"  FAIL: dropping {flashes.len} reflash record(s) changed NOTHING " &
      "— the page is not in gameHash, so the replay cannot witness it. " &
      "The round trip is VACUOUS.", 1)
  let expected = flashTicks[0] + 1
  echo &"  PASS: diverged at tick {dead.failTick}."
  if dead.failTick != expected:
    quit(&"  FAIL: expected divergence at tick {expected} (first flash " &
      &"{flashTicks[0]} + 1), got {dead.failTick}. The event does not land " &
      "where it was recorded.", 1)
  echo &"  PASS: divergence tick is EXACTLY first-flash({flashTicks[0]}) + 1."

  # EACH flash on its own. Dropping all of them only proves the FIRST one is
  # load-bearing — every later flash could be inert and this would still go
  # red at the same tick. Dropping exactly one at a time is what shows the
  # mid-episode flashes are carried too, and that each lands on its own
  # recorded tick rather than being folded into the opening one.
  if flashes.len > 1:
    echo ""
    echo "NEGATIVE, per flash: drop exactly ONE record at a time"
    for i in 0 ..< flashes.len:
      var one = data
      one.chats = @[]
      var seen = 0
      for chat in data.chats:
        if chat.isPolicyPageRecord():
          if seen == i:
            inc seen
            continue
          inc seen
        one.chats.add(chat)
      doAssert one.chats.len == data.chats.len - 1
      let
        tick = tickOfTime(flashes[i].time)
        solo = expandReplayTimeline(one)
      if not solo.hashFailed:
        quit(&"  FAIL: dropping the flash at tick {tick} changed nothing — " &
          "that record is inert and the replay does not witness it.", 1)
      if solo.failTick != tick + 1:
        quit(&"  FAIL: dropping the flash at tick {tick} diverged at " &
          &"{solo.failTick}, not {tick + 1}.", 1)
      echo &"  PASS: drop flash #{i} (tick {tick}) -> diverges at " &
        &"{solo.failTick} = {tick} + 1."

  echo ""
  echo "ROUND TRIP VERIFIED: both directions, on a recorded match."
