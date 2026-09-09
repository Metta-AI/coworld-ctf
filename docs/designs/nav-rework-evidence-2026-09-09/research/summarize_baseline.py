"""Validate the registered B0 matrix and write its complete timing scoreboard."""
import hashlib
import json
import math
from pathlib import Path

root = Path(__file__).parent
rows = []
for budget in (1024, 2048, 3072, 4096):
    for repeat in (1, 2, 3):
        path = root / 'B0' / f'b{budget}-r{repeat}.json'
        result = json.loads(path.read_text())
        data = result['tick']['maps']
        expected = {(s, c) for s in (16, 32) for c in ('first_goals', 'moving_goals', 'stuck_replans')}
        assert {(r['roster_size'], r['scenario']) for r in data} == expected
        assert len(data) == 6
        for row in data:
            samples = row['samples_ns']
            assert len(samples) == row['sample_count'] == 120
            assert sorted(samples)[math.ceil(0.95 * len(samples)) - 1] == row['p95_ns']
            assert max(samples) == row['max_ns']
            assert max(row['pops_per_tick']) <= budget
            rows.append(dict(budget=budget, repeat=repeat, seats=row['roster_size'],
                             scenario=row['scenario'], p95_ms=row['p95_ns']/1e6,
                             max_ms=row['max_ns']/1e6,
                             request_p95_us=row['request_overhead_p95_ns']/1000,
                             total_pops=sum(row['pops_per_tick']),
                             search_ns_per_pop=sum(row['route_search_samples_ns'])/sum(row['pops_per_tick'])))
summary = []
for budget in (1024, 2048, 3072, 4096):
    matching = [r for r in rows if r['budget'] == budget]
    p95 = max(r['p95_ms'] for r in matching)
    maximum = max(r['max_ms'] for r in matching)
    summary.append(dict(budget=budget, worst_p95_ms=p95, worst_max_ms=maximum,
                        headroom_pass=p95 <= 3.6 and maximum <= 4.5,
                        normal_tick_pass=p95 <= 4 and maximum <= 5))
(root / 'B0_SUMMARY.json').write_text(json.dumps(dict(rows=rows, budgets=summary), indent=2)+'\n')
lines = ['# B0: corrected inherited Xeon baseline', '',
         'Source `20234cc7`; m6i.8xlarge Xeon 8375C; CPU5 pin; three fresh processes per budget,',
         'six sequential scenarios per process, 120 measured ticks per scenario after five warmups.',
         'All registered pinned runs are included. The existing live tournament remained running.', '',
         '| Pops/tick | Worst p95 ms | Worst max ms | 3.6/4.5 headroom | 4/5 tick gate |',
         '|---:|---:|---:|:---:|:---:|']
for row in summary:
    lines.append(f"| {row['budget']} | {row['worst_p95_ms']:.6f} | {row['worst_max_ms']:.6f} | {'PASS' if row['headroom_pass'] else 'FAIL'} | {'PASS' if row['normal_tick_pass'] else 'FAIL'} |")
lines += ['', 'Largest tested headroom-passing budget: **1,024**. Largest tested 4/5-passing budget: **2,048**.',
          'These are different decisions. Neither is a complete production qualification or a proof of maximum capacity.',
          'B0 uses the existing breakdown clocks and one map; first_goals resets life every tick.',
          'Completion latency, instrumentation-off checks, current production instance types, full quality,',
          'memory/determinism and remaining Phase 10/11 gates remain outstanding.', '',
          'Raw rows and weighted search ns/pop are in B0_SUMMARY.json; unpinned burst files remain informational.',
          'No confidence interval or stable speedup claim is inferred from only three processes.']
(root / 'B0_REPORT.md').write_text('\n'.join(lines)+'\n')
paths = sorted((root / 'B0').glob('*'))
(root / 'B0_SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  B0/{p.name}\n' for p in paths if p.is_file()))
print(json.dumps(summary, indent=2))
