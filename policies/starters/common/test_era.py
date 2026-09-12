#!/usr/bin/env python3
"""Two tripwires on one authoritative record, docs/wiki/_era.md:

1. era.py's mirrored literals must equal it (the original check below).
2. docs/RULES.md's live glory-scoring section must name the SAME build tag
   and the SAME GLORYVERSION (`check_rules_md`). RULES.md carried four
   lines calling a LIVE economy a draft until #559 rewrote them by hand;
   the next such drift fails this test instead of waiting for a reader.

era.py's mirrored literals must equal docs/wiki/_era.md, the source of
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
RULES_MD = REPO_ROOT / "docs" / "RULES.md"


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


def parse_rules_live_line(path: Path) -> dict[str, str]:
    """The live status line of `docs/RULES.md`'s current-era scoring section.

    RULES.md marks more than one glory-scoring section `**This section is
    live.**` (a superseded catalog section stays marked live because its
    flags are still armed). Exactly ONE of those paragraphs names the BUILD
    TAG the published variant runs from -- that is the current-era status
    line, and the invariant this function asserts. Both values come out of
    that single paragraph: never from the section HEADING (which reads
    "GLORYVERSION 17 -> 18", a transition, and would match the wrong
    number), and never from elsewhere in the file, where superseded
    sections legitimately still name older versions in the past tense.
    """
    text = path.read_text()
    marker = "**This section is live.**"
    tag_re = re.compile(r"\*\*`(paintbot-v[^`]+)`\*\*")

    paragraphs = []
    pos = text.find(marker)
    while pos >= 0:
        end = text.find("\n\n", pos)
        paragraphs.append(text[pos:] if end < 0 else text[pos:end])
        pos = text.find(marker, pos + len(marker))
    if not paragraphs:
        raise AssertionError(
            f"could not find {marker!r} in {path} -- the live glory-scoring "
            "section must mark itself live so this tripwire can find it"
        )

    with_tag = [p for p in paragraphs if tag_re.search(p)]
    if len(with_tag) != 1:
        raise AssertionError(
            f"{path} has {len(paragraphs)} {marker!r} paragraph(s), of which "
            f"{len(with_tag)} name a bold **`paintbot-v...`** build tag; "
            "exactly one must (it is the current-era status line this "
            "tripwire checks against docs/wiki/_era.md)"
        )
    para = with_tag[0]

    gv = re.search(r"\*\*GLORYVERSION (\d+)\*\*", para)
    if not gv:
        raise AssertionError(
            f"the live status line of {path} names a build tag but no bold "
            "**GLORYVERSION <n>** -- cannot check it against _era.md"
        )
    return {"GLORY_VERSION": gv.group(1),
            "BUILD_TAG": tag_re.search(para).group(1)}


def check_rules_md(record: dict[str, str]) -> None:
    """`docs/wiki/_era.md` is authoritative; `docs/RULES.md`'s live section
    must agree with it on the build tag AND the GLORYVERSION.

    Why this is a test and not a convention: RULES.md carried four lines
    calling a LIVE economy a draft until #559 rewrote them by hand. The next
    such drift should fail a build, not wait for a reader to notice.
    """
    if not RULES_MD.exists():
        print(f"skip: {RULES_MD} not present")
        return
    live = parse_rules_live_line(RULES_MD)
    assert live["BUILD_TAG"] == record["BUILD_TAG"], (
        f"docs/RULES.md's live section names build tag "
        f"{live['BUILD_TAG']!r} but docs/wiki/_era.md's Build tag is "
        f"{record['BUILD_TAG']!r} -- docs/RULES.md IS THE STALE FILE "
        "(docs/wiki/_era.md is authoritative; edit RULES.md to match, or "
        "edit _era.md first if the era itself moved)"
    )
    assert live["GLORY_VERSION"] == record["GLORY_VERSION"], (
        f"docs/RULES.md's live section names GLORYVERSION "
        f"{live['GLORY_VERSION']} but docs/wiki/_era.md's GLORYVERSION is "
        f"{record['GLORY_VERSION']} -- docs/RULES.md IS THE STALE FILE "
        "(docs/wiki/_era.md is authoritative; edit RULES.md to match, or "
        "edit _era.md first if the era itself moved)"
    )
    print(
        "docs/RULES.md's live section matches docs/wiki/_era.md: "
        f"{live['BUILD_TAG']} / GLORYVERSION {live['GLORY_VERSION']}: OK"
    )


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

    check_rules_md(record)


if __name__ == "__main__":
    main()
