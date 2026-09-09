#!/usr/bin/env python3
"""Stamp every wiki page's header banner from the live-ruleset record.

Reads docs/wiki/_era.md for the live GameVersion / GLORYVERSION pair, then
walks every other docs/wiki/*.md page, reads that page's own first-line
"Verified against ..." stamp, and — when the page's stamped pair is older
than the live pair — inserts one additional line right after the stamp:

    **Verified against <old stamp> — the live game is GV<n> / GLORYVERSION
    <n>; treat details as unconfirmed.**

The page's own original stamp line is never edited or removed (Law 2 of
docs/designs/THE_WHOLE.md: era truth is sourced, never typed — this script
is the *only* thing that writes the "the live game is ..." sentence, and it
derives it from docs/wiki/_era.md every run rather than hard-coding it).
Running this script twice is a no-op the second time: it checks for its own
sentence before inserting a second copy.

Usage:
    python3 tools/wiki/render_era_banner.py [--wiki-dir docs/wiki] [--check]

--check exits non-zero if any page would change (for CI), without writing.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

STAMP_RE = re.compile(r"^\*(.+)\*\s*$")
GV_RE = re.compile(r"GV\s*0*(\d+)", re.IGNORECASE)
GLORY_RE = re.compile(r"GLORY(?:VERSION)?\s*0*(\d+)", re.IGNORECASE)

# Files in docs/wiki/ that are not wiki *pages* (process docs, or this
# record itself) and should not be banner-stamped or counted as pages.
NON_PAGE_FILES = {"AUDIT.md", "PUBLISH.md", "RESTRUCTURE-PLAN.md"}

STALE_MARKER = "the live game is"


def parse_era(era_path: Path) -> tuple[int, int]:
    text = era_path.read_text()
    gv_match = re.search(r"\*\*GameVersion:\*\*\s*(\d+)", text)
    glory_match = re.search(r"\*\*GLORYVERSION:\*\*\s*(\d+)", text)
    if not gv_match or not glory_match:
        raise SystemExit(
            f"could not find **GameVersion:** and **GLORYVERSION:** fields in {era_path}"
        )
    return int(gv_match.group(1)), int(glory_match.group(1))


def extract_stamp(first_line: str) -> tuple[int, int] | None:
    """Return (gv, glory) parsed from a page's first line, or None."""
    m = STAMP_RE.match(first_line.strip())
    if not m:
        return None
    body = m.group(1)
    gv_match = GV_RE.search(body)
    glory_match = GLORY_RE.search(body)
    if not gv_match or not glory_match:
        return None
    return int(gv_match.group(1)), int(glory_match.group(1))


def process_page(path: Path, era_gv: int, era_glory: int, write: bool) -> str:
    """Return one of: 'current', 'stale', 'stale-already-banded', 'unparsed'."""
    lines = path.read_text().splitlines(keepends=True)
    if not lines:
        return "unparsed"
    stamp = extract_stamp(lines[0])
    if stamp is None:
        return "unparsed"
    page_gv, page_glory = stamp
    if page_gv >= era_gv and page_glory >= era_glory:
        return "current"

    banner = (
        f"**Verified against `GV{page_gv} / Glory {page_glory}` — "
        f"{STALE_MARKER} `GV{era_gv} / GLORYVERSION {era_glory}`; "
        f"treat details as unconfirmed.**\n"
    )

    already = any(STALE_MARKER in line for line in lines[1:4])
    if already:
        return "stale-already-banded"

    if write:
        # Blank line before the banner so it renders as its own paragraph,
        # distinct from the page's original stamp line above it.
        new_lines = [lines[0], "\n", banner] + lines[1:]
        path.write_text("".join(new_lines))
    return "stale"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wiki-dir", default="docs/wiki")
    ap.add_argument(
        "--check",
        action="store_true",
        help="report only, exit 1 if any page is stale-but-unbanded",
    )
    args = ap.parse_args()

    wiki_dir = Path(args.wiki_dir)
    era_path = wiki_dir / "_era.md"
    era_gv, era_glory = parse_era(era_path)

    results: dict[str, list[str]] = {
        "current": [],
        "stale": [],
        "stale-already-banded": [],
        "unparsed": [],
    }

    pages = sorted(
        p
        for p in wiki_dir.glob("*.md")
        if p.name not in NON_PAGE_FILES and not p.name.startswith("_")
    )

    for page in pages:
        status = process_page(page, era_gv, era_glory, write=not args.check)
        results[status].append(page.name)

    total = len(pages)
    stale_total = len(results["stale"]) + len(results["stale-already-banded"])
    print(f"era: GV{era_gv} / GLORYVERSION {era_glory}  ({era_path})")
    print(f"pages scanned: {total}")
    print(f"  current (no banner needed): {len(results['current'])} — {results['current']}")
    print(
        f"  stale, banner {'inserted' if not args.check else 'needed'}: "
        f"{len(results['stale'])} — {results['stale']}"
    )
    print(
        f"  stale, banner already present: {len(results['stale-already-banded'])} "
        f"— {results['stale-already-banded']}"
    )
    print(f"  unparsed (no recognizable stamp, skipped): {len(results['unparsed'])} — {results['unparsed']}")

    if args.check and results["stale"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
