#!/usr/bin/env python3
"""GLORY GRADIENT Step A/B POST body builder -- read-only, MECHANICAL, never sends.

Builds the exact request bodies for the (not-yet-sent) full-replace
``POST /leagues/{league_id}/settings`` writes that arm ``season_leg_transform``
(Step A) and retune ``rated_k`` (Step B), per
``~/.ctf/knowledge/glory-gradient/00q-post-body-spec-2026-09-09.md``, PLUS
(``--arm win-gate``) the ARM WIN-GATE body that lands all three of
``season_leg_transform``, ``win_gated_legs`` (new field, metta#22988), and
``rated_k=0.02`` (the gated-sweep's recommended rate under the gate --
``01h-win-gated-standing-sweep-2026-09-14.md`` -- which supersedes Step B's
0.025 ONLY when the gate is on) in one POST.

THIS SCRIPT NEVER SENDS A POST. There is no POST/PUT/PATCH/DELETE code path
anywhere in this file or in ``step_a_read.py`` -- the shared ``Api`` class
(``step_a_read.Api``) defines only ``.get()``. It only GETs the live settings
(the same COMMISSIONER_OR_SUBMITTER_AUTH surface, plain bearer, that
step_a_read.py already uses) and writes JSON/markdown files to disk. ``--arm``
requires ``--dry-run`` as an explicit confirmation gate before either code
path runs -- not because there is a write to disable (there isn't), but so a
bare ``--arm win-gate`` invocation cannot be mistaken for "the real thing."

Why this exists (the hazard the spec calls out): the endpoint is a FULL
REPLACE -- ``leagues.py:3203-3204`` does
``stored = request.model_dump(mode="json", exclude_none=True); league.settings
= stored or None`` -- so any top-level block or nested field the POST body
omits (or supplies as JSON ``null``) is silently dropped from the whole
``leagues.settings`` row, not merged. The only safe construction is: GET the
live settings, take the ``.settings`` object VERBATIM, and change only the
intended leaf(s).

Method, mechanically (unchanged from the original Step A/B design):
  1. GET /leagues/{league_id}/settings. The response is an ENVELOPE
     (``LeagueSettingsResponse``: ``settings``, ``defaults``,
     ``effective_ladder_config``, ``commissioner_key``, ``warnings``,
     ``results_schema`` -- leagues.py:474-488). Only ``response["settings"]``
     is POST-shaped; the other keys are response-only computed/administrative
     fields and would 422 via ``unknown_key_paths`` if echoed into the
     request. This script extracts ``settings`` and discards the rest (never
     echoes the envelope).
  2. Deepcopy that ``settings`` object, once per intended edit-set, and change
     ONLY the intended leaf(s) -- everything else is carried through
     byte-for-byte because it was never touched.
  3. Recursively diff each constructed body against the live baseline. Every
     changed JSON path is reported before/after. The script asserts the diff
     has EXACTLY the expected changed path(s) -- any more (or fewer) means the
     echo was not byte-for-byte and the script fails loudly instead of
     writing a body file.
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
     is ever non-empty, the script does NOT write the normal body file -- it
     writes a ``-BLOCKED.json`` file instead, names the wiped field(s), and
     exits non-zero. Nothing is ever sent regardless.

Modes:
  (default, no --arm)  Legacy Step A (one path: season_leg_transform) + Step B
                        TEMPLATE (two paths: + rated_k=0.025). Unchanged
                        behavior/output from the original tool.
  --arm win-gate --dry-run
                        ARM WIN-GATE body: three paths --
                        ``ladder.ranking.season_leg_transform`` (none ->
                        signed_log2), ``ladder.ranking.win_gated_legs``
                        (absent/false -> true, metta#22988), and
                        ``ladder.ranking.rated_k`` (0.05 -> 0.02). Asserts the
                        diff against a FRESH GET is exactly those three paths
                        and writes ``00r-arm-body-<ts>.json`` (the body) +
                        ``00r-arm-body-<ts>.md`` (the diff/report, including a
                        before/after table of every ``ladder.ranking`` key so
                        the sub-document's completeness is visible, not just
                        asserted).

Usage:
    python3 tools/glory/step_a_body.py
    python3 tools/glory/step_a_body.py --arm win-gate --dry-run
"""
from __future__ import annotations

