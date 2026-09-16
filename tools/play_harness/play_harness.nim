## Native CLI for running shell play modules through the production pipeline.

import std/[os, strutils]

import ../../src/shell/play_harness_core

proc usage() =
  quit("usage: play_harness <case.json>", 1)

when isMainModule:
  let args = commandLineParams()
  if args.len != 1 or args[0] in ["-h", "--help"]:
    usage()
  try:
    stdout.write(runHarnessFile(args[0]).strip)
    stdout.write("\n")
  except CatchableError as error:
    stderr.writeLine("play_harness: " & error.msg)
    quit(1)
