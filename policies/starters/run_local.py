#!/usr/bin/env python3
"""Run one local episode of the LIVE ladder variant against your policy
image -- and refuse, rather than silently drift onto `coworld run-episode`'s
own certification fixture, if that variant is ever unset.

Prerequisites: Docker running, `uv add coworld` already done in this
project (see pyproject.toml / .python-version next to this file for the
Python bound that avoids the fresh-machine trap), and a policy image built
locally, e.g.:

    docker build --platform linux/amd64 -f policies/starters/cautious/Dockerfile \\
      -t starter-cautious:local .

Then, from the repository root:

    uv run python policies/starters/run_local.py \\
      coworld/<id>/coworld_manifest.json starter-cautious:local

`<id>` comes from `uv run coworld download <coworld id from the wiki/forum>`
(see docs/wiki/your-first-policy.md). Five named knobs -- the starter
harness's own live-loop schedule -- can be changed without a rebuild; see
`--help` or policies/starters/common/starter_knobs.py.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "common"))
from era import LIVE_VARIANT  # noqa: E402
from starter_knobs import KNOBS  # noqa: E402


def build_argv(args: argparse.Namespace) -> list[str]:
    if not LIVE_VARIANT:
        raise SystemExit(
            "run_local refuses to start: LIVE_VARIANT is unset in "
            "policies/starters/common/era.py. Fix that constant rather than "
            "letting `coworld run-episode` silently fall back to its own "
            "certification fixture -- a different map and team count that "
            "looks like a real run but is not the ladder ruleset "
            "(docs/designs/JOURNEY_MAP.md J17)."
        )
    argv = [
        "uv", "run", "coworld", "run-episode", args.manifest, args.image,
        "--variant", LIVE_VARIANT,
        "--timeout-seconds", str(args.timeout_seconds),
        "-o", args.output_dir,
    ]
    for token in args.run:
        argv += ["--run", token]
    for name, knob in KNOBS.items():
        value = getattr(args, name.replace("-", "_"))
        if value is not None:
            argv += ["--secret-env", f"{knob.env}={value}"]
    if args.canned:
        argv += ["--secret-env", "POC_CANNED=1"]
    for kv in args.secret_env:
        argv += ["--secret-env", kv]
    return argv


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("manifest", help="path to coworld_manifest.json "
                         "(from `coworld download`)")
    parser.add_argument("image", help="local docker tag for your policy "
                         "image, e.g. starter-cautious:local")
    parser.add_argument("--output-dir", "-o", default="runs/local")
    parser.add_argument("--timeout-seconds", type=float, default=300.0)
    parser.add_argument("--run", action="append", default=[],
                         metavar="TOKEN", help="one argv token for your "
                         "image's entrypoint, repeated (matches coworld's "
                         "own --run: one token per flag, not a JSON array). "
                         "Use the --run=TOKEN form (with '=') when a token "
                         "itself starts with '-', e.g. --canned -- plain "
                         "'--run --canned' is ambiguous to this parser. "
                         "Needed unless your image's default command is "
                         "already correct -- e.g. for the bundled starters: "
                         "--run=python --run=/app/policies/starters/"
                         "cautious/policy.py --run=--canned")
    parser.add_argument("--canned", action="store_true",
                         help="offline/CI decisions, no model credentials "
                              "(what a beginner runs before wiring a model)")
    parser.add_argument("--secret-env", action="append", default=[],
                         metavar="KEY=VALUE", help="pass any other env "
                         "var straight through (repeatable)")
    for name, knob in KNOBS.items():
        parser.add_argument(f"--{name}", dest=name.replace("-", "_"),
                             default=None, help=knob.help)
    args = parser.parse_args(argv)

    command = build_argv(args)
    print("+ " + " ".join(command))
    return subprocess.call(command)


if __name__ == "__main__":
    raise SystemExit(main())
