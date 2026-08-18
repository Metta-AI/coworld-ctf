## ⭐ SEAT-CONTRACT DUMP (2026-08-14, one-door break).
##
## Seat->role assignment is a SILENT contract: a wrong deal produces no error,
## it produces bots that stand still or roles that never exist. This prints the
## FULL deal for every board shape the league can hand us, for both the shipped
## table and its NODOOR1=1 revert, so "no role dropped or doubled" is a checked
## fact rather than a claim.
##
##   nim c -d:release -d:ctfEvalHarness --hints:off \
##     -o:players/baseline/eval/seatdump.out players/baseline/eval/seatdump.nim
##   players/baseline/eval/seatdump.out
##
## Reads roleForSeat and GameTeams directly (GameTeams is the var buildNavGrid
## sets from the stated team count), so it measures the real production path.

import std/[os, random, strutils, strformat, tables]
import ./harness_engine

include "../baseline.nim"

const RoleName = ["MidTop", "MidBottom", "MidGuard", "FlankTop", "FlankBottom",
                  "Overwatch", "HomeDefender"]

proc dumpBoard(label: string, teams: int, slots: int, prefix: HSlice[int, int]) =
  GameTeams = teams
  echo &"===== {label}  (GameTeams={teams}, {slots} slots) ====="
  # NOTE: `Team` is Red/Blue only — on a 4-team board it is the slot PARITY
  # (bot.myColor carries the real colour). roleForSeat consumes `team` solely
  # to break the seat-2/3 rusher tie, so both parities is the full space.
  for t in [Team.Red, Team.Blue]:
    var full: seq[string]
    var counts = initCountTable[string]()
    for seat in 0 .. 7:
      let r = RoleName[ord(roleForSeat(seat, t))]
      # ⭐ The ordinal IS the duplicate flag roleSep reads (#1 = a non-primary
      # holder that takes the separated lane/depth). Printing it here makes
      # "which seat is a clone" a checked fact of the same dump that proves the
      # multiset, instead of something re-derived by eye from the role column.
      let ordn = roleOrdinal(seat, t)
      full.add &"{seat}:{r}" & (if ordn > 0: &"#{ordn}" else: "")
      counts.inc r
    echo &"  {t:<7} ALL8    " & full.join("  ")
    # The seats we ACTUALLY hold in this mode.
    var held: seq[string]
    var heldRoles: seq[string]
    for seat in prefix:
      let r = RoleName[ord(roleForSeat(seat, t))]
      held.add &"{seat}:{r}"
      heldRoles.add r
    echo &"          HELD    " & held.join("  ") &
      &"   [FlankTop present: {\"FlankTop\" in heldRoles}]"
    # Multiset check over the full 8-seat deal: nothing added, dropped, doubled
    # relative to the canonical eight.
    var dupes: seq[string]
    for k, v in counts:
      if v > 1: dupes.add &"{k} x{v}"
    var missing: seq[string]
    for r in RoleName:
      if counts.getOrDefault(r) == 0: missing.add r
    echo &"          MULTISET dupes=[{dupes.join(\", \")}] missing=[{missing.join(\", \")}]"

when isMainModule:
  # ⭐ Print the FULL env arm, not just one lever. roleForSeat now reads four
  # independent reverts (NODEF4, NODOOR1, NOSEAT4, NOMIDGUARD8), and a header
  # that names only one of them is how a "both arms identical" claim gets made
  # about two runs that were never in the arms they said they were.
  var arm: seq[string]
  for v in ["NODEF4", "NODOOR1", "NOSEAT4", "NOMIDGUARD8"]:
    if getEnv(v).len > 0: arm.add v & "=1"
  echo (if arm.len == 0: "### SHIPPED (all role-table levers ON)"
        else: "### REVERTED: " & arm.join(" "))
  # 2-team, 16 slots: team = slot mod 2, teamSeat = slot div 2 -> 0..7.
  # In "1v1 (8 per team)" paintbot we hold slots {0,2,4,6} => teamSeats {0,1,2,3}.
  dumpBoard("2-TEAM 16-slot: league strided subset is teamSeats 0..3",
            2, 16, 0 .. 3)
  # 4-team, 16 slots: teamSeat = slot div 4 -> 0..3 for EVERY entrant.
  dumpBoard("4-TEAM 16-slot: every entrant holds teamSeats 0..3",
            4, 16, 0 .. 3)
  # 4ffa8, 32 slots: teamSeat = slot div 4 -> 0..7, all eight.
  dumpBoard("4-TEAM 32-slot (4ffa8): teamSeats 0..7", 4, 32, 0 .. 7)
