#!/usr/bin/env python3
"""Regression test for the guest-churn round-cycling stall.

Repro shape: a handful of guests repeatedly grab and drop Free Play seat
takeovers (the ONLY way a guest touches a live field -- see
registerTakeoverWebSocket in src/ctf/server.nim). Each connect/disconnect
walks through appState.lock multiple times on the HTTP worker threads
(ticket mint, WS upgrade accept/reject, OpenEvent, MessageEvent, CloseEvent).
The server's own per-tick broadcast pass ALSO re-acquires appState.lock once
per connected socket (see the `sockets`/`takeoverSockets` loops in
runServerLoop), so under concurrent churn the main tick thread has to win
that single mutex 10+ separate times a tick against a firehose of worker-
thread contenders. When it loses, the tick stalls -- and since round
transitions (lobby countdown, startGame, finishGame) only run inside that
same tick, the WHOLE FIELD stops cycling rounds for as long as the stall
lasts. Bots stay connected and seated throughout: this is not the old
roster/re-registration defect, it is lock contention.

The server already ships a live diagnostic for exactly this: GET
/health/frame reports the tick thread's current phase and how long it has
been there, with `stalled: msInPhase > 1000`. This test asserts on THAT
real, already-instrumented server state (not a restatement of the theory):
under a churn workload, the frame loop must never report stalled=true, and
the round counter (grep of "draw"/" win" lines in the server's own game-event
log) must keep advancing throughout the churn window.

Usage:
  python3 tools/churn_regression.py [--port 21999] [--duration 45]
                                     [--concurrency 4] [--skip-build]

Exit code 0 = pass (no stall, rounds kept cycling), 1 = fail.
Builds bin/churn-regression-server + players/baseline/churn-regression-bot.out
if missing (or --skip-build reuses whatever is already at those paths).
Starts and stops ONLY the processes it spawns itself (pids captured at
Popen() time); never touches any other field.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

import aiohttp
import websockets

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def build(skip_build: bool, server_bin: str, bot_bin: str) -> None:
    if skip_build and os.path.exists(server_bin) and os.path.exists(bot_bin):
        print(f"[churn-regression] reusing existing binaries")
        return
    print(f"[churn-regression] building release server -> {server_bin}")
    subprocess.run(
        ["nim", "c", "-d:release", "--hints:off", "--path:src", "-o:" + server_bin,
         "src/ctf.nim"],
        cwd=REPO_ROOT, check=True,
    )
    print(f"[churn-regression] building release baseline bot -> {bot_bin}")
    subprocess.run(
        ["nim", "c", "-d:release", "--hints:off", "-o:" + bot_bin,
         "players/baseline/baseline.nim"],
        cwd=REPO_ROOT, check=True,
    )


def wait_for_listener(port: int, proc: subprocess.Popen, timeout_s: float) -> None:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"server exited early with code {proc.returncode}")
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1):
                return
        except Exception:
            time.sleep(0.25)
    raise RuntimeError("server never opened its listener")


def round_count(log_path: str) -> int:
    if not os.path.exists(log_path):
        return 0
    n = 0
    with open(log_path, "r", errors="replace") as f:
        for line in f:
            s = line.strip()
            if s == "draw" or s.endswith(" win"):
                n += 1
    return n


async def get_ticket(session: "aiohttp.ClientSession", base: str) -> dict:
    async with session.get(f"{base}/takeover/seat", timeout=aiohttp.ClientTimeout(total=5)) as r:
        return await r.json()


async def guest_churn_loop(session, ws_base, base, tokens, name, hold_s, stop_at):
    while time.monotonic() < stop_at:
        try:
            info = await get_ticket(session, base)
        except Exception:
            await asyncio.sleep(0.2)
            continue
        seat = info.get("seat", -1)
        if seat < 0:
            await asyncio.sleep(0.15)
            continue
        ticket = info["ticket"]
        token = tokens[seat]
        url = f"{ws_base}/takeover?slot={seat}&token={token}&ticket={ticket}&name={name}"
        try:
            async with websockets.connect(url, open_timeout=8, close_timeout=8):
                await asyncio.sleep(hold_s)
        except Exception:
            continue


async def poll_frame_health(base: str, samples: list, stop_at: float) -> None:
    async with aiohttp.ClientSession() as session:
        while time.monotonic() < stop_at:
            try:
                async with session.get(
                    f"{base}/health/frame", timeout=aiohttp.ClientTimeout(total=2)
                ) as r:
                    data = await r.json()
                    samples.append((time.monotonic(), data))
            except Exception as e:
                samples.append((time.monotonic(), {"error": str(e)}))
            await asyncio.sleep(0.25)


async def run_workload(port: int, duration_s: float, concurrency: int, num_slots: int):
    base = f"http://127.0.0.1:{port}"
    ws_base = f"ws://127.0.0.1:{port}"
    tokens = {i: f"0xBADA55_{i}" for i in range(num_slots)}
    stop_at = time.monotonic() + duration_s
    frame_samples: list = []

    async with aiohttp.ClientSession() as session:
        churners = [
            guest_churn_loop(session, ws_base, base, tokens, f"guest{i}", 0.3, stop_at)
            for i in range(concurrency)
        ]
        await asyncio.gather(
            poll_frame_health(base, frame_samples, stop_at),
            *churners,
        )
    return frame_samples


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=21998)
    ap.add_argument("--duration", type=float, default=45.0)
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--config", default="config.freeplay-churn.json")
    ap.add_argument("--skip-build", action="store_true")
    args = ap.parse_args()

    server_bin = os.path.join(REPO_ROOT, "bin", "churn-regression-server")
    bot_bin = os.path.join(REPO_ROOT, "players", "baseline", "churn-regression-bot.out")
    config_path = os.path.join(REPO_ROOT, args.config)
    log_dir = os.path.join(REPO_ROOT, ".churn-regression")
    os.makedirs(log_dir, exist_ok=True)
    server_log_path = os.path.join(log_dir, "server.log")

    build(args.skip_build, server_bin, bot_bin)

    with open(config_path) as f:
        tokens = json.load(f)["tokens"]

    spawned: list[subprocess.Popen] = []  # pids recorded AT SPAWN; killed at teardown, nothing else
    try:
        env = dict(os.environ)
        env["COGAME_HOST"] = "0.0.0.0"
        env["COGAME_PORT"] = str(args.port)
        env["COGAME_CONFIG_URI"] = f"file://{config_path}"
        server_log = open(server_log_path, "w")
        server_proc = subprocess.Popen(
            [server_bin], cwd=REPO_ROOT, env=env, stdout=server_log, stderr=subprocess.STDOUT
        )
        spawned.append(server_proc)  # pid recorded right here, at spawn
        print(f"[churn-regression] server pid={server_proc.pid} port={args.port}")
        wait_for_listener(args.port, server_proc, timeout_s=60)
        print("[churn-regression] listening")

        for i, token in enumerate(tokens):
            benv = dict(os.environ)
            benv["COWORLD_PLAYER_WS_URL"] = f"ws://127.0.0.1:{args.port}/player?slot={i}&token={token}"
            bot_log = open(os.path.join(log_dir, f"bot_{i}.log"), "w")
            bot_proc = subprocess.Popen(
                [bot_bin], cwd=REPO_ROOT, env=benv, stdout=bot_log, stderr=subprocess.STDOUT
            )
            spawned.append(bot_proc)  # pid recorded right here, at spawn
        print(f"[churn-regression] seated {len(tokens)} bots")

        # Let the lobby fill and run a couple of quick baseline rounds before
        # the churn workload starts, so we have a real "cycling normally"
        # count to compare against.
        deadline = time.monotonic() + 30
        while round_count(server_log_path) < 1 and time.monotonic() < deadline:
            time.sleep(1)
        rounds_before = round_count(server_log_path)
        print(f"[churn-regression] rounds before churn: {rounds_before}")

        frame_samples = asyncio.run(
            run_workload(args.port, args.duration, args.concurrency, len(tokens))
        )

        rounds_after = round_count(server_log_path)
        print(f"[churn-regression] rounds after churn: {rounds_after}")

        stalled_readings = [
            (t, d) for (t, d) in frame_samples if isinstance(d, dict) and d.get("stalled")
        ]
        max_ms = max(
            (d.get("msInPhase", 0) for (_, d) in frame_samples if isinstance(d, dict)),
            default=0,
        )
        print(
            f"[churn-regression] frame health samples={len(frame_samples)} "
            f"stalled_readings={len(stalled_readings)} max_msInPhase={max_ms}"
        )

        ok = True
        if stalled_readings:
            ok = False
            print(
                f"[churn-regression] FAIL: /health/frame reported stalled=true "
                f"{len(stalled_readings)} time(s) during churn (worst msInPhase={max_ms})"
            )
        if rounds_after <= rounds_before:
            ok = False
            print(
                f"[churn-regression] FAIL: round counter did not advance during "
                f"{args.duration}s of churn ({rounds_before} -> {rounds_after})"
            )
        if ok:
            print(
                f"[churn-regression] PASS: no stall, rounds kept cycling "
                f"({rounds_before} -> {rounds_after}) under {args.concurrency}x guest churn"
            )
        return 0 if ok else 1
    finally:
        # Kill ONLY the pids this run recorded at spawn -- never a pattern kill.
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
    sys.exit(main())
