"""Summarize raw logs without removing cold ticks or slow samples."""
import json
import math
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
rows = []
for directory in sorted(root.glob('game-r*-b*-s*')):
    log = (directory / 'server.log').read_text()
    frames = [int(v)/1e6 for v in re.findall(r'^BUDGET_FRAME tick=\d+ ns=(\d+)$', log, re.M)]
    shell = re.findall(r'^BUDGET_SHELL tick=(\d+) ns=(\d+) pending=(\d+) no_path=(\d+) stale=(\d+)$', log, re.M)
    def stats(values):
        ordered = sorted(values)
        if not ordered:
            return None
        return dict(n=len(ordered), p50_ms=ordered[math.ceil(.5*len(ordered))-1],
                    p95_ms=ordered[math.ceil(.95*len(ordered))-1], max_ms=max(ordered),
                    over_24hz=sum(v > 1000/24 for v in ordered))
    r, b, s = map(int, re.fullmatch(r'game-r(\d+)-b(\d+)-s(\d+)', directory.name).groups())
    census = [int(v) for v in re.findall(r'^SHELL_MOVEMENT tick=\d+ seats=(\d+)', log, re.M)]
    frame_ticks = {int(t) for t in re.findall(r'^BUDGET_FRAME tick=(\d+)', log, re.M)}
    shell_ticks = {int(x[0]) for x in shell}
    row = dict(repeat=r, budget=b, seats=s, frames=stats(frames),
               observed_seats=sorted(set(census)),
               ready_module_seats=sorted({int(v) for v in re.findall(r'^SHELL_PLAY_COMMIT seat=(\d+).*terminal=tkReady', log, re.M)}),
               guest_init_seats=sorted({int(v) for v in re.findall(r'^SHELL_PLAY_LOG tick=\d+ seat=(\d+) entry=edge_ride phase=init', log, re.M)}),
               shell_only_ticks=sorted(shell_ticks-frame_ticks),
               frame_only_ticks=sorted(frame_ticks-shell_ticks),
               shell=stats([int(x[1])/1e6 for x in shell]),
               shell_first_tick=int(shell[0][0]) if shell else None,
               shell_last_tick=int(shell[-1][0]) if shell else None,
               pending_seat_ticks=sum(int(x[2]) for x in shell),
               no_path_seat_ticks=sum(int(x[3]) for x in shell),
               stale_seat_ticks=sum(int(x[4]) for x in shell),
               plan_events={outcome:len(re.findall(r'^SHELL_PLAN_BUDGET .*outcome='+outcome+r'$',log,re.M))
                            for outcome in ('completed','failed','suspended')},
               installs=len(re.findall(r'^SHELL_INSTALL ', log, re.M)),
               play_fault_lines=len(re.findall(r'^.*kind=play_fault.*$',log,re.M)),
               failure=json.loads((directory/'failure.json').read_text()) if (directory/'failure.json').exists() else None,
               exit=json.loads((directory/'exit.json').read_text()) if (directory/'exit.json').exists() else None)
    rows.append(row)
print(json.dumps(rows, indent=2))