import argparse
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

# ARM WIN-GATE (--arm win-gate): metta#22988 adds `win_gated_legs: bool`
# (documented default false) to ScoreRankingConfig alongside the two fields
# above. Reuses STEP_A_PATH/STEP_A_OLD/STEP_A_NEW and STEP_B_PATH unchanged;
# only the win-gate leaf and the arm's own rated_k target are new.
STEP_ARM_WIN_GATE_PATH = "ladder.ranking.win_gated_legs"
STEP_ARM_WIN_GATE_OLD = False  # documented default; field may be ABSENT entirely pre-deploy
STEP_ARM_WIN_GATE_NEW = True
STEP_ARM_RATED_K_NEW = 0.02  # gated-sweep ruling (01h-win-gated-standing-sweep-2026-09-14.md):
# dominates every swept rate on tau / #1-change / leader-share under the gate;
# supersedes Step B's 0.025 ONLY when win_gated_legs=true.
STEP_ARM_EXPECTED_PATHS = frozenset({STEP_A_PATH, STEP_ARM_WIN_GATE_PATH, STEP_B_PATH})


class BuildError(RuntimeError):
    """Raised to fail loudly; caught only at the run_* level to print + exit non-zero."""


def get_by_path(doc: dict, dotted: str):
    cur = doc
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None, False
        cur = cur[part]
    return cur, True


def set_by_path(doc: dict, dotted: str, value, allow_new_leaf: bool = False) -> None:
    """Set a dotted leaf path in place. Intermediate path components must
    already exist (never silently creates a nested object -- that would be
    schema-inventing, not echoing). The LEAF must already exist unless
    ``allow_new_leaf=True``, which is used only for fields the live document
    may not carry yet (e.g. a not-yet-deployed field like win_gated_legs) --
    every other call site keeps the original, stricter default."""
    parts = dotted.split(".")
    cur = doc
    for part in parts[:-1]:
        if not isinstance(cur, dict) or part not in cur:
            raise BuildError(f"cannot set {dotted!r}: intermediate path {part!r} missing or not an object")
        cur = cur[part]
    leaf = parts[-1]
    if not isinstance(cur, dict):
        raise BuildError(f"cannot set {dotted!r}: parent of leaf {leaf!r} is not an object")
    if leaf not in cur and not allow_new_leaf:
        raise BuildError(f"cannot set {dotted!r}: leaf key {leaf!r} missing from live document")
    cur[leaf] = value


def recursive_diff(old, new, prefix: str = "") -> list[dict]:
    """Leaf-level diff. Dicts recurse key-by-key (union of keys on both
    sides -- a key present on only one side shows up as one changed path,
    before/after None on the missing side); anything else (scalars, lists) is
    compared by equality and reported as a single changed path if unequal --
    deliberately NOT descending into lists, so any drift inside one (e.g.
    `divisions`) still surfaces as exactly one unexpected path rather than
    being silently missed."""
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


def ranking_completeness_report(live_ranking: dict, body_ranking: dict) -> list[dict]:
    """Before/after for every key seen in either `ladder.ranking` dict --
    lets a reader SEE the sub-document is whole (every untouched key carried
    through with its live value) instead of just trusting the diff-path
    assertion."""
    keys = sorted(set(live_ranking) | set(body_ranking))
    rows = []
    for k in keys:
        before = live_ranking.get(k)
        after = body_ranking.get(k)
        rows.append({"key": k, "before": before, "after": after, "changed": before != after})
    return rows


