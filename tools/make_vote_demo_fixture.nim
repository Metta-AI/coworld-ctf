## DEMO fixture builder for the viewer's MAP VOTE act: re-emits a real hosted
## replay byte stream through the sanctioned CtfReplayWriter, injecting a
## synthetic pre-match ballot (record 0x17) into the lobby span -- casts
## spread over ms 2100..6900 (before the first huddle line) and a resolution.
## Chrome-only: no config or input changes, the sim timeline is untouched.
## Usage: vp_make_vote_fixture <in.replay> <out.replay>
import std/[algorithm, json, os]
import ../src/ctf/replays
import ../src/shell/replay_records

type
  EvKind = enum evJoin, evLeave, evInput, evChat, evDebug, evLobby, evCall,
    evLifecycle, evBallot
  Ev = object
    ms: uint32
    kind: EvKind
    idx: int

when isMainModule:
  if paramCount() < 2:
    quit("usage: vp_make_vote_fixture <in.replay> <out.replay>", 1)
  let data = parseCtfReplayBytesFull(readFile(paramStr(1)))
  let rep = data.replay

  # Synthetic ballot: 14 of 16 seats cast (two abstain), option B wins 6-4-2-2.
  var ballots: seq[BallotRecord]
  let opts = [1'u8, 0, 1, 2, 1, 0, 3, 1, 0, 1, 2, 3, 0, 1]
  var ord = 1'u64
  for i, opt in opts:
    let seat = uint8(i + 1) # seats 1..14; 0 and 15 abstain
    ballots.add(BallotRecord(kind: brkCast,
      replayTimeMs: uint32(2100 + i * 340),
      ordinal: ord, seat: seat, team: seat mod 8, option: opt))
    inc ord
  ballots.add(BallotRecord(kind: brkResolved, replayTimeMs: 7000'u32,
    ordinal: ord, category: 1, tieBreakDrawn: 0, finalOption: 1))

  var events: seq[Ev]
  for i, j in rep.joins: events.add(Ev(ms: j.time, kind: evJoin, idx: i))
  for i, l in rep.leaves: events.add(Ev(ms: l.time, kind: evLeave, idx: i))
  for i, inp in rep.inputs: events.add(Ev(ms: inp.time, kind: evInput, idx: i))
  for i, c in rep.chats: events.add(Ev(ms: c.time, kind: evChat, idx: i))
  for i, d in rep.debugSprites: events.add(Ev(ms: d.time, kind: evDebug, idx: i))
  for i, m in data.shell.lobbyTranscript:
    events.add(Ev(ms: m.replayTimeMs, kind: evLobby, idx: i))
  for i, c in data.shell.calls:
    events.add(Ev(ms: c.replayTimeMs, kind: evCall, idx: i))
  for i, r in data.shell.lifecycle:
    events.add(Ev(ms: r.replayTimeMs, kind: evLifecycle, idx: i))
  for i, b in ballots: events.add(Ev(ms: b.replayTimeMs, kind: evBallot, idx: i))
  events.sort(proc(a, b: Ev): int =
    result = cmp(a.ms, b.ms)
    if result == 0: result = cmp(a.idx, b.idx))

  # The manifest's seat-bucket count must equal the config's PLAY seat
  # count (parseFormat2Records verifies exactly that).
  var playSeats = 0
  let cfg = parseJson(rep.configJson)
  if cfg.hasKey("slots"):
    for slot in cfg["slots"]:
      if slot.kind == JObject and slot.hasKey("control") and
          slot["control"].getStr() == "play":
        inc playSeats
  var w = openReplayWriter(paramStr(2), rep.configJson, CtfReplaySpec,
    shellEpisode = true, shellSeatCount = playSeats)
  for ev in events:
    case ev.kind
    of evJoin:
      let j = rep.joins[ev.idx]
      w.writeJoin(j.time, int(j.player), j.name, j.slot, j.token)
    of evLeave:
      let l = rep.leaves[ev.idx]
      w.writeLeave(l.time, int(l.player))
    of evInput:
      w.writeInput(rep.inputs[ev.idx])
    of evChat:
      let c = rep.chats[ev.idx]
      w.writeChat(c.time, int(c.player), c.message)
    of evDebug:
      let d = rep.debugSprites[ev.idx]
      w.writeDebugSprite(d.time, int(d.player), d.packet)
    of evLobby:
      w.writeLobbyChat(data.shell.lobbyTranscript[ev.idx])
    of evCall:
      w.writePlayCall(data.shell.calls[ev.idx])
    of evLifecycle:
      w.writeLifecycle(data.shell.lifecycle[ev.idx])
    of evBallot:
      w.flushReplayWriter() # writeBallot is raw -- pin its stream position
      w.writeBallot(ballots[ev.idx])
  w.flushReplayWriter()
  for a in data.shell.annotations:
    w.writeAnnotation(a)
  for h in rep.hashes:
    w.writeHash(h.tick, h.hash)
  w.closeReplayWriter()
  echo "wrote ", paramStr(2)

  # Round-trip proof through the real parser.
  let check = parseCtfReplayBytesFull(readFile(paramStr(2)))
  echo "roundtrip ballots=", check.shell.ballots.len,
    " transcript=", check.shell.lobbyTranscript.len,
    " calls=", check.shell.calls.len,
    " inputs=", check.replay.inputs.len,
    " hashes=", check.replay.hashes.len,
    " manifestVerified=", check.shell.manifestVerified
