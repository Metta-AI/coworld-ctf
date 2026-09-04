#!/usr/bin/env python3
"""Compute the next coworld publish version from the registry's highest existing row.

Usage: next_coworld_version.py <coworld-name>
Env:   SOFTMAX_TOKEN (Bearer token for the registry API)

Why this exists (2026-07-31): `coworld next-version <name>` is CANONICAL-based.
A partially-failed publish (row uploaded, certification/canonicalize failed)
leaves an orphan NON-canonical row above the canonical one, and every
subsequent publish then recomputes the same taken number and dies with
"409: already exists" until someone clears the orphan. Seven consecutive
publishes failed overnight 2026-07-30/31 on orphan ctf:0.7.128 this way.
This picker takes max(existing rows for <name>) + 1 patch instead, so an
orphan row advances the counter rather than wedging it.

Known trade (accepted by the operator, decision 1217042089600759): a failed
certification now burns a version number, i.e. MORE orphan rows over time.
That is fine — rows are cheap, wedges are not. NOTE for readers: a publish
is NOT a seat; the league era oracle is rounds / league.game.coworld_id,
never "the newest registry row" (the fleet once mislabelled 0.7.125/0.7.126
as live this way).

Registry API facts this code is built on (verified 2026-09-03):
  - GET /v2/coworlds returns a bare JSON list, newest-first (created_at desc).
  - `limit` hard-caps at 500 (501 -> HTTP 422); the registry holds more than
    500 rows, so a single page silently under-reads.
  - `?name=` is IGNORED by the server; filter client-side.
  - Pagination is KEYSET/CURSOR, not offset. `?offset=` / `?page=` / `?skip=`
    are all SILENTLY IGNORED and re-return page 0. To page, read the
    `x-next-cursor` RESPONSE HEADER and pass it back as `?cursor=<token>`;
    the last page omits the header. (The server migrated off `?offset=`
    between uploads #392 and #393 on 2026-09-03: offset paging then looped
    on the newest 500 rows forever and tripped the MAX_PAGES guard — an
    upload-CI outage. Do NOT reintroduce offset paging.)
"""

import json
import os
import re
import sys
import urllib.parse
import urllib.request

BASE = os.environ.get("SOFTMAX_API_BASE", "https://softmax.com/api/observatory")
PAGE_SIZE = 500  # server-side hard cap
MAX_PAGES = 200  # safety stop; 200 * 500 = 100k rows before this trips
SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def fetch_all_rows(token):
    """Walk the whole registry via keyset/cursor paging (see module docstring).

    Follows the `x-next-cursor` response header; terminates when the server
    omits it (last page) or a short page comes back. MAX_PAGES stays a safety
    stop against a pathological cursor loop, and we additionally refuse to
    advance on a cursor that fails to yield any new rows — the guard that
    would have caught the offset->cursor migration instead of masking it.
    """
    rows = []
    seen_ids = set()
    cursor = None
    for _ in range(MAX_PAGES):
        url = f"{BASE}/v2/coworlds?limit={PAGE_SIZE}"
        if cursor:
            url += f"&cursor={urllib.parse.quote(cursor, safe='')}"
        req = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                # The site's edge blocks python's default "Python-urllib/x.y"
                # User-Agent with a 403 (verified 2026-07-31); any explicit UA passes.
                "User-Agent": "coworld-ctf-ci/next_coworld_version",
            },
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            cursor = resp.headers.get("x-next-cursor")
            batch = json.load(resp)
        if not isinstance(batch, list):
            raise SystemExit(f"unexpected response shape from {url}: {type(batch)}")
        new = [r for r in batch if r.get("id") not in seen_ids]
        seen_ids.update(r.get("id") for r in batch)
        rows.extend(new)
        # Paging broke (e.g. server ignoring the cursor and re-serving a page):
        # a full batch that adds nothing new means we are not advancing. Fail
        # loudly rather than silently loop or under-read.
        if batch and not new:
            raise SystemExit(
                "registry cursor did not advance (page re-served with no new rows); "
                "the pagination contract likely changed again — refusing to guess"
            )
        if len(batch) < PAGE_SIZE or not cursor:
            return rows
    raise SystemExit(f"registry did not terminate within {MAX_PAGES} pages; refusing to guess")


def parse_version(row):
    m = SEMVER_RE.match(row.get("version") or "")
    if not m:
        # Never skip silently: an unparseable row for our name could be the max.
        raise SystemExit(
            f"row {row.get('id')} for {row.get('name')} has non-semver version "
            f"{row.get('version')!r}; refusing to compute a next version past it"
        )
    return tuple(int(g) for g in m.groups())


def compute_next(rows, name):
    """Return next version string for <name>: highest existing row, patch + 1.

    Hard-fails unless the fetched set contains <name>'s canonical row and the
    max row is >= it — the guard against a truncated/under-read fetch
    re-colliding with an existing number.
    """
    mine = [r for r in rows if r.get("name") == name]
    if not mine:
        raise SystemExit(f"no rows for coworld {name!r} in {len(rows)} fetched rows")
    versions = [(parse_version(r), r) for r in mine]
    max_ver, max_row = max(versions, key=lambda vr: vr[0])
    canonical = [v for v, r in versions if r.get("canonical")]
    if not canonical:
        raise SystemExit(
            f"no canonical row for {name!r} among {len(mine)} fetched rows; "
            "fetch likely truncated — refusing to pick a version"
        )
    if max_ver < max(canonical):
        raise SystemExit(
            f"max fetched row {max_ver} < canonical {max(canonical)} for {name!r}; "
            "fetch under-read — refusing to pick a version"
        )
    nxt = f"{max_ver[0]}.{max_ver[1]}.{max_ver[2] + 1}"
    print(
        f"{name}: {len(mine)} rows, max existing {max_row.get('version')} "
        f"(canonical: {max_row.get('canonical')}), next -> {nxt}",
        file=sys.stderr,
    )
    return nxt


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <coworld-name>")
    token = os.environ.get("SOFTMAX_TOKEN")
    if not token:
        raise SystemExit("SOFTMAX_TOKEN is not set")
    rows = fetch_all_rows(token)
    print(f"fetched {len(rows)} registry rows", file=sys.stderr)
    print(compute_next(rows, sys.argv[1]))


if __name__ == "__main__":
    main()