def build_arm_win_gate_body(live_settings: dict) -> tuple[dict, dict]:
    """Deepcopy live_settings and apply the three ARM WIN-GATE edits.
    Raises BuildError loudly on any precondition mismatch -- never silently
    proceeds from an unexpected live state. Returns (body, meta) where meta
    records what the live document held for each touched field BEFORE the
    edit, for reporting."""
    cur_transform, transform_present = get_by_path(live_settings, STEP_A_PATH)
    if not transform_present:
        raise BuildError(f"{STEP_A_PATH!r} not present in live settings -- cannot build ARM WIN-GATE body")
    if cur_transform != STEP_A_OLD:
        raise BuildError(
            f"live {STEP_A_PATH!r} = {cur_transform!r}, expected {STEP_A_OLD!r} "
            "(already armed, or a different state than this script assumes) -- refusing to build"
        )

    cur_win_gate, win_gate_present = get_by_path(live_settings, STEP_ARM_WIN_GATE_PATH)
    if win_gate_present and cur_win_gate not in (False, None):
        raise BuildError(
            f"live {STEP_ARM_WIN_GATE_PATH!r} = {cur_win_gate!r}, expected absent or "
            f"{STEP_ARM_WIN_GATE_OLD!r} -- already armed, or the field means something unexpected"
        )

    cur_rated_k, rated_k_present = get_by_path(live_settings, STEP_B_PATH)
    if not rated_k_present:
        raise BuildError(f"{STEP_B_PATH!r} not present in live settings -- cannot build ARM WIN-GATE body")
    if cur_rated_k == STEP_ARM_RATED_K_NEW:
        raise BuildError(
            f"live {STEP_B_PATH!r} is already {STEP_ARM_RATED_K_NEW!r} -- setting it again would "
            "not register as a changed path and would break the exactly-3-paths assertion"
        )

    body = copy.deepcopy(live_settings)
    set_by_path(body, STEP_A_PATH, STEP_A_NEW)
    set_by_path(body, STEP_ARM_WIN_GATE_PATH, STEP_ARM_WIN_GATE_NEW, allow_new_leaf=True)
    set_by_path(body, STEP_B_PATH, STEP_ARM_RATED_K_NEW)

    meta = {
        "transform_before": cur_transform,
        "win_gate_present_live": win_gate_present,
        "win_gate_before": cur_win_gate,
        "rated_k_before": cur_rated_k,
    }
    return body, meta


def fetch_live_settings(out_dir: str, ts_file: str, bank_prefix: str) -> tuple[dict | None, dict | None, list, str]:
    """Fresh GET (never cached, never reused across runs). Banks the raw
    envelope to disk as evidence and returns
    (settings_envelope, live_settings_or_None, envelope_only_keys, bank_path).
    On failure, settings_envelope/live_settings are both None; caller prints
    the reason and exits non-zero."""
    token = sar.load_softmax_token()
    api = sar.Api(token)

    settings_envelope, reason = sar.fetch_settings(api)
    if settings_envelope is None:
        print(f"FATAL: could not GET live settings: {reason}", file=sys.stderr)
        return None, None, [], reason

    out_path = os.path.join(out_dir, f"{bank_prefix}-{ts_file}.json")
    with open(out_path, "w") as f:
        json.dump(settings_envelope, f, indent=2, sort_keys=True)
    print(f"wrote {out_path}")

    if "settings" not in settings_envelope or not isinstance(settings_envelope["settings"], dict):
        print("FATAL: envelope has no POST-shaped 'settings' object -- refusing to build a body", file=sys.stderr)
        return settings_envelope, None, [], out_path

    live_settings = settings_envelope["settings"]
    envelope_only_keys = sorted(set(settings_envelope) - {"settings"})
    print(f"envelope-only keys stripped (never echoed into a POST body): {envelope_only_keys}")
    return settings_envelope, live_settings, envelope_only_keys, out_path


def run_legacy(out_dir: str, ts_iso: str, ts_file: str) -> int:
    """Original Step A (one path) + Step B TEMPLATE (two paths) builder --
    behavior/output unchanged from before --arm existed."""
    settings_envelope, live_settings, envelope_only_keys, live_settings_path = fetch_live_settings(
        out_dir, ts_file, "00q-live-settings"
    )
    if live_settings is None:
        return 1

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


