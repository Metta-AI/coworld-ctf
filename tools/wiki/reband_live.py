#!/usr/bin/env python3
"""Re-band every LIVE wiki page's era banner, and optionally mirror
live-only pages (no docs/wiki/<slug>.md yet) into the repo.

Companion to render_era_banner.py (which only touches the local
docs/wiki/*.md mirrors). This script talks to the real wiki API:

    GET  https://softmax.com/api/observatory/v2/wikis/paintbot/pages
    GET  https://softmax.com/api/observatory/v2/wikis/paintbot/pages/<slug>
    PUT  https://softmax.com/api/observatory/v2/wikis/paintbot/pages/<slug>

curl only — plain Python `urllib`/`requests` gets a Cloudflare 403 against
this API (see docs/wiki/PUBLISH.md's mechanism note). Token is read from
~/.softmax/credentials.yaml and used only inside the Authorization header;
it is never printed or logged.

For every live page, in slug order:
  1. GET the page.
  2. Bank the untouched "before" body to /tmp/wiki-reband/<slug>.before.md.
  3. Compute the re-banded body with render_era_banner.reband_text(...,
     reband=True) — same logic, same tests, as the local-mirror script.
  4. If the body changed and --apply is passed: PUT the new body (using
     the revision_id from step 1 as base_revision_id — fetch-edit-put, not
     a canned diff, per docs/wiki/conventions.md's "merge, don't clobber"
     rule), then GET again and assert the diff between before and after is
     confined to the banner line(s) (a blank+banner insertion, a single
     banner-line replacement, or a blank+banner removal once the page's own
     stamp is current) — never any other content. If that assertion
     fails, or the PUT itself fails, the banked before-body is PUT back
     immediately and the page is reported as "restored", never left
     half-written.
  5. If --mirror-missing is passed: for any slug with no docs/wiki/<slug>.md
     in the repo, write the page's final (re-banded) body there, so every
     live page ends up with a repo mirror.

Without --apply this is a dry run: it reports what WOULD happen (GETs
only, no writes to the live wiki). Local mirror files ARE still written by
--mirror-missing regardless of --apply, since that's a repo-local write,
not a live one — but it always mirrors the final *computed* body (the
already re-banded text), so the repo copy is correct even before a
separate --apply pass lands the same text live.

Usage:
    python3 tools/wiki/reband_live.py                       # dry run, all 44
    python3 tools/wiki/reband_live.py --apply                # write live
    python3 tools/wiki/reband_live.py --apply --mirror-missing
    python3 tools/wiki/reband_live.py --slugs glory,elo       # subset, for spot checks
"""

from __future__ import annotations

import argparse
import difflib
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_era_banner as reb  # noqa: E402

API_BASE = "https://softmax.com/api/observatory/v2/wikis/paintbot/pages"
BANK_DIR = Path("/tmp/wiki-reband")
PUT_SLEEP_S = 2.2  # convention from docs/wiki/PUBLISH.md: 30 revisions / 60s
REPO_ROOT = Path(__file__).resolve().parents[2]
WIKI_DIR = REPO_ROOT / "docs" / "wiki"


def load_token() -> str:
    import yaml

    creds_path = Path.home() / ".softmax" / "credentials.yaml"
    d = yaml.safe_load(creds_path.read_text())
    return d["tokens"]["https://softmax.com/api"]


