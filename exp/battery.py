"""A/B scrimmage battery: two Nim bot binaries, 8v8, sides alternated.

Every episode is one server plus 16 bot processes. Team A takes the even
(red) slots on even episodes and the odd (blue) slots on odd ones, so the
red-side advantage measured in this project (28-12 on a 40-episode mirror,
p=0.0166) cancels in the battery total instead of loading one arm.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def run_episode(a_bin: Path, b_bin: Path, episode: int, port: int, work: Path,
                config: Path, artlog: bool = False) -> dict:
    ep_dir = (work / f"ep_{episode:04d}").resolve()
    ep_dir.mkdir(parents=True, exist_ok=True)
    results_path = ep_dir / "results.json"
    a_side = "red" if episode % 2 == 0 else "blue"
    a_slots = [s for s in range(16) if (s % 2 == 0) == (a_side == "red")]

    t0 = time.time()
    server = subprocess.Popen(
        [str(REPO / "src" / "ctf_server_bin")],
        cwd=REPO,
        env={
            "PATH": "/usr/bin:/bin",
            "HOME": str(Path.home()),
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(port),
            "COGAME_CONFIG_URI": f"file://{config}",
            "COGAME_RESULTS_URI": f"file://{results_path}",
        },
        stdout=(ep_dir / "server.log").open("w"),
        stderr=subprocess.STDOUT,
    )
    time.sleep(2.0)
    kids = []
    try:
        for slot in range(16):
            binary = a_bin if slot in a_slots else b_bin
            art = ({"CTF_ARTLOG_PATH": str(ep_dir / f"art_{slot:02d}.zip")}
                   if artlog else {})
            kids.append(subprocess.Popen(
                [str(binary)],
                cwd=REPO,
                env={
                    "PATH": "/usr/bin:/bin",
                    "HOME": str(Path.home()),
                    "COWORLD_PLAYER_WS_URL":
                        f"ws://127.0.0.1:{port}/player?slot={slot}&token=0xBADA55_{slot}",
                    **art,
                },
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ))
        server.wait(timeout=1800)
    finally:
        for k in kids:
            k.terminate()
        if server.poll() is None:
            server.terminate()

    results = json.loads(results_path.read_text())
    teams = results["team"]
    log_text = (ep_dir / "server.log").read_text()
    pacing = re.search(
        r"Frame pacing: (\d+) playing frames — skipped (\d+) \((\d+\.\d+)%\)", log_text)
    a_team = a_side
    b_team = "blue" if a_side == "red" else "red"

    def team_sum(key: str, team: str) -> int:
        vals = results.get(key)
        if vals is None:
            return -1
        return sum(v for v, t in zip(vals, teams, strict=True) if t == team)

    out = {
        "episode": episode,
        "a_side": a_side,
        "a_score": team_sum("scores", a_team),
        "b_score": team_sum("scores", b_team),
        "a_kills": team_sum("kills", a_team),
        "b_kills": team_sum("kills", b_team),
        "a_teamkills": team_sum("teamKills", a_team),
        "b_teamkills": team_sum("teamKills", b_team),
        "a_deaths": team_sum("deaths", a_team),
        "b_deaths": team_sum("deaths", b_team),
        "a_captures": team_sum("captures", a_team),
        "b_captures": team_sum("captures", b_team),
        "frames": int(pacing.group(1)) if pacing else -1,
        "skipped": int(pacing.group(2)) if pacing else -1,
        "wall_s": round(time.time() - t0, 1),
        "raw": results,
    }
    a_win = {w for w, t in zip(results["win"], teams, strict=True) if t == a_team}
    b_win = {w for w, t in zip(results["win"], teams, strict=True) if t == b_team}
    assert len(a_win) == 1 and len(b_win) == 1, (a_win, b_win)
    out["a_won"] = a_win.pop()
    out["b_won"] = b_win.pop()
    out["draw"] = not out["a_won"] and not out["b_won"]
    (ep_dir / "outcome.json").write_text(json.dumps(out, indent=1))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--a-bin", type=Path, required=True)
    ap.add_argument("--b-bin", type=Path, required=True)
    ap.add_argument("--episodes", type=int, required=True)
    ap.add_argument("--parallel", type=int, default=3)
    ap.add_argument("--base-port", type=int, default=2400)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--config", type=Path, default=REPO / "config.json")
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--artlog", action="store_true",
                    help="write each seat's decision telemetry zip into the episode dir")
    args = ap.parse_args()

    args.work.mkdir(parents=True, exist_ok=True)
    a_bin = args.a_bin.resolve()
    b_bin = args.b_bin.resolve()
    log = (args.work / "episodes.jsonl").open("a")

    ports: "queue.Queue[int]" = queue.Queue()
    for k in range(args.parallel):
        ports.put(args.base_port + k)

    def job(i: int) -> dict:
        # A port is owned by exactly one in-flight episode. Deriving it from
        # the episode index instead lets episode i and i+parallel overlap
        # whenever one run is slow, and the second server then fails to bind.
        port = ports.get()
        try:
            return run_episode(a_bin, b_bin, i, port, args.work,
                               args.config.resolve(), artlog=args.artlog)
        finally:
            ports.put(port)

    eps = list(range(args.start, args.start + args.episodes))
    with ThreadPoolExecutor(max_workers=args.parallel) as pool:
        for out in pool.map(job, eps):
            slim = {k: v for k, v in out.items() if k != "raw"}
            log.write(json.dumps(slim) + "\n")
            log.flush()
            print(json.dumps(slim), flush=True)


if __name__ == "__main__":
    main()
