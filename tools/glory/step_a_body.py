#!/usr/bin/env python3
"""GLORY GRADIENT Step A/B POST body builder -- read-only, MECHANICAL, never sends.

Builds the exact request bodies for the (not-yet-sent) full-replace
``POST /leagues/{league_id}/settings`` writes that arm ``season_leg_transform``
(Step A) and retune ``rated_k`` (Step B), per
``~/.ctf/knowledge/glory-gradient/00q-post-body-spec-2026-09-09.md``.

THIS SCRIPT NEVER SENDS A POST. It only GETs the live settings (the same
COMMISSIONER_OR_SUBMITTER_AUTH surface, plain bearer, that step_a_read.py
already uses) and writes JSON files to disk.

Why this exists (the hazard the spec calls out): the endpoint is a FULL
REPLACE -- ``leagues.py:3203-3204`` does
``stored = request.model_dump(mode="json", exclude_none=True); league.settings
= stored or None`` -- so any top-level block or nested field the POST body
omits (or supplies as JSON ``null``) is silently dropped from the whole
``leagues.settings`` row, not merged. The only safe construction is: GET the
live settings, take the ``.settings`` object VERBATIM, and change only the
intended leaf(s).

Method, mechanically:
  1. GET /leagues/{league_id}/settings. The response is an ENVELOPE
     (``LeagueSettingsResponse``: ``settings``, ``defaults``,
     ``effective_ladder_config``, ``commissioner_key``, ``warnings``,
     ``results_schema`` -- leagues.py:474-488). Only ``response["settings"]``
     is POST-shaped; the other keys are response-only computed/administrative
     fields and would 422 via ``unknown_key_paths`` if echoed into the
     request. This script extracts ``settings`` and discards the rest (never
     echoes the envelope).
  2. Deepcopy that ``settings`` object twice: once for the Step A body (one
     leaf changed: ``ladder.ranking.season_leg_transform``), once for the
     Step B body (that same leaf, PLUS ``ladder.ranking.rated_k``).
  3. Recursively diff each constructed body against the live baseline. Every
     changed JSON path is reported before/after. The script asserts A has
     EXACTLY ONE changed path and B has EXACTLY TWO -- any more (or fewer)
     means the echo was not byte-for-byte and the script fails loudly instead
     of writing a body file.
  4. exclude_none hazard gate (owner refinement, 2026-09-09): recursively
     collect every JSON path in the live settings document whose value is
     already ``None`` -- these are HARMLESS to round-trip as explicit
     ``null`` (exclude_none drops them either way; they carry no data today).
     Separately compute ``null_paths(body) - null_paths(live)``: any path
     that is null in the constructed body but was NOT null live is a field
     that HELD A VALUE live and would be WIPED by the echo -- a BLOCKER. Since
     this script only ever deepcopies the live document and changes leaf
     VALUES (never sets anything to None), this set is provably empty by
     construction; the check exists as a live runtime gate against a future
     bug in this script (or a schema change), not a speculative worry.  If it
     is ever non-empty, the script does NOT write the normal
     ``00q-step-a-body-<ts>.json`` -- it writes
     ``00q-step-a-body-<ts>-BLOCKED.json`` instead, names the wiped field(s),
     and exits non-zero. Nothing is ever sent regardless.

Usage:
    python3 tools/glory/step_a_body.py
"""
from __future__ import annotations

import copy
import json
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import step_a_read as sar  # noqa: E402  (local module, same dir)

OUT_DIR_DEFAULT = sar.OUT_DIR_DEFAULT
LEAGUE_ID = sar.LEAGUE_ID

STEP_A_PATH = "ladder.ranking.season_leg_transform"
STEP_A_OLD = "none"
STEP_A_NEW = "signed_log2"
STEP_B_PATH = "ladder.ranking.rated_k"
STEP_B_OLD = 0.05
STEP_B_NEW = 0.025


class BuildError(RuntimeError):
    """Raised to fail loudly; caught only at main() to print + exit non-zero."""


def get_by_path(doc: dict, dotted: str):
    cur = doc
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None, False
        cur = cur[part]
    return cur, True


def set_by_path(doc: dict, dotted: str, value) -> None:
    parts = dotted.split(".")
    cur = doc
    for part in parts[:-1]:
        if not isinstance(cur, dict) or part not in cur:
            raise BuildError(f"cannot set {dotted!r}: intermediate path {part!r} missing or not an object")
        cur = cur[part]
    if not isinstance(cur, dict) or parts[-1] not in cur:
        raise BuildError(f"cannot set {dotted!r}: leaf key {parts[-1]!r} missing from live document")
    cur[parts[-1]] = value


def recursive_diff(old, new, prefix: str = "") -> list[dict]:
    """Leaf-level diff. Dicts recurse key-by-key (union of keys on both
    sides); anything else (scalars, lists) is compared by equality and
    reported as a single changed path if unequal -- deliberately NOT
    descending into lists, so any drift inside one (e.g. `divisions`) still
    surfaces as exactly one unexpected path rather than being silently
    missed."""
    changes = []
    if isinstance(old, dict) and isinstance(new, dict):
        for key in sorted(set(old) | set(new)):
            changes.extend(recursive_diff(old.get(key), new.get(key), f"{prefix}{key}."))
    else:
        if old != new:
            changes.append({"path": prefix.rstrip("."), "before": old, "after": new})
    return changes