def curl_get(token: str, slug: str) -> tuple[int, dict | None]:
    proc = subprocess.run(
        [
            "curl",
            "-s",
            "-w",
            "\n%{http_code}",
            "-H",
            f"Authorization: Bearer {token}",
            f"{API_BASE}/{slug}",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    text = proc.stdout
    body_text, _, code_text = text.rpartition("\n")
    try:
        code = int(code_text)
    except ValueError:
        code = -1
    try:
        data = json.loads(body_text) if body_text.strip() else None
    except json.JSONDecodeError:
        data = None
    return code, data


def curl_put(token: str, slug: str, payload: dict) -> tuple[int, dict | None]:
    payload_path = BANK_DIR / f"{slug}.put-payload.json"
    payload_path.write_text(json.dumps(payload))
    proc = subprocess.run(
        [
            "curl",
            "-s",
            "-w",
            "\n%{http_code}",
            "-X",
            "PUT",
            "-H",
            f"Authorization: Bearer {token}",
            "-H",
            "Content-Type: application/json",
            "--data",
            f"@{payload_path}",
            f"{API_BASE}/{slug}",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    payload_path.unlink(missing_ok=True)
    text = proc.stdout
    body_text, _, code_text = text.rpartition("\n")
    try:
        code = int(code_text)
    except ValueError:
        code = -1
    try:
        data = json.loads(body_text) if body_text.strip() else None
    except json.JSONDecodeError:
        data = None
    return code, data


def banner_only_diff(old_text: str, new_text: str) -> tuple[bool, int]:
    """Return (confined_to_banner, changed_line_count).

    confined_to_banner is True iff every added/removed line is either
    blank or matches render_era_banner.BANNER_LINE_RE — i.e. the only
    difference between old_text and new_text is the banner.
    """
    old_lines = old_text.splitlines()
    new_lines = new_text.splitlines()
    sm = difflib.SequenceMatcher(a=old_lines, b=new_lines)
    changed = 0
    ok = True
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        changed += max(i2 - i1, j2 - j1)
        for line in old_lines[i1:i2] + new_lines[j1:j2]:
            if line.strip() == "":
                continue
            if not reb.BANNER_LINE_RE.match(line.strip()):
                ok = False
    return ok, changed


def describe_stamp(stamp: tuple[int, int] | None) -> str:
    if stamp is None:
        return "unparsed"
    return f"GV{stamp[0]}/Glory{stamp[1]}"


def process_one(
    token: str, slug: str, era_gv: int, era_glory: int, apply: bool
) -> dict:
    row: dict = {"slug": slug}

    code, data = curl_get(token, slug)
    row["get_code"] = code
    if code != 200 or data is None:
        row["result"] = "get-failed"
        return row

    title = data["title"]
    revision_id = data["current_revision_id"]
    body = data["current_revision"]["body"]
    row["title"] = title

    before_path = BANK_DIR / f"{slug}.before.md"
    before_path.write_text(body)

    if reb.is_dated_log_slug(slug):
        # Point-in-time log entries (changelog family) are never banded —
        # see render_era_banner.DATED_LOG_SLUG_RE's docstring.
        row["before_stamp"] = "n/a (dated log)"
        row["before_banner_era"] = "n/a (dated log)"
        row["status"] = "exempt-dated-log"
        row["final_body"] = body
        row["result"] = "exempt-dated-log"
        return row

    lines = body.splitlines(keepends=True) if body else []
    stamp_idx = reb.find_stamp_line(lines) if lines else None
    own_stamp = reb.extract_stamp(lines[stamp_idx]) if stamp_idx is not None else None
    row["before_stamp"] = describe_stamp(own_stamp)

    existing_banner_idx = (
        reb.find_banner_line(lines, after=stamp_idx) if stamp_idx is not None else None
    )
    if existing_banner_idx is not None:
        m = reb.BANNER_LINE_RE.match(lines[existing_banner_idx].strip())
        row["before_banner_era"] = f"GV{m.group(3)}/Glory{m.group(4)}"
    else:
        row["before_banner_era"] = "none"

    new_body, status = reb.reband_text(body, era_gv, era_glory, reband=True, slug=slug)
    row["status"] = status
    row["final_body"] = new_body  # used by --mirror-missing regardless of apply

    if status not in ("stale", "rebanded", "banner-removed"):
        row["result"] = "unchanged" if status != "unparsed" else "skipped-unparsed"
        return row

    if not apply:
        row["result"] = "would-change"
        return row

    put_code, put_resp = curl_put(
        token,
        slug,
        {
            "title": title,
            "body": new_body,
            "base_revision_id": revision_id,
            "idempotency_key": f"{slug}-reband-{int(time.time())}",
        },
    )
    row["put_code"] = put_code
    time.sleep(PUT_SLEEP_S)

    put_ok = put_code in (200, 201)

    if not put_ok:
        # The PUT itself was rejected (e.g. a stale base_revision_id because
        # another agent edited this page concurrently). Nothing was written
        # by us, so there is nothing to restore — restoring here would risk
        # clobbering that other, legitimate concurrent edit. Just report and
        # move on; a re-run picks up the page's now-current state fresh.
        row["result"] = "put-rejected"
        return row

    verify_code, verify_data = curl_get(token, slug)
    row["verify_get_code"] = verify_code
    after_body = (verify_data or {}).get("current_revision", {}).get("body", "") if verify_data else ""

    confined, diff_lines = banner_only_diff(body, after_body)
    row["diff_lines"] = diff_lines

    if verify_code == 200 and confined and after_body == new_body:
        row["result"] = "changed"
    else:
        # Our own PUT landed but produced something unexpected (server-side
        # mangling, or the diff wasn't confined to the banner). This is OUR
        # write behaving badly, so restore is the right call: put the
        # banked before-body back, based on the revision we just created.
        restore_code, _ = curl_put(
            token,
            slug,
            {
                "title": title,
                "body": body,
                "base_revision_id": (verify_data or {}).get("current_revision_id", revision_id),
                "idempotency_key": f"{slug}-reband-restore-{int(time.time())}",
            },
        )
        time.sleep(PUT_SLEEP_S)
        restore_verify_code, restore_verify_data = curl_get(token, slug)
        restored_body = (restore_verify_data or {}).get("current_revision", {}).get("body", "")
        row["restore_put_code"] = restore_code
        row["restore_verify_code"] = restore_verify_code
        row["result"] = "restored" if restored_body == body else "RESTORE-FAILED"

    return row


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="write to the live wiki (default: dry run)")
    ap.add_argument(
        "--mirror-missing",
        action="store_true",
        help="write a docs/wiki/<slug>.md mirror for any live page that doesn't have one",
    )
    ap.add_argument("--slugs", default=None, help="comma-separated subset of slugs (default: all live pages)")
    args = ap.parse_args()

    BANK_DIR.mkdir(parents=True, exist_ok=True)
    token = load_token()
    era_gv, era_glory = reb.parse_era(WIKI_DIR / "_era.md")

    if args.slugs:
        slugs = [s.strip() for s in args.slugs.split(",") if s.strip()]
    else:
        proc = subprocess.run(
            ["curl", "-s", "-H", f"Authorization: Bearer {token}", API_BASE],
            capture_output=True,
            text=True,
            timeout=30,
        )
        listing = json.loads(proc.stdout)
        slugs = sorted(e["slug"] for e in listing["entries"])

    print(f"era: GV{era_gv} / GLORYVERSION {era_glory}")
    print(f"pages: {len(slugs)}  mode: {'APPLY' if args.apply else 'DRY RUN'}")
    print()

    rows = []
    for slug in slugs:
        row = process_one(token, slug, era_gv, era_glory, apply=args.apply)
        rows.append(row)
        print(
            f"{row['slug']:24s} before={row.get('before_stamp','?'):16s} "
            f"banner-before={row.get('before_banner_era','?'):16s} "
            f"status={row.get('status','?'):8s} result={row['result']:16s} "
            f"get={row.get('get_code','-')} put={row.get('put_code','-')} "
            f"verify={row.get('verify_get_code','-')} diff_lines={row.get('diff_lines','-')}"
        )

    print()
    from collections import Counter

    by_before = Counter(r.get("before_stamp", "?") for r in rows)
    by_result = Counter(r["result"] for r in rows)
    print("count per before-era:", dict(by_before))
    print("count per result:", dict(by_result))

    if args.mirror_missing:
        print()
        print("mirroring live-only pages into docs/wiki/ ...")
        mirrored = []
        for row in rows:
            slug = row["slug"]
            if "final_body" not in row:
                continue
            local_path = WIKI_DIR / f"{slug}.md"
            if local_path.exists():
                continue
            local_path.write_text(row["final_body"])
            mirrored.append(slug)
            print(f"  mirrored: {slug} -> {local_path.relative_to(REPO_ROOT)}")
        print(f"newly mirrored: {len(mirrored)} — {mirrored}")

    restored = [r["slug"] for r in rows if r["result"] == "restored"]
    failed_restore = [r["slug"] for r in rows if r["result"] == "RESTORE-FAILED"]
    if failed_restore:
        print(f"\n!!! RESTORE FAILED for: {failed_restore} — manual intervention needed", file=sys.stderr)
        return 2
    if restored:
        print(f"\nrestored (PUT verification failed, reverted to banked before-body): {restored}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
