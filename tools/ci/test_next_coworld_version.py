#!/usr/bin/env python3
"""Fixture tests for the next_coworld_version picker (stdlib only, no network).

Run from anywhere: python3 tools/ci/test_next_coworld_version.py
The upload workflow runs this before every version computation.
"""

import io
import json
import sys
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import next_coworld_version as picker  # noqa: E402

compute_next = picker.compute_next


def row(name, version, canonical=False, rid="cow_test"):
    return {"id": rid, "name": name, "version": version, "canonical": canonical}


def expect_exit(fn, fragment):
    try:
        fn()
    except SystemExit as e:
        msg = str(e)
        assert fragment in msg, f"expected {fragment!r} in error, got: {msg}"
        return
    raise AssertionError(f"expected SystemExit containing {fragment!r}, none raised")


class FakeResponse(io.BytesIO):
    def __init__(self, rows, cursor=None):
        super().__init__(json.dumps(rows).encode())
        self.headers = {} if cursor is None else {"x-next-cursor": cursor}

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


def test_fetches_summary_projection_with_cursor_paging():
    first_page = [
        row("other", f"1.0.{i}", rid=f"cow_{i}") for i in range(picker.PAGE_SIZE)
    ]
    second_page = [
        first_page[-1],
        row("paintbot", "0.7.413", canonical=True, rid="cow_target"),
    ]
    responses = [FakeResponse(first_page, "after/500+rows"), FakeResponse(second_page)]
    requests = []

    def fake_urlopen(req, timeout):
        requests.append((req, timeout))
        return responses.pop(0)

    with mock.patch.object(picker.urllib.request, "urlopen", side_effect=fake_urlopen):
        rows = picker.fetch_all_rows("test-token")

    assert len(rows) == picker.PAGE_SIZE + 1
    assert [request.full_url for request, _timeout in requests] == [
        f"{picker.BASE}/v2/coworlds/summaries?limit={picker.PAGE_SIZE}",
        f"{picker.BASE}/v2/coworlds/summaries?limit={picker.PAGE_SIZE}&cursor=after%2F500%2Brows",
    ]
    assert all(timeout == 60 for _request, timeout in requests)
    assert all(
        request.get_header("User-agent") == "coworld-ctf-ci/next_coworld_version"
        for request, _ in requests
    )


test_fetches_summary_projection_with_cursor_paging()


# THE defect scenario (2026-07-30/31 wedge): canonical 0.7.127, orphan
# NON-canonical 0.7.128 above it. canonical-based picker returns 0.7.128
# and 409s forever; this picker must return 0.7.129.
orphan_rows = [
    row("ctf", "0.7.128", canonical=False),  # the orphan (newest-first)
    row("ctf", "0.7.127", canonical=True),
    row("ctf", "0.7.126", canonical=False),
    row("paintbot", "0.7.138", canonical=True),
]
assert compute_next(orphan_rows, "ctf") == "0.7.129"

# Clean registry: max row IS the canonical -> plain patch bump.
assert compute_next(orphan_rows, "paintbot") == "0.7.139"

# Numeric (not lexicographic) ordering: 0.7.9 < 0.7.10 < 0.7.100.
numeric_rows = [
    row("ctf", "0.7.9", canonical=True),
    row("ctf", "0.7.100", canonical=False),
    row("ctf", "0.7.10", canonical=False),
]
assert compute_next(numeric_rows, "ctf") == "0.7.101"

# Other names never leak into the computation.
mixed = orphan_rows + [row("speedrun-wow", "9.9.9", canonical=True)]
assert compute_next(mixed, "ctf") == "0.7.129"

# Under-read guards: a fetch that misses the canonical row must hard-fail,
# never emit a number that can re-collide.
expect_exit(lambda: compute_next([row("ctf", "0.7.5")], "ctf"), "no canonical row")

# A fully fetched registry with no rows for a new name starts its own sequence.
assert compute_next([], "paintbot-profiling") == "0.1.0"
assert compute_next(orphan_rows, "paintbot-profiling") == "0.1.0"

# Unparseable version for our name is a hard failure, not a silent skip —
# a skipped max row would re-collide.
expect_exit(
    lambda: compute_next(
        [row("ctf", "0.7.x"), row("ctf", "0.7.1", canonical=True)], "ctf"
    ),
    "non-semver",
)

print("test_next_coworld_version: all assertions passed")
