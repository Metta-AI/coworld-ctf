## The tier-2 events artifact format (`events.json`), in ONE place.
##
## Two producers write this exact byte format and the platform ingest reads it:
##
## 1. The LIVE game (`server.nim`), when the runtime hands it a
##    `COGAME_EVENTS_URI`. The sim is already stepping, so collecting events
##    costs nothing extra — no re-simulation, and no chance of the extractor
##    being built from a different engine version than the one that played.
## 2. The RESIM extractor (`tools/extract_events.nim`), which replays a stored
##    `.bitreplay` with the sink on. This is the retroactive path: it covers
##    episodes that were recorded before the live emitter shipped.
##
## Both go through `eventsJsonl` here so a live episode and a resim of that
## same episode produce IDENTICAL bytes. Keeping the serializer in `src/`
## rather than in the tool is what makes that guarantee checkable (see
## tests/test_events_artifact.nim, which asserts live == resim).
##
## Format: JSON lines. One object per event in tick order, then a trailing
## `{"type":"summary",...}` row carrying the tick count, the event count, and
## the `gameVersion` that produced it. The platform parser
## (`coworld_recording.parse_events_artifact`) drops the summary row and
## normalizes the rest, so the summary is the honest self-description of the
## stream rather than data anyone has to join against.

import
  std/[json, strutils],
  sim

const
  CogameEventsUriEnv* = "COGAME_EVENTS_URI"
    ## Where the live game writes its tier-2 events artifact. Set by the
    ## platform dispatcher to a file:// path in the shared episode workdir; the
    ## runner then uploads that file to the presigned per-job EVENTS_URI. Unset
    ## (a live server, a local run) means "do not collect" — the sink stays off
    ## and the game pays nothing. This lives here rather than in bitworld's
    ## RuntimeConfig because the events artifact is currently a CTF-specific
    ## channel; move it there once a second coworld emits one.

  MaxCollectedEvents* = 400_000
    ## Hard ceiling on events held for one episode (~45 MB serialized, under
    ## the platform's 64 MB ingest cap). A normal full match emits a few
    ## hundred, so this is only a runaway guard: past it the game stops
    ## collecting and marks the artifact truncated instead of growing until the
    ## pod is OOM-killed. A truncated stream is recoverable; a dead episode is
    ## not.

proc key*(kind: SimEventKind): string =
  ## Returns the JSON event key for one tier-2 event kind. These strings are
  ## the WIRE CONTRACT read by the platform's channel `eventKind` mapping —
  ## renaming one silently blanks a workbench tab, so they are spelled out
  ## here rather than derived from the enum name.
  case kind
  of Shot: "shot"
  of Hit: "hit"
  of Damage: "damage"
  of Kill: "kill"
  of Death: "death"
  of FlagSteal: "flag_steal"
  of FlagReturn: "flag_return"
  of Capture: "capture"
  of Respawn: "respawn"
  of Heal: "heal"
  of PhaseChange: "phase"

proc jsonRow*(event: SimEvent): JsonNode =
  ## Returns one JSON-lines row for a tier-2 sim event. Every field is always
  ## present (n/a reads as -1 for slots/hp, 0 for amounts, "" for weapon), so
  ## a reader never has to distinguish "absent" from "not applicable".
  result = newJObject()
  result["tick"] = %event.tick
  result["kind"] = %event.kind.key()
  result["source"] = %event.source
  result["target"] = %event.target
  result["weapon"] = %event.weapon
  result["amount"] = %event.amount
  result["hp"] = %event.hp
  result["blocked"] = %event.blocked
  result["x"] = %event.x
  result["y"] = %event.y

proc summaryRow*(ticks, eventCount: int, truncated = false): JsonNode =
  ## Returns the trailing summary row that closes the artifact. `gameVersion`
  ## pins the stream to the rules that produced it: a reader comparing two
  ## episodes can tell whether they are even the same game. `truncated` is
  ## always present — a reader must never have to guess whether a missing flag
  ## means "complete" or "we forgot to say".
  result = newJObject()
  result["type"] = %"summary"
  result["ticks"] = %ticks
  result["events"] = %eventCount
  result["gameVersion"] = %GameVersion
  result["truncated"] = %truncated

proc eventsJsonl*(
  events: openArray[SimEvent], ticks: int, truncated = false
): string =
  ## Serializes a full tier-2 events artifact: one row per event, then the
  ## summary row. Trailing newline, so appending is always line-safe.
  var lines = newSeqOfCap[string](events.len + 1)
  for event in events:
    lines.add($event.jsonRow())
  lines.add($summaryRow(ticks, events.len, truncated))
  lines.join("\n") & "\n"
