#!/usr/bin/env python3
"""era.py's mirrored literals must equal docs/wiki/_era.md, the source of
record (THE_WHOLE.md Law 2: "era truth is sourced, never typed").

era.py cannot parse docs/wiki/_era.md at import time -- a beginner's copy
of policies/starters/ is a standalone project that does not ship docs/
(see era.py's own docstring) -- so it carries a copy of the same literals
instead. This test is the drift guard for that copy: it runs from the
monorepo checkout, where docs/wiki/_era.md exists, and fails loudly the
moment someone bumps one file and not the other.

Run from anywhere: python3 policies/starters/common/test_era.py
Wired into CI as the `era-tripwire` job in .github/workflows/build.yml.

If docs/wiki/_era.md is not found (e.g. this file was copied out on its
own, same as the rest of policies/starters/), the check is skipped rather
than failed -- there is nothing to compare against outside the monorepo.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import era  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[3]
ERA_MD = REPO_ROOT / "docs" / "wiki" / "_era.md"


def parse_era_md(path: Path) -> dict[str, str]:
    text = path.read_text()

    def field(label: str, pattern: str) -> str:
        m = re.search(rf"\*\*{label}:\*\*\s*{pattern}", text)
        if not m:
            raise AssertionError(f"could not find **{label}:** field in {path}")
        return m.group(1)

    return {
        "LIVE_VARIANT": field("Live variant", r"`([^`]+)`"),
        "BUILD_TAG": field("Build tag", r"`([^`]+)`"),
        "GAME_VERSION": field("GameVersion", r"(\d+)"),
        "GLORY_VERSION": field("GLORYVERSION", r"(\d+)"),
    }


def main() -> None:
    if not ERA_MD.exists():
        print(f"skip: {ERA_MD} not present (standalone starter checkout)")
        return

    record = parse_era_md(ERA_MD)

    assert era.LIVE_VARIANT == record["LIVE_VARIANT"], (
        f"era.LIVE_VARIANT={era.LIVE_VARIANT!r} != "
        f"docs/wiki/_era.md's Live variant={record['LIVE_VARIANT']!r} -- "
        "edit era.py to match (docs/wiki/_era.md is authoritative)"
    )
    assert era.BUILD_TAG == record["BUILD_TAG"], (
        f"era.BUILD_TAG={era.BUILD_TAG!r} != "
        f"docs/wiki/_era.md's Build tag={record['BUILD_TAG']!r} -- "
        "edit era.py to match (docs/wiki/_era.md is authoritative)"
    )
    assert era.GAME_VERSION == int(record["GAME_VERSION"]), (
        f"era.GAME_VERSION={era.GAME_VERSION!r} != "
        f"docs/wiki/_era.md's GameVersion={record['GAME_VERSION']!r} -- "
        "edit era.py to match (docs/wiki/_era.md is authoritative)"
    )
    assert era.GLORY_VERSION == int(record["GLORY_VERSION"]), (
        f"era.GLORY_VERSION={era.GLORY_VERSION!r} != "
        f"docs/wiki/_era.md's GLORYVERSION={record['GLORY_VERSION']!r} -- "
        "edit era.py to match (docs/wiki/_era.md is authoritative)"
    )
    print(
        "era.py matches docs/wiki/_era.md: "
        f"{era.LIVE_VARIANT} / {era.BUILD_TAG} / "
        f"GV{era.GAME_VERSION} / GLORYVERSION {era.GLORY_VERSION}: OK"
    )


if __name__ == "__main__":
    main()
