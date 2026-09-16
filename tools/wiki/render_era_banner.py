#!/usr/bin/env python3
"""Stamp every wiki page's header banner from the live-ruleset record.

Reads docs/wiki/_era.md for the live GameVersion / GLORYVERSION pair, then
walks every other docs/wiki/*.md page, reads that page's own first-line
"Verified against ..." stamp, and — when the page's stamped pair is older
than the live pair — inserts one additional line right after the stamp:

    **Verified against <old stamp> — the live game is GV<n> / GLORYVERSION
    <n>; treat details as unconfirmed.**

The page's own original stamp line (what the content was actually
verified against) is NEVER edited or removed — that would be a claim that
someone re-verified the content, which this script cannot know (Law 2 of
docs/designs/THE_WHOLE.md: era truth is sourced, never typed). Only the
"the live game is ..." clause is written by this script, and it always
derives both halves of the banner fresh from (1) the page's own untouched
stamp and (2) docs/wiki/_era.md — never from a cached copy of either.

Two write modes:

- Default (no `--reband`): additive-only, matching the original behavior.
  Once a banner exists, it is left alone forever even if the era moves on
  again — reported as `stale-already-banded`.
- `--reband`: replaces an existing-but-outdated banner's "the live game
  is ..." clause with the current era, in place. The "Verified against"
  clause is recomputed from the page's own (untouched) first line every
  time, so it is byte-identical before and after a reband. A banner that
  already names the current era is left untouched (idempotent).

A banner can also become entirely obsolete: if a page's own stamp is
brought up to the live era (a content re-trace) while a banner from its
stale window is still sitting there, that banner no longer belongs on the
page at all — regardless of what its own "the live game is" clause says
(that clause is never trusted for this decision; the page's own stamp is
the only source of truth, per Law 2 above). `--check` reports this as
`stale-banner` (a failure, same severity as `stale`); `--reband` removes
the banner line and the blank line its insertion added, restoring the
page byte-for-byte to what it looked like before the banner ever existed
(reported as `banner-removed`). Without `--reband`, such a banner is left
alone, same as `stale-already-banded`.

Usage:
    python3 tools/wiki/render_era_banner.py [--wiki-dir docs/wiki] [--check] [--reband]

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

# A banner line this script itself wrote, in either the plain or reband
# form. Group 1/2 = the "Verified against" clause (derived from the
# page's own stamp); group 3/4 = the "live game is" clause (derived from
# _era.md at write time).
BANNER_LINE_RE = re.compile(
    r"^\*\*Verified against `GV(\d+) / Glory (\d+)` — "
    + re.escape(STALE_MARKER)
    + r" `GV(\d+) / GLORYVERSION (\d+)`; treat details as unconfirmed\.\*\*\s*$"
)

# How many lines after the page's own stamp line to scan for an existing
# banner. The banner is always inserted immediately (blank line + banner)
# after the stamp line, so 6 lines of slack comfortably covers drift.
BANNER_SEARCH_WINDOW = 6

# How many leading lines to scan for the page's own stamp line. Most pages
# open with the stamp on line 0, but some (e.g. the live achievements/deeds
# pages) open with an H1 title first. A small window lets us find the
# stamp after a title without risking a false match deep in prose.
STAMP_SEARCH_WINDOW = 4

HEADING_RE = re.compile(r"^#{1,6}\s")

# Slugs this script never touches: dated, point-in-time log pages. Per
# docs/wiki/AUDIT.md, the changelog family ("changelog" plus one
# "changelog-YYYY-MM-DD" per day something shipped) is "not stale by
# definition" — each entry is a snapshot of what was true on its own date,
# not a living reference page, so stamping it "verified against ... the
# live game is GV63" would misrepresent an immutable historical record as
# something needing re-verification. reband_live.py checks this before
# calling reband_text at all. `patch-notes` joins this set for the same
# reason: it is structurally a changelog (versioned tables, newest first,
# keyed by build/GV/Glory), not a living reference page a reader checks
# against the current era.
DATED_LOG_SLUG_RE = re.compile(r"^(changelog(-\d{4}-\d{2}-\d{2})?|patch-notes)$")


def is_dated_log_slug(slug: str) -> bool:
    return bool(DATED_LOG_SLUG_RE.match(slug))


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


def build_banner(page_gv: int, page_glory: int, era_gv: int, era_glory: int) -> str:
    return (
        f"**Verified against `GV{page_gv} / Glory {page_glory}` — "
        f"{STALE_MARKER} `GV{era_gv} / GLORYVERSION {era_glory}`; "
        f"treat details as unconfirmed.**\n"
    )


def find_stamp_line(lines: list[str]) -> int | None:
    """Return the index of the page's own "Verified against ..." stamp
    line, or None if it can't be found safely.

    Usually line 0. Some pages open with an H1 title (and/or a blank line)
    before the stamp; those are skipped over. Any other non-blank,
    non-heading line encountered before a stamp is found means the page's
    structure isn't one this script recognizes, so it bails out (returns
    None) rather than guessing — safer to leave a page unparsed than to
    band the wrong line.
    """
    for i in range(min(STAMP_SEARCH_WINDOW, len(lines))):
        line = lines[i]
        if extract_stamp(line) is not None:
            return i
        stripped = line.strip()
        if stripped == "" or HEADING_RE.match(stripped):
            continue
        return None
    return None


def find_banner_line(lines: list[str], after: int = 0) -> int | None:
    """Return the index of an existing banner line in `lines`, or None.

    Scans the BANNER_SEARCH_WINDOW lines immediately after index `after`
    (the page's own stamp line)."""
    window = lines[after + 1 : after + 1 + BANNER_SEARCH_WINDOW]
    for offset, line in enumerate(window, start=after + 1):
        if BANNER_LINE_RE.match(line.strip()):
            return offset
    return None


def reband_text(
    text: str, era_gv: int, era_glory: int, reband: bool, slug: str | None = None
) -> tuple[str, str]:
    """Compute the (possibly) re-banded text for one page.

    `slug` is the page's slug (its filename stem, e.g. "changelog-2026-09-04"
    for docs/wiki/changelog-2026-09-04.md). When given and
    `is_dated_log_slug(slug)` is true, the text is returned completely
    untouched — dated, point-in-time log pages are never banner-stamped
    (see DATED_LOG_SLUG_RE's docstring). This mirrors the check
    reband_live.py's process_one() makes before ever calling this function,
    so the two scripts agree on the exemption regardless of call site —
    this local script previously lacked the check and would incorrectly
    stamp changelog-YYYY-MM-DD pages that happen to have a parseable
    "Verified against ..." first line.

    Returns (new_text, status), where status is one of:
      'current'               — already correct, nothing to do
      'stale'                 — no banner existed yet; one was added
      'stale-already-banded'  — a banner exists and names an old era, but
                                 `reband` is False so it is left alone
                                 (legacy/default behavior)
      'rebanded'               — a banner existed, named an old era, and
                                 `reband` is True so it was replaced
      'stale-banner'           — the page's own stamp is now current (>=
                                 the live era), but a banner from when it
                                 was stale is still sitting there. This
                                 outranks whatever the banner's own "the
                                 live game is" clause says (that clause is
                                 not trusted for this decision — a page's
                                 own re-verified stamp is the only source
                                 of truth). `reband` is False so nothing is
                                 written; a `--check` run must still treat
                                 this as a failure.
      'banner-removed'         — same detection as 'stale-banner', but
                                 `reband` is True so the obsolete banner
                                 (and the blank line its insertion added)
                                 was removed, restoring the page to
                                 exactly what it looked like before the
                                 banner was ever added.
      'unparsed'               — no recognizable "Verified against ..."
                                 stamp found near the top; never touched
      'exempt-dated-log'       — `slug` matches DATED_LOG_SLUG_RE; never
                                 touched, regardless of its own stamp
    """
    if slug is not None and is_dated_log_slug(slug):
        # A page can arrive here already carrying a banner from before it
        # was exempted (patch-notes.md did, at GV24/Glory12 vs GV63). An
        # exempt page should never carry one going forward, so strip it on
        # sight rather than leaving it stuck there forever — this reuses
        # the same "banner-removed" status and removal shape (banner line
        # plus the blank line before it) as the current-stamp case below.
        lines = text.splitlines(keepends=True)
        stamp_idx = find_stamp_line(lines) if lines else None
        banner_idx = (
            find_banner_line(lines, after=stamp_idx) if stamp_idx is not None else None
        )
        if banner_idx is not None:
            new_lines = list(lines)
            remove_from = banner_idx
            if banner_idx == stamp_idx + 2 and lines[stamp_idx + 1].strip() == "":
                remove_from = stamp_idx + 1
            del new_lines[remove_from : banner_idx + 1]
            return "".join(new_lines), "banner-removed"
        return text, "exempt-dated-log"

    lines = text.splitlines(keepends=True)
    if not lines:
        return text, "unparsed"
    stamp_idx = find_stamp_line(lines)
    if stamp_idx is None:
        return text, "unparsed"
    page_gv, page_glory = extract_stamp(lines[stamp_idx])
    page_is_current = page_gv >= era_gv and page_glory >= era_glory

    banner_idx = find_banner_line(lines, after=stamp_idx)

    if banner_idx is None:
        if page_is_current:
            return text, "current"
        banner = build_banner(page_gv, page_glory, era_gv, era_glory)
        # Blank line before the banner so it renders as its own paragraph,
        # distinct from the page's own stamp line above it.
        new_lines = lines[: stamp_idx + 1] + ["\n", banner] + lines[stamp_idx + 1 :]
        return "".join(new_lines), "stale"

    if page_is_current:
        # The page's own stamp has caught up to the live era (typically a
        # content re-trace), but a banner inserted while it was stale is
        # still here. It is obsolete regardless of what its own "the live
        # game is" clause claims — a tampered or stale banner clause must
        # never override the page's own (untouched) stamp, which is the
        # only trusted source. Remove it, mirroring exactly how it was
        # inserted (a blank line, then the banner line, immediately after
        # the stamp) so the page returns byte-for-byte to what it looked
        # like before the banner was ever added.
        if not reband:
            return text, "stale-banner"
        new_lines = list(lines)
        remove_from = banner_idx
        if banner_idx == stamp_idx + 2 and lines[stamp_idx + 1].strip() == "":
            remove_from = stamp_idx + 1
        del new_lines[remove_from : banner_idx + 1]
        return "".join(new_lines), "banner-removed"

    m = BANNER_LINE_RE.match(lines[banner_idx].strip())
    assert m is not None  # find_banner_line only returns matching indices
    banner_era_gv, banner_era_glory = int(m.group(3)), int(m.group(4))
    if banner_era_gv >= era_gv and banner_era_glory >= era_glory:
        return text, "current"

    if not reband:
        return text, "stale-already-banded"

    # Recompute the banner fresh from the page's own (untouched) stamp and
    # the current era — the "Verified against" clause is therefore always
    # byte-identical to what was there before; only "the live game is"
    # clause changes.
    new_banner = build_banner(page_gv, page_glory, era_gv, era_glory)
    new_lines = list(lines)
    new_lines[banner_idx] = new_banner
    return "".join(new_lines), "rebanded"


def process_page(
    path: Path, era_gv: int, era_glory: int, write: bool, reband: bool
) -> str:
    text = path.read_text()
    new_text, status = reband_text(text, era_gv, era_glory, reband, slug=path.stem)
    if write and status in ("stale", "rebanded", "banner-removed"):
        path.write_text(new_text)
    return status


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wiki-dir", default="docs/wiki")
    ap.add_argument(
        "--check",
        action="store_true",
        help="report only, exit 1 if any page is stale-but-unbanded",
    )
    ap.add_argument(
        "--reband",
        action="store_true",
        help=(
            "replace an existing-but-outdated banner's 'the live game is' "
            "clause with the current era, instead of leaving it alone"
        ),
    )
    args = ap.parse_args()

    wiki_dir = Path(args.wiki_dir)
    era_path = wiki_dir / "_era.md"
    era_gv, era_glory = parse_era(era_path)

    results: dict[str, list[str]] = {
        "current": [],
        "stale": [],
        "stale-already-banded": [],
        "rebanded": [],
        "stale-banner": [],
        "banner-removed": [],
        "unparsed": [],
        "exempt-dated-log": [],
    }

    pages = sorted(
        p
        for p in wiki_dir.glob("*.md")
        if p.name not in NON_PAGE_FILES and not p.name.startswith("_")
    )

    for page in pages:
        status = process_page(
            page, era_gv, era_glory, write=not args.check, reband=args.reband
        )
        results[status].append(page.name)

    total = len(pages)
    print(f"era: GV{era_gv} / GLORYVERSION {era_glory}  ({era_path})")
    print(f"pages scanned: {total}")
    print(f"  current (no banner needed): {len(results['current'])} — {results['current']}")
    print(
        f"  stale, banner {'inserted' if not args.check else 'needed'}: "
        f"{len(results['stale'])} — {results['stale']}"
    )
    print(
        f"  stale, banner already present (left alone; pass --reband to update it): "
        f"{len(results['stale-already-banded'])} — {results['stale-already-banded']}"
    )
    print(
        f"  rebanded (existing banner's era updated): {len(results['rebanded'])} "
        f"— {results['rebanded']}"
    )
    print(
        f"  stale-banner (remove) — own stamp is current, obsolete banner "
        f"left alone (pass --reband to remove it): "
        f"{len(results['stale-banner'])} — {results['stale-banner']}"
    )
    print(
        f"  banner-removed (own stamp caught up, obsolete banner deleted): "
        f"{len(results['banner-removed'])} — {results['banner-removed']}"
    )
    print(f"  unparsed (no recognizable stamp, skipped): {len(results['unparsed'])} — {results['unparsed']}")
    print(
        f"  exempt (dated changelog log page, never banded): "
        f"{len(results['exempt-dated-log'])} — {results['exempt-dated-log']}"
    )

    if args.check and (
        results["stale"]
        or results["stale-already-banded"]
        or results["rebanded"]
        or results["stale-banner"]
        or results["banner-removed"]
    ):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
