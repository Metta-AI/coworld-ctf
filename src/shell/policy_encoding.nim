## Shared canonical encoding for typed play policy fragments.

import std/[algorithm, strutils]

import canonical_fast, types

proc protectedSetEmpty*(value: ProtectedSet): bool {.inline.} =
  value.teams.card == 0 and value.seats.len == 0

proc writeProtectedSet*(w: var CanonicalWriter, value: ProtectedSet) =
  ## Writes the engine-side canonical protected set: resolved plain seat
  ## spellings and team spellings, both sorted and deduplicated by wire text.
  w.beginObject()
  if value.seats.len > 0:
    var seats = newSeqOfCap[string](value.seats.len)
    for seat in value.seats:
      seats.add($seat)
    seats.sort()
    w.key("seats")
    w.beginArray()
    for index, seat in seats:
      if index == 0 or seat != seats[index - 1]:
        w.addString(seat)
    w.endArray()
  if value.teams.card > 0:
    var teams = newSeqOfCap[string](value.teams.card)
    for team in value.teams:
      teams.add(($team).toLowerAscii)
    teams.sort()
    w.key("teams")
    w.beginArray()
    for team in teams:
      w.addString(team)
    w.endArray()
  w.endObject()
