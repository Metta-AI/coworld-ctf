"""Finite real-server screen. Run inside the build image with /results mounted."""
import json
import os
from pathlib import Path
import socket
import subprocess
import time

ROOT = Path('/workspace/ctf')
RESULTS = Path('/results')

def affinity(cpus):
    return lambda: os.sched_setaffinity(0, cpus)

def run(budget, seats, repeat):
    out = RESULTS / f'game-r{repeat}-b{budget}-s{seats}'
    out.mkdir(exist_ok=False)
    config = json.loads((ROOT / 'config.practice.json').read_text())
    patch = json.loads((ROOT / 'tests/fixtures/shell/shell_demo_config.json').read_text())
    for key, value in patch.items():
        if value is None:
            config.pop(key, None)
        else:
            config[key] = value
    config.update(seed=907, maxGames=1, maxTicks=1200, playSeatBindTicks=120,
                  fastMode=True, speed=1, barrageMaxPerSec=0, gunRange=497, mapPath='arena')
    config['minPlayers'] = seats
    config['players'] = config['players'][:seats]
    config['slots'] = config['slots'][:seats]
    config['tokens'] = config['tokens'][:seats]
    config['demoPlay']['seats'] = list(range(seats))
    path = out / 'config.json'
    path.write_text(json.dumps(config, indent=2) + '\n')
    env = dict(os.environ, COGAME_HOST='0.0.0.0', COGAME_PORT='21814',
               COGAME_CONFIG_URI=f'file://{path}', SHELL_ZONE_LOG='1')
    clients = []
    files = []
    started = time.monotonic()
    with (out / 'server.log').open('w') as log:
        server = subprocess.Popen([str(RESULTS / f'server-{budget}')], cwd=ROOT,
                                  env=env, stdout=log, stderr=subprocess.STDOUT,
                                  preexec_fn=affinity({5}))
        try:
            for _ in range(600):
                if server.poll() is not None:
                    raise RuntimeError(f'server exited during startup: {server.returncode}')
                try:
                    with socket.create_connection(('127.0.0.1', 21814), timeout=.2):
                        break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError('server startup timeout')
            for seat, token in enumerate(config['tokens']):
                client_env = dict(os.environ, COWORLD_PLAYER_WS_URL=
                    f'ws://127.0.0.1:21814/player?slot={seat}&token={token}')
                client_log = (out / f'presence-{seat}.log').open('w')
                files.append(client_log)
                clients.append(subprocess.Popen([str(RESULTS / 'presence')], cwd=ROOT,
                    env=client_env, stdout=client_log, stderr=subprocess.STDOUT,
                    preexec_fn=affinity({6, 7})))
            code = server.wait(timeout=300)
            (out / 'exit.json').write_text(json.dumps(dict(code=code,
                wall_seconds=time.monotonic()-started)) + '\n')
            if code:
                raise RuntimeError(f'server failed: {code}')
        finally:
            for process in [server, *clients]:
                if process.poll() is None:
                    process.terminate()
            for process in [server, *clients]:
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            for file in files:
                file.close()
    print(out.name, 'complete', flush=True)

if __name__ == '__main__':
    for repeat, order in enumerate(((256,512,1024), (1024,512,256)), 1):
        for budget in order:
            for seats in (16,32):
                try:
                    run(budget, seats, repeat)
                except (RuntimeError, subprocess.TimeoutExpired) as error:
                    out = RESULTS / f'game-r{repeat}-b{budget}-s{seats}'
                    (out / 'failure.json').write_text(json.dumps(dict(
                        type=type(error).__name__, error=str(error))) + '\n')
                    print(out.name, 'FAILED:', error, flush=True)
