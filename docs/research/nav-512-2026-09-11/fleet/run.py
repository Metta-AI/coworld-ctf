"""Execute fleet/CARD.md using the frozen current-main m5a references."""
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

ROOT=Path('/workspace/ctf')
HERE=ROOT/'docs/research/nav-512-2026-09-11'
sys.path.insert(0,str(HERE/'qualification'))
from run_case import run
from metrics import inspect

family=sys.argv[1]
if family not in ['c6a.4xlarge','c8i-flex.4xlarge']:raise ValueError(family)
reference=Path('/reference')
if not json.loads((reference/'performance-verdict.json').read_text())['passed']:
    raise RuntimeError('m5a qualification did not pass')
assets=json.loads((reference/'assets.json').read_text())
for path,digest in assets.items():
    if hashlib.sha256(Path(path).read_bytes()).hexdigest()!=digest:raise RuntimeError(f'changed asset: {path}')
provenance=json.loads((Path('/fleet-results')/f'{family}-instance.json').read_text())
if provenance['id']!='i-08b7fb62b50e0740a' or provenance['type']!=family or provenance['state']!='running':raise RuntimeError('wrong instance provenance')
if provenance['image_id']!=(reference/'image-id.txt').read_text().strip():raise RuntimeError('changed Docker image')
results=Path('/fleet-results')/family
results.mkdir(exist_ok=False)
manifest=json.loads((HERE/'qualification/proposed-configs/manifest.json').read_text())
selected=[next(c for c in manifest if c['name']==name) for name in ['map5001-s32-edge-r1050','scale29-s32-moving-r1050']]
for case in selected:
    path=HERE/'qualification/proposed-configs'/case['config']
    if hashlib.sha256(path.read_bytes()).hexdigest()!=case['sha256']:raise RuntimeError(f'changed config: {path}')
reference_rows=json.loads((reference/'performance-rows.json').read_text())
refs={}
for case in selected:
    for variant in ['parent','candidate']:
        values={r['semantic_sha256'] for r in reference_rows if r['case']==case['name'] and r['variant']==variant}
        if len(values)!=1:raise RuntimeError('invalid m5a semantic reference')
        refs[(case['name'],variant)]=values.pop()
host=dict(instance=provenance,libc=subprocess.check_output(['getconf','GNU_LIBC_VERSION'],text=True).strip(),clock_ticks_per_second=os.sysconf('SC_CLK_TCK'),kernel=platform.uname()._asdict(),affinity=sorted(os.sched_getaffinity(0)),
          lscpu=subprocess.check_output(['lscpu','-J'],text=True),
          topology=subprocess.check_output(['lscpu','-e=CPU,CORE,SOCKET,NODE'],text=True),
          siblings={p.parent.parent.name:p.read_text().strip() for p in Path('/sys/devices/system/cpu').glob('cpu[0-9]*/topology/thread_siblings_list')},
          assets=assets)
(results/'host.json').write_text(json.dumps(host,indent=2)+'\n')

def cpu_snapshot():
    return dict(monotonic_ns=time.monotonic_ns(),utc_ns=time.time_ns(),
                counters={line.split()[0]:list(map(int,line.split()[1:])) for line in Path('/proc/stat').read_text().splitlines() if line.startswith('cpu')})

cells=[(case,mode) for mode in ['pinned','unpinned'] for case in selected]
rows=[]
for repeat in range(1,4):
    for index,(case,mode) in enumerate(cells):
        order=[('parent',256),('candidate',512)]
        if (index+repeat-1)%2:order.reverse()
        for variant,budget in order:
            directory=results/f'{case["name"]}-{mode}'/f'{variant}-b{budget}-r{repeat}'
            if directory.exists():raise RuntimeError(f'refusing to overwrite: {directory}')
            before=cpu_snapshot()
            print(f'START {family} {case["name"]} {mode} {variant} repeat={repeat}',flush=True)
            try:
                server=Path('/original/server-256') if variant=='parent' else Path('/candidate/server-512')
                run(HERE/'qualification/proposed-configs'/case['config'],server,Path('/original/presence'),directory,{5} if mode=='pinned' else None)
                metrics=inspect(directory,case)
                row=dict(case=case['name'],mode=mode,variant=variant,budget=budget,repeat=repeat,**metrics)
                rows.append(row)
                (results/'rows.json').write_text(json.dumps(rows,indent=2)+'\n')
            except Exception as error:
                if directory.exists():(directory/'failure.json').write_text(json.dumps(dict(type=type(error).__name__,error=str(error)))+'\n')
                raise
            finally:
                if directory.exists():(directory/'cpu-lifecycle.json').write_text(json.dumps(dict(before=before,after=cpu_snapshot()),indent=2)+'\n')
            if metrics['semantic_sha256']!=refs[(case['name'],variant)]:
                (directory/'mismatch.json').write_text(json.dumps(dict(case=case['name'],mode=mode,
                    variant=variant,budget=budget,repeat=repeat,actual=metrics['semantic_sha256'],
                    expected=refs[(case['name'],variant)]),indent=2)+'\n')
                raise RuntimeError('cross-family semantic mismatch; completed game retained, acceptance stopped')
verdicts=[]
for case,mode in cells:
    cell_rows=[r for r in rows if r['case']==case['name'] and r['mode']==mode]
    pairs=[]
    for repeat in range(1,4):
        parent=next(r for r in cell_rows if r['variant']=='parent' and r['repeat']==repeat)
        candidate=next(r for r in cell_rows if r['variant']=='candidate' and r['repeat']==repeat)
        pairs.append({k:candidate[k]/parent[k] for k in ['total_ns','p50_ns','p95_ns','max_ns']})
    medians={k:statistics.median(p[k] for p in pairs) for k in pairs[0]}
    worst={v:max(r['deadline_misses'] for r in cell_rows if r['variant']==v) for v in ['parent','candidate']}
    exact=all(len({r['semantic_sha256'] for r in cell_rows if r['variant']==v})==1 for v in ['parent','candidate'])
    verdicts.append(dict(case=case['name'],mode=mode,ratios=pairs,median_ratios=medians,worst_misses=worst,repeat_exact=exact,
                         passed=exact and all(v<=1 for v in medians.values()) and worst['candidate']<=worst['parent']))
(results/'verdict.json').write_text(json.dumps(dict(family=family,cells=verdicts,passed=all(v['passed'] for v in verdicts)),indent=2)+'\n')
