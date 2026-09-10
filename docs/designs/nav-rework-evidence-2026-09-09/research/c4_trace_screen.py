"""Count exact ordered-pixel source-tuple reuse; no production changes or timing."""
import json
from collections import OrderedDict
from pathlib import Path
root = Path(__file__).resolve().parent
rows = []
for trace in sorted((root / 'C2-local/traces').glob('*.navsrc.txt')):
    headers, keys = {}, []
    for line in trace.read_text().splitlines():
        if not line.startswith(('NAVSRC sys ', 'NAVSRC sched ')):
            continue
        fields = dict(token.split('=', 1) for token in line.split() if '=' in token)
        if line.startswith('NAVSRC sys '):
            headers = fields
        elif fields['changed'] == '1':
            key = tuple(tuple(map(int, point.split(':')[:2])) for point in fields.get('pts', '').split(',') if point)
            assert len(key) == int(fields['n'])
            keys.append(key)
    for capacity in [1, 4, 8, 16]:
        cache = OrderedDict()
        hits = empty = 0
        for key in keys:
            if not key:
                empty += 1
                continue
            if key in cache:
                hits += 1
                cache.move_to_end(key)
            else:
                cache[key] = None
                if len(cache) > capacity:
                    cache.popitem(last=False)
        nonempty = len(keys) - empty
        rows.append({'trace': trace.name, 'map': headers['map'], 'seats': int(headers['seats']),
                     'capacity': capacity, 'rebuilds': len(keys), 'empty': empty,
                     'nonempty_hits': hits, 'nonempty_hit_rate': hits / nonempty if nonempty else None})
print(json.dumps(rows, indent=2))
