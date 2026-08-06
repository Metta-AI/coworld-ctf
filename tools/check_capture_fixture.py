#!/usr/bin/env python3
"""Does a candidate recording qualify as the CAPTURE fixture?

`tests/test_broadcast_state.nim` states the recipe's two conditions in prose;
this checks them mechanically so a re-record is not eyeballed:

  1. the episode ENDS ON A CAPTURE (not a wipe, not a time-limit draw), and
  2. only ONE flag is out from the last steal to that capture.

Condition 2 is the subtle one and it is not cosmetic. `test_replay_scan`'s
endzone fade ramp watches this fixture just past the last steal, and its
per-frame band allowance (EndzoneRampBandsPerFrame + 1) assumes a SINGLE
powered-down endzone. A double-steal ending ships both teams' bands in the
same frame and busts the bound — which is exactly how the GV40 re-record of
seed 1 failed: blue stole at 2584, red at 2688, and both stayed out until
blue captured at 3582, giving 9 new bands in a frame against an allowance
of 5.

Reads `tools/expand_replay` output on stdin. Exits 0 if the recording
qualifies, 1 if it does not, and says which condition failed.
"""
import re
import sys

tick = 0
out = {}          # team -> tick it was stolen on
last_steal = None  # (tick, team whose flag was taken)
capture = None     # (tick, team whose flag was captured)
double = []        # windows where two flags were out at once

for line in sys.stdin:
    line = line.rstrip()
    m = re.match(r"^tick (\d+)", line)
    if m:
        tick = int(m.group(1))
        continue
    m = re.search(r"stole the (\w+) flag", line)
    if m:
        out[m.group(1)] = tick
        last_steal = (tick, m.group(1))
        if len(out) > 1:
            double.append((tick, sorted(out)))
        continue
    m = re.search(r"^\s*(\w+) flag returned home", line)
    if m:
        out.pop(m.group(1), None)
        continue
    m = re.search(r"captured the (\w+) flag", line)
    if m:
        capture = (tick, m.group(1))
        # The capture returns the captured flag; anything still out is a
        # SECOND carry running alongside it.
        out.pop(m.group(1), None)
        continue

if capture is None:
    print("REJECT: episode does not end on a capture")
    sys.exit(1)

if last_steal is None:
    print("REJECT: capture with no recorded steal")
    sys.exit(1)

# Was a second flag out at any point in [last steal, capture]?
tail_double = [d for d in double if d[0] >= last_steal[0]]
still_out = sorted(out)
if tail_double or still_out:
    print(
        f"REJECT: double steal in the tail — capture of {capture[1]} "
        f"at tick {capture[0]}, last steal of {last_steal[1]} at "
        f"{last_steal[0]}; also out: {tail_double or still_out}"
    )
    sys.exit(1)

print(
    f"ACCEPT: {capture[1]} flag captured at tick {capture[0]}; "
    f"last steal was of {last_steal[1]} at tick {last_steal[0]}, "
    f"and it stood alone"
)
sys.exit(0)
