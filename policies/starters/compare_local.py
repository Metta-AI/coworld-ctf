#!/usr/bin/env python3
"""Run two seed-matched local episodes -- before and after changing one
knob -- and print a small before/after table in glossary words: Glory
this episode by deed, rank in the episode, tags made, survived until.

`coworld_manifest.json`'s `battle-royale-s2` variant carries a FIXED
`game_config.seed`, so two separate single-episode runs against the same
manifest always play the same map and spawn layout (verified: both
config.json's `seed` and `mapPath` were identical across two independent
runs on 2026-09-09). That holds the scenario constant; it does not make
outcomes deterministic -- containers schedule on real wall-clock time, so
one before/after pair is a data point, not a proof. Run it more than once
before trusting a small difference (see policies/starters/VERSION_LOG.md's
own "noise floor" note: treat small deltas as noise).

Usage, from the repository root:

    uv run python policies/starters/compare_local.py \\
      coworld/<id>/coworld_manifest.json starter-cautious:local \\
      --knob recall-seconds --before 15 --after 4 --seat 0

Runs two episodes (runs/compare/before, runs/compare/after), each via
run_local.py, then prints both tables.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))
sys.path.insert(0, str(_HERE / "common"))
from starter_knobs import KNOBS  # noqa: E402
from parse_local_run import load_run, render_table  # noqa: E402
import run_local  # noqa: E402


def run_one(manifest: str, image: str, output_dir: str, knob: str, value: str,
            *, timeout_seconds: float, canned: bool, run_tokens: list[str]) -> None:
    argv = [manifest, image, "-o", output_dir,
            "--timeout-seconds", str(timeout_seconds), f"--{knob}", value]
    if canned:
        argv.append("--canned")
    for token in run_tokens:
        argv += ["--run", token]
    rc = run_local.main(argv)
    if rc != 0:
        raise SystemExit(f"run_local.py failed (exit {rc}) for {output_dir} "
                          f"-- see coworld's own output above.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("manifest")
    parser.add_argument("image")
    parser.add_argument("--knob", required=True, choices=sorted(KNOBS),
                         help="the one thing to change between runs")
    parser.add_argument("--before", required=True, help="knob value for the BEFORE run")
    parser.add_argument("--after", required=True, help="knob value for the AFTER run")
    parser.add_argument("--seat", type=int, default=0,
                         help="which seat is 'you' in the table (default: seat 0)")
    parser.add_argument("--output-dir", default="runs/compare")
    parser.add_argument("--timeout-seconds", type=float, default=300.0)
    parser.add_argument("--canned", action="store_true")
    parser.add_argument("--run", action="append", default=[], metavar="TOKEN",
                         help="one argv token for your image's entrypoint, "
                         "repeated (see run_local.py --help)")
    args = parser.parse_args(argv)

    before_dir = f"{args.output_dir}/before"
    after_dir = f"{args.output_dir}/after"

    print(f"=== BEFORE: --{args.knob} {args.before} ===")
    run_one(args.manifest, args.image, before_dir, args.knob, args.before,
            timeout_seconds=args.timeout_seconds, canned=args.canned, run_tokens=args.run)
    print(f"=== AFTER: --{args.knob} {args.after} ===")
    run_one(args.manifest, args.image, after_dir, args.knob, args.after,
            timeout_seconds=args.timeout_seconds, canned=args.canned, run_tokens=args.run)

    before_rows = load_run(before_dir)
    after_rows = load_run(after_dir)
    print()
    print(render_table("BEFORE", before_rows, focus_seat=args.seat))
    print(render_table("AFTER", after_rows, focus_seat=args.seat))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
