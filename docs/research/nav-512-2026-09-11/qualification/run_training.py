"""Current-main six-game confirmation registered in current-main/CARD.md."""
import hashlib
import json
from pathlib import Path
import statistics
from run_case import run
from metrics import inspect

results=Path('/qualification-results')
root=Path('/workspace/ctf/docs/research/nav-512-2026-09-11')
for path,digest in json.loads((results/'assets.json').read_text()).items():
    if hashlib.sha256(Path(path).read_bytes()).hexdigest()!=digest: raise RuntimeError(f'asset changed: {path}')
passed=json.loads((results/'correctness-passed.json').read_text())
manifest=json.loads((root/'qualification/proposed-configs/manifest.json').read_text())
assert [r['case'] for r in passed]==[c['name'] for c in manifest]
config=root/'current-main/training-config.json'
assert hashlib.sha256(config.read_bytes()).hexdigest()==(root/'current-main/training-config.sha256').read_text().split()[0]
rows=[]
for repeat in range(1,4):
    order=[('parent',256),('candidate',512)]
    if repeat==2:order.reverse()
    for variant,budget in order:
        directory=results/'training'/f'{variant}-b{budget}-r{repeat}'
        if directory.exists():raise RuntimeError(f'refusing to overwrite: {directory}')
        print(f'START training {variant} {budget} repeat={repeat}',flush=True)
        server=Path('/original/server-256') if variant=='parent' else Path('/candidate/server-512')
        try:
            run(config,server,Path('/original/presence'),directory,{5})
            rows.append(dict(variant=variant,budget=budget,repeat=repeat,**inspect(directory,dict(seats=32,play='edge_ride'))))
            (results/'training-rows.json').write_text(json.dumps(rows,indent=2)+'\n')
        except Exception as error:
            if directory.exists():(directory/'failure.json').write_text(json.dumps(dict(type=type(error).__name__,error=str(error)))+'\n')
            raise
pairs=[]
for repeat in range(1,4):
    parent=next(r for r in rows if r['variant']=='parent' and r['repeat']==repeat)
    candidate=next(r for r in rows if r['variant']=='candidate' and r['repeat']==repeat)
    pairs.append({k:candidate[k]/parent[k] for k in ('total_ns','p50_ns','p95_ns','max_ns')})
medians={k:statistics.median(p[k] for p in pairs) for k in pairs[0]}
worst={v:max(r['deadline_misses'] for r in rows if r['variant']==v) for v in ['parent','candidate']}
exact=all(len({r['semantic_sha256'] for r in rows if r['variant']==v})==1 for v in ['parent','candidate'])
verdict=dict(ratios=pairs,median_ratios=medians,worst_misses=worst,repeat_exact=exact,
             passed=exact and all(v<=1 for v in medians.values()) and worst['candidate']<=worst['parent'])
(results/'training-verdict.json').write_text(json.dumps(verdict,indent=2)+'\n')
print(json.dumps(verdict,indent=2))
