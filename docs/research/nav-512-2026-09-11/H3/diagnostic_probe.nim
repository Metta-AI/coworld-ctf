## Run with --stackTrace:on. The bad index must still raise, and its caller
## must remain visible even though H3 omits the tiny helper's own frame.
import std/strutils
include ../../../../src/shell/body_planner

proc diagnosticCaller() {.noinline.} =
  var heap: FixedHeap
  heap.positions = newSeq[int](1)
  heap.positionGeneration = newSeq[uint64](1)
  heap.setPosition(2, 0)

try:
  diagnosticCaller()
  quit("ERROR: bounds check did not raise", 1)
except IndexDefect as error:
  let trace = getStackTrace(error)
  doAssert "diagnosticCaller" in trace
  when defined(expectLeafFrame):
    doAssert "setPosition" in trace
  else:
    doAssert "setPosition" notin trace
  echo trace
  echo "BOUNDS CHECK AND CALLER TRACE PRESERVED"
