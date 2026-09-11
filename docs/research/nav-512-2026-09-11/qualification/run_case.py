"""Run one frozen qualification config through the original finite server/presence lifecycle."""
import json
import os
from pathlib import Path
import socket
import subprocess
import time

ROOT = Path('/workspace/ctf')

def affinity(cpus):
    return lambda: os.sched_setaffinity(0, cpus)

def run(config_path, server_path, presence_path, out, server_cpus):
    out.mkdir(parents=True, exist_ok=False)
    config = json.loads(config_path.read_text())
    path = out / 'config.json'
    path.write_text(json.dumps(config, indent=2) + '\n')
    env = dict(os.environ, COGAME_HOST='0.0.0.0', COGAME_PORT='21814',
               COGAME_CONFIG_URI=f'file://{path}', SHELL_ZONE_LOG='1')
    clients = []
    files = []
    started = time.monotonic()
    with (out / 'server.log').open('w') as log:
        server = subprocess.Popen([str(server_path)], cwd=ROOT,
                                  env=env, stdout=log, stderr=subprocess.STDOUT,
                                  preexec_fn=affinity(server_cpus) if server_cpus else None)
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
                clients.append(subprocess.Popen([str(presence_path)], cwd=ROOT,
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
    import argparse
    parser = argparse.ArgumentParser(description='Finite real-game qualification case; preserves the original screen process lifecycle.')
    parser.add_argument('config', type=Path)
    parser.add_argument('server', type=Path)
    parser.add_argument('presence', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--server-cpus', default='5', help='Comma-separated logical CPUs, or all for an unpinned server.')
    args = parser.parse_args()
    cpus = None if args.server_cpus == 'all' else {int(c) for c in args.server_cpus.split(',')}
    try:
        run(args.config, args.server, args.presence, args.output, cpus)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        (args.output/'failure.json').write_text(json.dumps(dict(type=type(error).__name__,error=str(error)))+'\n')
        raise
