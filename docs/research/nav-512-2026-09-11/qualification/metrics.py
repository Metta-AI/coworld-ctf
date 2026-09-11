"""Shared full-frame metrics for registered campaigns."""
import hashlib
import json
import re

PREFIXES = ('SHELL_PLAN_BUDGET ', 'SHELL_NAV ', 'SHELL_INSTALL ', 'SHELL_MOVEMENT ')

def inspect(directory, case):
    if (directory/'failure.json').exists():
        raise RuntimeError(f'failed run: {directory}')
    exit_info = json.loads((directory/'exit.json').read_text())
    log = (directory/'server.log').read_text()
    frames = [(int(t),int(ns)) for t,ns in re.findall(r'^BUDGET_FRAME tick=(\d+) ns=(\d+)$',log,re.M)]
    if exit_info['code'] != 0 or len(frames) != 1200 or {t for t,_ in frames} != set(range(1,1201)):
        raise RuntimeError(f'incomplete frame coverage: {directory}')
    guests = {int(s) for s in re.findall(r'^SHELL_PLAY_LOG tick=\d+ seat=(\d+) entry='+re.escape(case['play'])+r' phase=init',log,re.M)}
    census = {int(s) for s in re.findall(r'^SHELL_MOVEMENT tick=\d+ seats=(\d+)',log,re.M)}
    if guests != set(range(case['seats'])) or census != {case['seats']} or 'kind=play_fault' in log:
        raise RuntimeError(f'guest, seat or fault coverage failed: {directory}')
    semantic = '\n'.join(l for l in log.splitlines() if l.startswith(PREFIXES))
    values = sorted(ns for _,ns in frames)
    shell = re.findall(r'^BUDGET_SHELL tick=\d+ ns=\d+ pending=(\d+) no_path=(\d+) stale=(\d+)$',log,re.M)
    if len(shell)!=1200: raise RuntimeError(f'missing shell counters: {directory}')
    result = dict(total_ns=sum(values),p50_ns=values[599],p95_ns=values[1139],max_ns=values[-1],
                  deadline_misses=sum(v*24>1_000_000_000 for v in values),
                  semantic_sha256=hashlib.sha256(semantic.encode()).hexdigest(),
                  pending_seat_ticks=sum(int(x[0]) for x in shell),
                  no_path_seat_ticks=sum(int(x[1]) for x in shell),
                  stale_seat_ticks=sum(int(x[2]) for x in shell),exit=exit_info)
    (directory/'metrics.json').write_text(json.dumps(result,indent=2)+'\n')
    return result