def run_arm_win_gate(out_dir: str, ts_iso: str, ts_file: str) -> int:
    """--arm win-gate --dry-run: builds the 3-path ARM WIN-GATE body from a
    FRESH GET, asserts the diff is exactly those 3 paths, and writes
    00r-arm-body-<ts>.json (the body) + 00r-arm-body-<ts>.md (the diff and a
    full before/after table of every `ladder.ranking` key). No network write
    of any kind occurs -- see module docstring."""
    settings_envelope, live_settings, envelope_only_keys, live_settings_path = fetch_live_settings(
        out_dir, ts_file, "00r-arm-live-settings"
    )
    if live_settings is None:
        return 1

    try:
        body, meta = build_arm_win_gate_body(live_settings)
    except BuildError as e:
        print(f"FATAL: {e}", file=sys.stderr)
        return 1

    diff_arm = recursive_diff(live_settings, body)
    null_in_live = null_paths(live_settings)
    new_nulls = sorted(set(null_paths(body)) - set(null_in_live))
    blocked = bool(new_nulls)
    diff_paths = {d["path"] for d in diff_arm}
    paths_match = diff_paths == set(STEP_ARM_EXPECTED_PATHS)
    arm_ok = (not blocked) and len(diff_arm) == 3 and paths_match

    if blocked:
        body_path = os.path.join(out_dir, f"00r-arm-body-{ts_file}-BLOCKED.json")
    else:
        body_path = os.path.join(out_dir, f"00r-arm-body-{ts_file}.json")
    with open(body_path, "w") as f:
        json.dump(body, f, indent=2, sort_keys=True)
    print(f"wrote {body_path}")

    live_ranking = get_by_path(live_settings, "ladder.ranking")[0] or {}
    body_ranking = get_by_path(body, "ladder.ranking")[0] or {}
    ranking_rows = ranking_completeness_report(live_ranking, body_ranking)
    live_ranking_count = len(live_ranking)
    body_ranking_count = len(body_ranking)

    verdict = "READY (dry run only -- OWNER sends the real POST)" if arm_ok else ("BLOCKED" if blocked else "FAILED")

    report_path = os.path.join(out_dir, f"00r-arm-body-{ts_file}.md")
    lines = [
        f"# GLORY GRADIENT ARM WIN-GATE POST body + diff (DRY RUN, GET-only) -- {ts_iso}",
        "",
        "**NO POST WAS SENT.** This script has no POST/PUT/PATCH/DELETE code path at all "
        "(`step_a_read.Api` defines only `.get()`) -- everything below is a fresh GET, a "
        "mechanical body construction, and a diff, all written to disk only.",
        "",
        f"- league_id: `{LEAGUE_ID}`",
        f"- live settings envelope (fresh GET, this run): `{live_settings_path}`",
        f"- envelope-only keys stripped before use as a POST body (never echoed): {envelope_only_keys}",
        f"- `{STEP_ARM_WIN_GATE_PATH}` present in live settings: **{meta['win_gate_present_live']}** "
        f"(expect **False** -- metta#22988 not yet deployed to the served backend)",
        f"- live values before this arm: season_leg_transform={meta['transform_before']!r}, "
        f"win_gated_legs={meta['win_gate_before']!r} (present={meta['win_gate_present_live']}), "
        f"rated_k={meta['rated_k_before']!r}",
        "",
        "## exclude_none hazard gate",
        "",
        f"Bucket (a) -- already null/absent live, harmless to round-trip: **{len(null_in_live)} path(s)**",
        f"Bucket (b) -- BLOCKER, a live value that would be wiped to null: **{len(new_nulls)} path(s)**",
        "",
    ]
    if new_nulls:
        lines.append("```")
        lines.extend(new_nulls)
        lines.append("```")
    else:
        lines.append("(none -- the body is a byte-for-byte echo of the fresh GET plus exactly the three intended edits)")
    lines.append("")

    lines.append("## The 3-path diff (vs this run's fresh GET)")
    lines.append("")
    lines.extend(render_diff_lines("ARM WIN-GATE", diff_arm))
    lines.append(f"expected path set: {sorted(STEP_ARM_EXPECTED_PATHS)}")
    lines.append(f"actual path set: {sorted(diff_paths)}")
    lines.append(f"paths match expected set exactly: **{paths_match}**")
    lines.append("")

    lines.append("## `ladder.ranking` sub-document completeness (before -> after, every key)")
    lines.append("")
    lines.append("| key | before | after | changed |")
    lines.append("|---|---|---|---|")
    for row in ranking_rows:
        lines.append(f"| `{row['key']}` | `{json.dumps(row['before'])}` | `{json.dumps(row['after'])}` | {row['changed']} |")
    lines.append("")
    lines.append(f"ranking key count: live={live_ranking_count} body={body_ranking_count}")
    lines.append("")

    lines.append(f"## VERDICT: {verdict}")
    lines.append("")

    with open(report_path, "w") as f:
        f.write("\n".join(lines))
    print(f"wrote {report_path}")

    print(
        f"VERDICT: arm_win_gate={verdict} diff_paths={len(diff_arm)} paths={sorted(diff_paths)} "
        f"null_in_live={len(null_in_live)} new_nulls={len(new_nulls)} "
        f"win_gated_legs_present_live={meta['win_gate_present_live']} "
        f"ranking_keys_live={live_ranking_count} ranking_keys_body={body_ranking_count}"
    )

    if not arm_ok:
        print(
            f"FAIL LOUD: ARM WIN-GATE body is not exactly-3-paths-changed (got {len(diff_arm)}, "
            f"paths={sorted(diff_paths)}) or introduced a value-wiping null -- see {report_path}",
            file=sys.stderr,
        )
        return 1
    return 0


