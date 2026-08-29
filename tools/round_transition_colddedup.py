#!/usr/bin/env python3
"""Tests the coordinator's hypothesis: does the SAME cold-dedup path that
churn stall (01b2eead) exercises also fire on ORDINARY round transitions,
with NO guest churn at all -- purely from the server's own reset path
re-registering every already-connected bot socket (admitPendingJoins ->
appState.playerViewers[socket] = initPlayerViewerState(), which wipes
sentPlacements for every roster socket at once)?

Method: one server, 8 bots (config.freeplay-churn.json, the known-good
config -- avoids conflating with the SEPARATE already-filed 16-seat
config-recording bug, task 6564b968), ZERO guest traffic. Poll
/health/frame at 50ms resolution for several rounds. Cross-reference
poll timestamps against sim.log's "game started"/"win" lines (which are
flushed to the log file as they're echoed) to find the exact
wall-clock moment of each transition, then look at the coldDedup delta
in a tight window straddling that moment vs. a window well inside a
round (steady combat).
"""
import asyncio
import json
import os
import re
import signal
import subprocess
import sys
import time

sys.path.insert(0, "/Users/maxwellstarr/projects/ctf-churn-verify/tools")
import churn_regression as cr

REPO_ROOT = "/Users/maxwellstarr/projects/ctf-churn-verify"
PORT = 22131
DURATION = 70.0

server_bin = os.path.join(REPO_ROOT, "bin", "churn-regression-server")
bot_bin = os.path.join(REPO_ROOT, "players", "baseline", "churn-regression-bot.out")
config_path = os.path.join(REPO_ROOT, "config.freeplay-churn.json")
log_dir = "/tmp/round-transition-test"
os.makedirs(log_dir, exist_ok=True)
server_log_path = os.path.join(log_dir, "server.log")

with open(config_path) as f:
    tokens = json.load(f)["tokens"]

spawned = []


async def poll_frame_health(base, samples, stop_at):
    async with cr.aiohttp.ClientSession() as session:
        while time.monotonic() < stop_at:
            t0 = time.monotonic()
            try:
                async with session.get(
                    f"{base}/health/frame", timeout=cr.aiohttp.ClientTimeout(total=2)
                ) as r:
                    data = await r.json()
                    samples.append((time.monotonic(), data))
            except Exception as e:
                samples.append((time.monotonic(), {"error": str(e)}))
            # 50ms resolution: tight enough to bracket a single-tick spike.
            elapsed = time.monotonic() - t0
            await asyncio.sleep(max(0.0, 0.05 - elapsed))


def main():
    env = dict(os.environ)
    env["COGAME_HOST"] = "0.0.0.0"
    env["COGAME_PORT"] = str(PORT)
    env["COGAME_CONFIG_URI"] = f"file://{config_path}"
    server_log = open(server_log_path, "w")
    server_proc = subprocess.Popen(
        [server_bin], cwd=REPO_ROOT, env=env, stdout=server_log, stderr=subprocess.STDOUT
    )
    spawned.append(server_proc)
    print(f"[roundtest] server pid={server_proc.pid} port={PORT}", flush=True)
    try:
        cr.wait_for_listener(PORT, server_proc, timeout_s=60)
        print("[roundtest] listening", flush=True)

        for i, token in enumerate(tokens):
            benv = dict(os.environ)
            benv["COWORLD_PLAYER_WS_URL"] = f"ws://127.0.0.1:{PORT}/player?slot={i}&token={token}"
            bot_log = open(os.path.join(log_dir, f"bot_{i}.log"), "w")
            bot_proc = subprocess.Popen(
                [bot_bin], cwd=REPO_ROOT, env=benv, stdout=bot_log, stderr=subprocess.STDOUT
            )
            spawned.append(bot_proc)
        print(f"[roundtest] seated {len(tokens)} bots (NO guest churn)", flush=True)

        base = f"http://127.0.0.1:{PORT}"
        samples = []
        start_wall = time.monotonic()
        asyncio.run(poll_frame_health(base, samples, start_wall + DURATION))

        rounds = cr.round_count(server_log_path)
        print(f"[roundtest] rounds completed: {rounds}", flush=True)

        # Find transition wall-clock offsets: re-read server.log with a
        # timestamp-free grep is not enough -- but we polled at 50ms and can
        # instead find the transition ticks (round length is deterministic:
        # maxTicks=240) and correlate directly against the coldDedup series
        # for spikes, independent of log timestamps.
        with open(os.path.join(log_dir, "samples.jsonl"), "w") as f:
            for t, d in samples:
                f.write(json.dumps({"t": t - start_wall, **(d if isinstance(d, dict) else {"raw": d})}) + "\n")

        # coldDedup delta per sample, and tick delta, to find spikes.
        rows = [(t - start_wall, d) for (t, d) in samples if isinstance(d, dict) and "coldDedup" in d]
        print(f"[roundtest] {len(rows)} valid samples", flush=True)
        prev = None
        spikes = []
        for t, d in rows:
            if prev is not None:
                dcold = d["coldDedup"] - prev[1]["coldDedup"]
                dtick = d["tick"] - prev[1]["tick"]
                if dcold > 0:
                    spikes.append((t, dcold, dtick))
            prev = (t, d)
        print(f"[roundtest] {len(spikes)} samples with coldDedup>0 (of {len(rows)-1} intervals)", flush=True)
        for t, dcold, dtick in spikes:
            print(f"[roundtest]   t={t:.2f}s  coldDedup+={dcold}  tick+={dtick}", flush=True)

        total_cold = rows[-1][1]["coldDedup"] - rows[0][1]["coldDedup"] if len(rows) >= 2 else None
        print(f"[roundtest] total coldDedup over window: {total_cold}", flush=True)

    finally:
        for proc in spawned:
            if proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
        deadline = time.monotonic() + 5
        for proc in spawned:
            remaining = max(0.0, deadline - time.monotonic())
            try:
                proc.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    main()
