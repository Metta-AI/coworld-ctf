"""Execute the frozen six-cell campaign; never replace or overwrite a run."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
from run_case import run
from metrics import inspect

ROOT = Path('/workspace/ctf')
HERE = ROOT/'docs/research/nav-512-2026-09-11/qualification'
parser=argparse.ArgumentParser()
parser.add_argument('phase',choices=['correctness','performance'])
args=parser.parse_args()
results=Path('/qualification-results')
manifest=json.loads((HERE/'proposed-configs/manifest.json').read_text())
assets=json.loads((results/'assets.json').read_text())
for path,digest in assets.items():
    if hashlib.sha256(Path(path).read_bytes()).hexdigest()!=digest: raise RuntimeError(f'asset changed: {path}')
for case in manifest:
    p=HERE/'proposed-configs'/case['config']
    if hashlib.sha256(p.read_bytes()).hexdigest()!=case['sha256']: raise RuntimeError(f'config changed: {p}')

def execute(case, variant, budget, repeat):
    directory=results/args.phase/case['name']/f'{variant}-b{budget}-r{repeat}'
    if directory.exists(): raise RuntimeError(f'refusing to overwrite: {directory}')
    server=Path('/original/server-256') if variant=='parent' else Path(f'/candidate/server-{budget}')
    print(f'START {args.phase} {case["name"]} {variant} {budget} repeat={repeat}',flush=True)
    try:
        run(HERE/'proposed-configs'/case['config'],server,Path('/original/presence'),directory,{5})
        return inspect(directory,case)
    except Exception as error:
        if directory.exists(): (directory/'failure.json').write_text(json.dumps(dict(type=type(error).__name__,error=str(error)))+'\n')
        raise

rows=[]
if args.phase=='correctness':
    for case in manifest:
        parent=execute(case,'parent',256,1)
        candidate=execute(case,'candidate',256,1)
        if parent['semantic_sha256']!=candidate['semantic_sha256']:
            raise RuntimeError(f'same-budget semantic mismatch: {case["name"]}')
        rows.append(dict(case=case['name'],parent=parent,candidate=candidate))
    (results/'correctness-passed.json').write_text(json.dumps(rows,indent=2)+'\n')
else:
    if not json.loads((results/'training-verdict.json').read_text())['passed']:
        raise RuntimeError('current-main training confirmation did not pass')
    passed=json.loads((results/'correctness-passed.json').read_text())
    if [r['case'] for r in passed]!=[c['name'] for c in manifest]:raise RuntimeError('incomplete correctness campaign')
    for repeat in range(1,4):
        for index,case in enumerate(manifest):
            order=[('parent',256),('candidate',512)]
            if (index+repeat-1)%2:order.reverse()
            for variant,budget in order:
                metrics=execute(case,variant,budget,repeat)
                rows.append(dict(case=case['name'],variant=variant,budget=budget,repeat=repeat,**metrics))
                (results/'performance-rows.json').write_text(json.dumps(rows,indent=2)+'\n')
    decisions=[]
    for case in manifest:
        pairs=[]
        for repeat in range(1,4):
            parent=next(r for r in rows if r['case']==case['name'] and r['variant']=='parent' and r['repeat']==repeat)
            candidate=next(r for r in rows if r['case']==case['name'] and r['variant']=='candidate' and r['repeat']==repeat)
            pairs.append({key:candidate[key]/parent[key] for key in ('total_ns','p50_ns','p95_ns','max_ns')})
        medians={key:statistics.median(p[key] for p in pairs) for key in pairs[0]}
        worst={v:max(r['deadline_misses'] for r in rows if r['case']==case['name'] and r['variant']==v) for v in ['parent','candidate']}
        exact=all(len({r['semantic_sha256'] for r in rows if r['case']==case['name'] and r['variant']==v})==1 for v in ['parent','candidate'])
        decisions.append(dict(case=case['name'],ratios=pairs,median_ratios=medians,worst_misses=worst,
                              repeat_exact=exact,passed=exact and all(v<=1 for v in medians.values()) and worst['candidate']<=worst['parent']))
    (results/'performance-verdict.json').write_text(json.dumps(dict(cases=decisions,passed=all(c['passed'] for c in decisions)),indent=2)+'\n')