def run_check_deploy() -> int:
    """--check-deploy: ONE fresh GET /leagues/{league_id}/settings, prints
    EXACTLY one line, writes NO files (no bank, no body, no report -- unlike
    every other mode in this script). Built for a shell `until ...; do sleep
    N; done` poll: exit 0 once `win_gated_legs` is present in the live
    settings (metta#22988 deployed to the served backend), exit 1 while
    still absent. No POST/PUT/PATCH/DELETE code path, as everywhere else in
    this file -- this is a single `sar.fetch_settings` GET call."""
    token = sar.load_softmax_token()
    api = sar.Api(token)
    ts_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    settings_envelope, reason = sar.fetch_settings(api)

    if settings_envelope is None or not isinstance(settings_envelope.get("settings"), dict):
        print(
            f"win_gated_legs_present_live=False season_leg_transform=None rated_k=None fetched={ts_iso}"
        )
        print(f"(GET failed or unusable envelope: {reason})", file=sys.stderr)
        return 1

    live_settings = settings_envelope["settings"]
    win_gate_val, win_gate_present = get_by_path(live_settings, STEP_ARM_WIN_GATE_PATH)
    transform_val, _ = get_by_path(live_settings, STEP_A_PATH)
    rated_k_val, _ = get_by_path(live_settings, STEP_B_PATH)

    print(
        f"win_gated_legs_present_live={win_gate_present} season_leg_transform={transform_val} "
        f"rated_k={rated_k_val} fetched={ts_iso}"
    )
    return 0 if win_gate_present else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument(
        "--arm",
        choices=["win-gate"],
        default=None,
        help=(
            "build the ARM WIN-GATE body (3 paths: ladder.ranking.season_leg_transform, "
            "ladder.ranking.win_gated_legs, ladder.ranking.rated_k=0.02) from a FRESH GET, "
            "instead of the legacy Step A (one-path) / Step B-template (two-path) bodies. "
            "Legacy behavior (no --arm) is unchanged."
        ),
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "required alongside --arm. This script has NO POST/PUT/PATCH/DELETE code path at "
            "all (step_a_read.Api defines only .get()) -- there is no network write for "
            "--dry-run to disable. It is an explicit confirmation gate: --arm without "
            "--dry-run refuses to run."
        ),
    )
    ap.add_argument(
        "--check-deploy",
        action="store_true",
        help=(
            "ONE fresh GET, prints exactly one line, writes NO files. Exit 0 once "
            "ladder.ranking.win_gated_legs is present in the live settings (metta#22988 "
            "deployed to the served backend), exit 1 while still absent -- for a shell "
            "`until tools/glory/step_a_body.py --check-deploy; do sleep N; done` poll. "
            "No POST path, as everywhere else in this script."
        ),
    )
    args = ap.parse_args()

    if args.check_deploy:
        return run_check_deploy()

    if args.arm and not args.dry_run:
        print(
            "REFUSING: --arm requires --dry-run. (This tool cannot POST regardless of this "
            "flag -- --dry-run is a confirmation gate, not a network-write toggle.)",
            file=sys.stderr,
        )
        return 2

    now = datetime.now(timezone.utc)
    ts_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    ts_file = now.strftime("%Y%m%dT%H%M%SZ")
    out_dir = os.path.expanduser(OUT_DIR_DEFAULT)
    os.makedirs(out_dir, exist_ok=True)

    if args.arm == "win-gate":
        return run_arm_win_gate(out_dir, ts_iso, ts_file)
    return run_legacy(out_dir, ts_iso, ts_file)


if __name__ == "__main__":
    sys.exit(main())