def null_paths(obj, prefix: str = "") -> list[str]:
    """Dotted paths of every key whose value is JSON null, recursing into
    dicts and dict-valued list items (list-of-scalar/None items are also
    reported by index)."""
    paths: list[str] = []
    if isinstance(obj, dict):
        for key, val in obj.items():
            p = f"{prefix}{key}"
            if val is None:
                paths.append(p)
            elif isinstance(val, dict):
                paths.extend(null_paths(val, p + "."))
            elif isinstance(val, list):
                for i, item in enumerate(val):
                    if item is None:
                        paths.append(f"{p}.{i}")
                    elif isinstance(item, dict):
                        paths.extend(null_paths(item, f"{p}.{i}."))
    return paths


def render_diff_lines(label: str, diffs: list[dict]) -> list[str]:
    lines = [f"### {label} -- {len(diffs)} changed path(s)", ""]
    lines.append("| path | before | after |")
    lines.append("|---|---|---|")
    for d in diffs:
        lines.append(f"| `{d['path']}` | `{json.dumps(d['before'])}` | `{json.dumps(d['after'])}` |")
    lines.append("")
    return lines


def main() -> int:
    now = datetime.now(timezone.utc)
    ts_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    ts_file = now.strftime("%Y%m%dT%H%M%SZ")

    out_dir = os.path.expanduser(OUT_DIR_DEFAULT)
    os.makedirs(out_dir, exist_ok=True)

    token = sar.load_softmax_token()
    api = sar.Api(token)

    settings_envelope, reason = sar.fetch_settings(api)
    if settings_envelope is None:
        print(f"FATAL: could not GET live settings: {reason}", file=sys.stderr)
        return 1

    # Bank the raw envelope verbatim -- this is evidence, not the POST body.
    live_settings_path = os.path.join(out_dir, f"00q-live-settings-{ts_file}.json")
    with open(live_settings_path, "w") as f:
        json.dump(settings_envelope, f, indent=2, sort_keys=True)
    print(f"wrote {live_settings_path}")

    if "settings" not in settings_envelope or not isinstance(settings_envelope["settings"], dict):
        print("FATAL: envelope has no POST-shaped 'settings' object -- refusing to build a body", file=sys.stderr)
        return 1

    live_settings = settings_envelope["settings"]
    envelope_only_keys = sorted(set(settings_envelope) - {"settings"})
    print(f"envelope-only keys stripped (never echoed into a POST body): {envelope_only_keys}")

    # Sanity-check the documented pre-conditions before building anything.
    cur_transform, transform_present = get_by_path(live_settings, STEP_A_PATH)
    cur_rated_k, rated_k_present = get_by_path(live_settings, STEP_B_PATH)
    if not transform_present:
        print(f"FATAL: {STEP_A_PATH!r} not present in live settings -- cannot build Step A body", file=sys.stderr)
        return 1
    if cur_transform != STEP_A_OLD:
        print(
            f"FATAL: live {STEP_A_PATH!r} = {cur_transform!r}, expected {STEP_A_OLD!r} "
            "(already armed, or a different state than this script assumes) -- refusing to build",
            file=sys.stderr,
        )
        return 1
    if not rated_k_present:
        print(f"FATAL: {STEP_B_PATH!r} not present in live settings -- cannot build Step B body", file=sys.stderr)
        return 1
    if cur_rated_k != STEP_B_OLD:
        print(
            f"NOTE: live {STEP_B_PATH!r} = {cur_rated_k!r}, spec assumed {STEP_B_OLD!r} -- "
            "Step B body is a TEMPLATE regardless; using the LIVE value as its 'before'.",
        )

    null_in_live = null_paths(live_settings)

    # ---- Step A body: one leaf changed ----
    body_a = copy.deepcopy(live_settings)
    set_by_path(body_a, STEP_A_PATH, STEP_A_NEW)
    diff_a = recursive_diff(live_settings, body_a)
    new_nulls_a = sorted(set(null_paths(body_a)) - set(null_in_live))

    blocked_a = bool(new_nulls_a)
    a_ok = (not blocked_a) and len(diff_a) == 1 and diff_a[0]["path"] == STEP_A_PATH

    if blocked_a:
        a_path = os.path.join(out_dir, f"00q-step-a-body-{ts_file}-BLOCKED.json")
    else:
        a_path = os.path.join(out_dir, f"00q-step-a-body-{ts_file}.json")
    with open(a_path, "w") as f:
        json.dump(body_a, f, indent=2, sort_keys=True)
    print(f"wrote {a_path}")

    # ---- Step B body: TEMPLATE -- two leaves changed vs the SAME live baseline ----
    body_b = copy.deepcopy(body_a)
    set_by_path(body_b, STEP_B_PATH, STEP_B_NEW)
    diff_b = recursive_diff(live_settings, body_b)
    new_nulls_b = sorted(set(null_paths(body_b)) - set(null_in_live))

    blocked_b = bool(new_nulls_b)
    expected_b_paths = {STEP_A_PATH, STEP_B_PATH}
    b_ok = (not blocked_b) and len(diff_b) == 2 and {d["path"] for d in diff_b} == expected_b_paths

    b_path = os.path.join(out_dir, f"00q-step-b-body-{ts_file}.json")
    with open(b_path, "w") as f:
        json.dump(body_b, f, indent=2, sort_keys=True)
    print(f"wrote {b_path}  *** TEMPLATE -- re-derive from a FRESH GET at Step B time, do not reuse this file ***")
    note_path = os.path.join(out_dir, f"00q-step-b-body-{ts_file}-NOTE-TEMPLATE.md")
    with open(note_path, "w") as f:
        f.write(
            f"# TEMPLATE -- not a ready-to-send Step B body\n\n"
            f"Generated {ts_iso} from the SAME live GET used for the Step A body above, "
            f"before Step A has been sent. Step A's own POST will change live standings "
            f"and possibly other fields; this file demonstrates the SHAPE of Step B's body "
            f"(`{STEP_A_PATH}` already `{STEP_A_NEW!r}`, `{STEP_B_PATH}` -> `{STEP_B_NEW!r}`) "
            f"but MUST be re-derived from a fresh `GET /leagues/{{league_id}}/settings` taken "
            f"at actual Step B time -- resending a stale cached body is documented failure mode "
            f"#2 in `00q-post-body-spec-2026-09-09.md` §5 (inert no-op if `season_leg_transform` "
            f"has drifted, or worse if any sibling field has changed underneath this snapshot).\n"
        )
    print(f"wrote {note_path}")

    # ---- Report ----
    report_path = os.path.join(out_dir, f"00q-body-diff-{ts_file}.md")
    lines = [
        f"# GLORY GRADIENT Step A/B POST body diff -- {ts_iso}",
        "",
        f"- league_id: `{LEAGUE_ID}`",
        f"- live settings envelope: `{live_settings_path}`",
        f"- envelope-only keys stripped before use as a POST body (never echoed): {envelope_only_keys}",
        "",
        "## exclude_none hazard gate",
        "",
        f"Bucket (a) -- ALREADY null/absent live, harmless to round-trip as explicit `null` "
        f"(exclude_none drops these from `stored` either way; nothing changes since they carry "
        f"no data today): **{len(null_in_live)} path(s)**",
        "",
    ]
    if null_in_live:
        lines.append("```")
        lines.extend(f"{p}" for p in null_in_live)
        lines.append("```")
    else:
        lines.append("(none -- every field in the live document currently holds a value)")
    lines.append("")
    lines.append(
        f"Bucket (b) -- BLOCKER: paths that are null in a constructed body but held a VALUE live "
        f"(would be silently wiped by exclude_none on POST): Step A **{len(new_nulls_a)}**, "
        f"Step B **{len(new_nulls_b)}**"
    )
    lines.append("")
    if new_nulls_a or new_nulls_b:
        lines.append("```")
        lines.extend(f"A: {p}" for p in new_nulls_a)
        lines.extend(f"B: {p}" for p in new_nulls_b)
        lines.append("```")
    else:
        lines.append("(none -- both bodies are provably a byte-for-byte echo plus the intended leaf edit(s))")
    lines.append("")

    lines.append("## Step A field-by-field diff (vs live baseline)")
    lines.append("")
    lines.extend(render_diff_lines("Step A", diff_a))
    lines.append(f"Step A verdict: **{'READY' if a_ok else ('BLOCKED' if blocked_a else 'FAILED')}**")
    lines.append("")

    lines.append("## Step B (TEMPLATE) field-by-field diff (vs the SAME live baseline)")
    lines.append("")
    lines.extend(render_diff_lines("Step B", diff_b))
    lines.append(f"Step B verdict: **{'READY (template)' if b_ok else ('BLOCKED' if blocked_b else 'FAILED')}**")
    lines.append("")

    with open(report_path, "w") as f:
        f.write("\n".join(lines))
    print(f"wrote {report_path}")

    print(
        f"VERDICT: step_a={'READY' if a_ok else ('BLOCKED' if blocked_a else 'FAILED')} "
        f"diff_a_paths={len(diff_a)} "
        f"step_b={'READY(template)' if b_ok else ('BLOCKED' if blocked_b else 'FAILED')} "
        f"diff_b_paths={len(diff_b)} "
        f"null_in_live={len(null_in_live)} new_nulls_a={len(new_nulls_a)} new_nulls_b={len(new_nulls_b)}"
    )

    if not a_ok:
        print(
            f"FAIL LOUD: Step A body is not exactly-one-path-changed (got {len(diff_a)}) "
            f"or introduced a value-wiping null -- see {report_path}",
            file=sys.stderr,
        )
    if not b_ok:
        print(
            f"FAIL LOUD: Step B body is not exactly-two-paths-changed (got {len(diff_b)}) "
            f"or introduced a value-wiping null -- see {report_path}",
            file=sys.stderr,
        )
    return 0 if (a_ok and b_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
