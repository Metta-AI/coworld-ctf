"""Evaluate the preregistered H1 screen without dropping frames or failed runs."""
from pathlib import Path
import hashlib
import json
import math
import re
import statistics
import sys

root = Path(sys.argv[1])
rows = []
streams = {}
for variant, budgets in [('parent',(256,512)), ('candidate',(512,))]:
    for budget in budgets:
        for repeat in (1,2,3):
            directory = root/variant/f'game-r{repeat}-b{budget}-s32'
            row = dict(variant=variant,budget=budget,repeat=repeat)
            if (directory/'failure.json').exists():
                row['failure'] = json.loads((directory/'failure.json').read_text())
                rows.append(row)
                continue
            row['exit'] = json.loads((directory/'exit.json').read_text())
            log = (directory/'server.log').read_text()
            frames = [(int(t),int(ns)) for t,ns in re.findall(r'^BUDGET_FRAME tick=(\d+) ns=(\d+)$',log,re.M)]
            values = sorted(ns for _,ns in frames)
            assert len(values)==1200 and len({t for t,_ in frames})==1200,directory
            assert row['exit']['code']==0,directory
            census = {int(s) for s in re.findall(r'^SHELL_MOVEMENT tick=\d+ seats=(\d+)',log,re.M)}
            assert census=={32},(directory,census)
            guests = {int(s) for s in re.findall(r'^SHELL_PLAY_LOG tick=\d+ seat=(\d+) entry=edge_ride phase=init',log,re.M)}
            assert guests==set(range(32)),(directory,guests)
            row.update(total_ns=sum(values),p50_ns=values[599],p95_ns=values[math.ceil(.95*len(values))-1],max_ns=values[-1],deadline_misses=sum(v*24>1_000_000_000 for v in values))
            shell = re.findall(r'^BUDGET_SHELL tick=\d+ ns=\d+ pending=(\d+) no_path=(\d+) stale=(\d+)$',log,re.M)
            assert len(shell)==1200,directory
            row.update(pending_seat_ticks=sum(int(x[0]) for x in shell),no_path_seat_ticks=sum(int(x[1]) for x in shell),stale_seat_ticks=sum(int(x[2]) for x in shell),play_faults=log.count('kind=play_fault'))
            stage_rows=[dict((k,int(v)) for k,v in re.findall(r"(\w+)=(\d+)",line)) for line in log.splitlines() if line.startswith('SHELL_TIMING ')]
            row['stage_window_ticks']=sum(s['window_ticks'] for s in stage_rows)
            row['stage_totals_us']={key:sum(s.get(key,0) for s in stage_rows) for key in stage_rows[0] if key.endswith('_us') and key!='max_tick_us'} if stage_rows else {}
            semantic='\n'.join(l for l in log.splitlines() if l.startswith(('SHELL_PLAN_BUDGET ','SHELL_NAV ','SHELL_INSTALL ','SHELL_MOVEMENT ')))
            streams[(variant,budget,repeat)]=semantic
            row['semantic_sha256']=hashlib.sha256(semantic.encode()).hexdigest()
            rows.append(row)

result=dict(rows=rows)
if any('failure' in row for row in rows):
    result['decision']='FAILED RUN: not accepted'
else:
    paired={}
    for budget in (256,512):
        ratios={key:[] for key in ('total_ns','p50_ns','p95_ns','max_ns')}
        parents=[];candidates=[]
        for repeat in (1,2,3):
            parent=next(r for r in rows if r['variant']=='parent' and r['budget']==budget and r['repeat']==repeat)
            candidate=next(r for r in rows if r['variant']=='candidate' and r['repeat']==repeat)
            parents.append(parent);candidates.append(candidate)
            for key in ratios:ratios[key].append(candidate[key]/parent[key])
        paired[budget]=dict(ratios=ratios,median_ratios={k:statistics.median(v) for k,v in ratios.items()},parent_worst_misses=max(r['deadline_misses'] for r in parents),candidate_worst_misses=max(r['deadline_misses'] for r in candidates))
    exact=all(streams[('parent',512,r)]==streams[('candidate',512,r)] for r in (1,2,3))
    repeat_exact=all(streams[(variant,budget,r)]==streams[(variant,budget,1)] for variant,budgets in [('parent',(256,512)),('candidate',(512,))] for budget in budgets for r in (2,3))
    result.update(paired=paired,semantic_exact=exact,repeat_semantic_exact=repeat_exact)
    for budget,threshold,name in ((512,.98,'intermediate_screen_pass'),(256,1.0,'training_scenario_512_target')):
        p=paired[budget];m=p['median_ratios']
        result[name]=exact and repeat_exact and all(r['play_faults']==0 for r in rows) and m['total_ns']<=threshold and all(m[k]<=1.0 for k in ('p50_ns','p95_ns','max_ns')) and p['candidate_worst_misses']<=p['parent_worst_misses']
    result['qualification']='Training scenario only; no full-game shipping qualification claim.'
print(json.dumps(result,indent=2))
