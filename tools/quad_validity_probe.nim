## T3 closeout probe: quad-mirror 4-team validity over 16 seeds through the
## SHIPPING generateCtfMap (best-of-K), reproducing the brief's "16/16 @007c28e"
## regression gate. Not part of the server; a measurement tool.
##   nim c -d:release -r tools/quad_validity_probe.nim [count] [startSeed]
import std/[os, strformat, strutils], ../src/ctf/sim

when isMainModule:
  let
    count = if paramCount() >= 1: parseInt(paramStr(1)) else: 16
    startSeed = if paramCount() >= 2: parseInt(paramStr(2)) else: 1
  let overrides = MapGenOverrides(
    size: "standard", symmetry: "quadmirror",
    windows: -1, pits: -1, pitDensity: -1)
  var valid = 0
  for i in 0 ..< count:
    let seed = startSeed + i
    var ok = false
    var note = ""
    try:
      let m = generateCtfMap(seed, overrides, teams = 4)
      let reason = validateGeneratedMap(m)
      let diag = mapDiagnostics(m)
      ok = reason.len == 0 and diag.unreachableTeams.len == 0 and diag.centerReachable
      note = &"{m.width}x{m.height} sym={m.symmetry} reason=\"{reason}\" " &
        &"unreach={diag.unreachableTeams.len} centerReach={diag.centerReachable}"
    except CtfError as e:
      note = "RAISED: " & e.msg
    if ok: inc valid
    echo &"seed={seed} {(if ok: \"VALID\" else: \"INVALID\")} {note}"
  echo &"quad-mirror validity: {valid}/{count} ({100.0*float(valid)/float(count):.1f}%)"
