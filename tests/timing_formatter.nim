## Per-test wall-clock timing, as an opt-in `unittest` output formatter.
##
## The suite is slow enough that "which tests cost the time" is a question we
## have had to answer more than once, and answering it by guessing has been
## wrong before: the standing diagnosis for the ~50 minute run was best-of-K
## generation on pool sweeps, and a full 20-map pool sweep measures 23 s — so
## the three sweeps in the suite could not have been more than a minute of it.
##
## Import this module BEFORE the tests you want timed (module init registers
## the formatter, and `unittest` runs each test at import time), then read the
## table it prints at exit. `tests/timed_shard.nim` does exactly that.
##
## Off by default and imported by nothing in the shards, so it costs the CI
## run nothing.

import
  std/[algorithm, exitprocs, monotimes, strformat, strutils, times, unittest]

type
  TimingFormatter = ref object of OutputFormatter
    ## Records the wall time of every test, keyed by "suite / test".
    started: MonoTime
    suite: string
    timings: seq[(float, string)]

var timing = TimingFormatter(timings: @[])

method suiteStarted(formatter: TimingFormatter, suiteName: string) =
  formatter.suite = suiteName

method testStarted(formatter: TimingFormatter, testName: string) =
  formatter.started = getMonoTime()

method testEnded(formatter: TimingFormatter, testResult: TestResult) =
  let ms = (getMonoTime() - formatter.started).inMilliseconds.float
  formatter.timings.add (ms, formatter.suite & " / " & testResult.testName)

proc report() =
  ## Slowest tests first, with the share of total each one carries. Printed to
  ## stderr so it survives a caller that greps stdout for test failures.
  var timings = timing.timings
  timings.sort(Descending)
  var total = 0.0
  for (ms, _) in timings:
    total += ms
  stderr.writeLine ""
  stderr.writeLine "=== per-test timing: " & $timings.len & " tests, " &
    &"{total/1000:.1f} s total ==="
  var cumulative = 0.0
  for i, (ms, name) in timings:
    if ms < 100 and i > 40:
      ## The tail is thousands of sub-100ms tests; the question is always
      ## which ones are big, so stop once both are true.
      stderr.writeLine &"  ... {timings.len - i} more under 100 ms"
      break
    cumulative += ms
    stderr.writeLine &"{ms/1000:>8.1f}s  {cumulative/total*100:>5.1f}%  " &
      name.strip()

addOutputFormatter(timing)
addExitProc(report)
