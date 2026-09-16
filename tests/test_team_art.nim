## Every team's art exists, for every team in the enum.
##
## This test is the replacement for `rig_art.teamArtOrFallback`, the helper
## that used to substitute Red's art for any missing per-team file so a
## widened `Team` could boot before the tint pipeline shipped. That fallback
## made a missing asset SILENT — the wrong-coloured cog is a perfectly
## playable frame, so a renamed or dropped file would have reached a live
## match reading as "this team plays in Red". Deleting it turned that into a
## loud readImage failure; this test moves the failure earlier still, to CI,
## and states the contract in one place: four art families x every Team.
##
## It asserts EXISTENCE, deliberately not content — the rig segment count is
## checked because a half-populated directory is the failure mode a
## bake-time tint pipeline actually produces (it writes files one at a time),
## and that one is invisible to a spot check of the directory listing.

import
  std/[os, strutils, unittest],
  ctf/[rig_art, sim_types]

const RigSegmentsPerTeam = 10
  ## data/rig_real/<team> holds one PNG per RigSeg; every authored team dir
  ## has carried exactly this many since the rig art landed, and the tint
  ## pipeline reproduces the full set per new identity.

suite "team art matrix":

  test "every team has soldier, crown, heart and pedestal masters":
    for team in Team:
      let
        name = teamText(team)
        dir = gameDir()
      for path in [
        "data/soldier_" & name & ".png",
        "data/soldier_" & name & "_crown.png",
        "data/heart_" & name & ".png",
        "data/ped_" & name & ".png"
      ]:
        checkpoint("team " & name & " is missing " & path)
        check fileExists(dir / path)

  test "every team has a complete rig_real segment directory":
    for team in Team:
      let
        name = teamText(team)
        dir = gameDir() / "data/rig_real" / name
      checkpoint("team " & name & " has no rig dir at " & dir)
      check dirExists(dir)
      var segments = 0
      if dirExists(dir):
        for kind, path in walkDir(dir):
          if kind == pcFile and path.endsWith(".png"):
            inc segments
      checkpoint("team " & name & " has " & $segments & " rig segments")
      check segments == RigSegmentsPerTeam

  test "the enum is the full 16-team BR roster":
    ## Guards the matrix above against quietly shrinking: if `Team` were
    ## narrowed back, every loop here would still pass while covering less.
    check ord(Team.high) - ord(Team.low) + 1 == 16
