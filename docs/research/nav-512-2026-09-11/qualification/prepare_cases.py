"""Prepare proposed held-out configs; freeze their hashes before timed qualification."""
from pathlib import Path
import copy
import hashlib
import json

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
cases = [
    ('map505-s16-edge-r331', 'docs/research/nav-512-2026-09-11/qualification-maps/pool-505.json', 16, 331, False),
    ('map5001-s32-edge-r1050', 'docs/research/nav-512-2026-09-11/qualification-maps/pool-5001.json', 32, 1050, False),
    ('scale29-s32-edge-r497', 'docs/research/nav-512-2026-09-11/qualification-maps/map-scale29.json', 32, 497, False),
    ('map505-s32-moving-r497', 'docs/research/nav-512-2026-09-11/qualification-maps/pool-505.json', 32, 497, True),
    ('map5001-s16-moving-r331', 'docs/research/nav-512-2026-09-11/qualification-maps/pool-5001.json', 16, 331, True),
    ('scale29-s32-moving-r1050', 'docs/research/nav-512-2026-09-11/qualification-maps/map-scale29.json', 32, 1050, True),
]
base = json.loads((ROOT/'config.practice.json').read_text())
for key, value in json.loads((ROOT/'tests/fixtures/shell/shell_demo_config.json').read_text()).items():
    if value is None:
        base.pop(key, None)
    else:
        base[key] = value
output = HERE/'proposed-configs'
output.mkdir(exist_ok=True)
manifest = []
for name, map_path, seats, gun_range, moving in cases:
    config = copy.deepcopy(base)
    config.update(seed=907, maxGames=1, maxTicks=1200, playSeatBindTicks=120,
                  fastMode=True, speed=1, barrageMaxPerSec=0, gunRange=gun_range,
                  mapPath='arena', mapSpec=json.loads((ROOT/map_path).read_text()), minPlayers=seats)
    for key in ('players', 'slots', 'tokens'):
        config[key] = config[key][:seats]
    config['demoPlay']['seats'] = list(range(seats))
    if moving:
        config['hitPoints'] = 1000
        config['demoPlay'].update(
            modulePath='docs/research/nav-512-2026-09-11/qualification/.build/nav_research_moving.wasm',
            playName='nav_research_moving', params={})
    path = output/f'{name}.json'
    path.write_text(json.dumps(config, indent=2)+'\n')
    manifest.append(dict(name=name, config=path.name, seats=seats, gun_range=gun_range,
                         play=config['demoPlay']['playName'], hit_points=config['hitPoints'],
                         map_name=config['mapSpec']['name'],
                         sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
(output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
