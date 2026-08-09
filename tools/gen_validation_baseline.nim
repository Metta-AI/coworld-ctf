## Regenerates tests/fixtures/map-validation-baseline.tsv — the 402-row pin on
## what `validateGeneratedMap` says about the generator's RAW first draw
## (`generateMapAttempt`, attempt 0) for seeds 1000..1200 at 2 and 4 teams.
##
## The fixture is a REGRESSION pin, not a quality claim: it exists so a change
## to the validators or to the draw order shows up as a per-seed diff with a
## reason string instead of as a silent shift in what the generator serves. It
## had no regenerator until the best-of-K work re-dealt every seed, which meant
## the only way to move it was by hand.
##
## Usage: nim c -d:release -r tools/gen_validation_baseline.nim [lo] [hi]
## Writes the fixture in place and prints the first-attempt pass rate per team
## count — the number that says whether the validators filter anything at all.
## `tests/test_map_editor_core.nim` also pins the row COUNT (402) and that both
## endzone archetypes and both 4-team layouts appear, so keep the seed span.
import std/[os, osproc, strformat, strutils], ../src/ctf/sim

const
  RepoDir = currentSourcePath().parentDir().parentDir()
  OutPath = RepoDir / "tests" / "fixtures" / "map-validation-baseline.tsv"

func shortName(endzone: EndzoneShape): string =
  ## "ezColumn" -> "column": the fixture spells the archetypes the way the
  ## `mapEndzone` config knob does, not the way the enum does.
  ($endzone)[2 .. ^1].toLowerAscii

func shortName(layout: TeamLayout): string =
  ($layout)[6 .. ^1].toLowerAscii

when isMainModule:
  let
    lo = if paramCount() >= 1: paramStr(1).parseInt else: 1000
    hi = if paramCount() >= 2: paramStr(2).parseInt else: 1200
    overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
  var
    lines = @["teams\tseed\tendzone\tlayout\treason"]
    passed, total: array[2, int]
  for teams in [2, 4]:
    let slot = if teams == 2: 0 else: 1
    for seed in lo .. hi:
      let
        gameMap = generateMapAttempt(seed, overrides, teams)
        reason = validateGeneratedMap(gameMap)
      inc total[slot]
      if reason.len == 0: inc passed[slot]
      lines.add &"{teams}\t{seed}\t{gameMap.endzone.shortName}\t" &
        &"{gameMap.layout.shortName}\t{reason}"
  var sha = "unknown"
  let (revision, code) =
    execCmdEx("git -C " & quoteShell(RepoDir) & " rev-parse HEAD")
  if code == 0: sha = revision.strip()
  writeFile(
    OutPath,
    "# validateGeneratedMap baseline from " & sha & "\n" &
      lines.join("\n") & "\n")
  echo &"wrote {OutPath} ({lines.len - 1} rows)"
  for teams in [2, 4]:
    let slot = if teams == 2: 0 else: 1
    echo &"  {teams} teams: first-attempt pass {passed[slot]}/{total[slot]} " &
      &"({100.0 * float(passed[slot]) / float(total[slot]):.1f}%)"
