#!/usr/bin/env python3
"""tools/stranger_walk/boundary_scan.py — classify isolation_audit.sh's
boundary-pattern hits as WARN (explained by the stranger's own PUBLIC repo
checkout under its workspace) or DQ (unexplained — a real isolation-boundary
leak).

Owner ruling 2026-09-09: a DISQUALIFY requires evidence the stranger's own
action REACHED the host (a tool call whose path/argument targets ~/.ctf, the
host HOME, ~/.claude, the Keychain, or a credential value appearing in an
artifact). A bare string occurrence of an internal path that the stranger
encountered inside a PUBLIC repo file it legitimately read — found
2026-09-09: `~/.ctf/knowledge/stranger-walk/STATUS-2026-09-09.md` leaks into
README.md, policies/poc_llm_policy/README.md,
docs/designs/BUILDER_DOOR.md, and docs/designs/THE_GAME_EXPLAINS_ITSELF.md,
all on `main` right now — is a WARN that cites the public file, not a DQ.
Those four files are a separate follow-up (owner will scrub them); this
script is the instrument-side fix so an unrelated repo-hygiene bug does not
silently disqualify a real baseline run.

Usage: boundary_scan.py <run-dir> <pattern>
Reads matched transcript lines on stdin, one per line, in `grep -n`'s
"<lineno>:<line>" format (isolation_audit.sh already produces exactly this).
For each line, extracts the longest path-shaped token containing the
pattern match and checks whether that EXACT token exists verbatim in any
file under <run-dir>/workspace — the stranger's own persisted working
directory (bind-mounted, still on disk after the container exits; see
run_container.sh's guard #1). That directory is where a stranger's own
`git clone`/wget of the public repo, or any fetched doc page, would land —
never where a credential or host secret could be (that's $RUN_DIR itself,
a different, non-overlapping mount — see guard #1).

Prints one classification per input line:
  WARN <lineno> <token> <checkout-relative-file>
  DQ <lineno> <token>
Exit 0 always — this is a classifier, not a pass/fail gate; the caller
(isolation_audit.sh) tallies WARN vs DQ lines itself.
"""
import os
import re
import sys

# A generous "path-shaped" token: starts with ~ or / or a bare word char,
# runs through slashes/dots/dashes/underscores. Widened around the raw
# pattern match so e.g. `~/.ctf` extends out to the full
# `~/.ctf/knowledge/stranger-walk/STATUS-2026-09-09.md` it's embedded in.
TOKEN_RE = re.compile(r"[~./\w][\w./-]{4,}")

MAX_FILE_BYTES = 5_000_000


def find_in_checkout(token, workspace_dir):
    if not token or not os.path.isdir(workspace_dir):
        return None
    for root, _dirs, files in os.walk(workspace_dir):
        for name in files:
            path = os.path.join(root, name)
            try:
                if os.path.getsize(path) > MAX_FILE_BYTES:
                    continue
                with open(path, "r", errors="ignore") as f:
                    content = f.read()
            except Exception:
                continue
            if token in content:
                return os.path.relpath(path, workspace_dir)
    return None


def widen_token(text, match):
    token = match.group(0)
    for tm in TOKEN_RE.finditer(text):
        if tm.start() <= match.start() and tm.end() >= match.end():
            return tm.group(0)
    return token


def main():
    if len(sys.argv) != 3:
        print("usage: boundary_scan.py <run-dir> <pattern>", file=sys.stderr)
        return 2
    run_dir, pattern = sys.argv[1], sys.argv[2]
    workspace_dir = os.path.join(run_dir, "workspace")
    pat_re = re.compile(pattern)
    for raw_line in sys.stdin:
        raw_line = raw_line.rstrip("\n")
        lineno, sep, text = raw_line.partition(":")
        if not sep:
            continue
        m = pat_re.search(text)
        if not m:
            # Shouldn't happen (caller already grep -E'd for this pattern),
            # but fail safe toward DQ rather than silently dropping a line.
            print(f"DQ {lineno} (pattern-not-re-found)")
            continue
        token = widen_token(text, m)
        hit_file = find_in_checkout(token, workspace_dir)
        if not hit_file:
            # The model's OWN summary of what it read often paraphrases a
            # long path with a trailing ellipsis (found 2026-09-09: a
            # stranger's own end-of-run summary wrote
            # `~/.ctf/knowledge/stranger-walk/...` while recapping the
            # README it had just read, rather than quoting the filename
            # verbatim) — still just citing public content it legitimately
            # saw, not a new host-reach. Strip a trailing run of `.` and
            # retry with the remaining prefix if it's still specific enough
            # to mean something (a bare `~/.ctf` alone is too generic to
            # trust as evidence of *which* file explains it).
            stripped = re.sub(r"\.+$", "", token)
            if len(stripped) >= 15 and stripped != token:
                hit_file = find_in_checkout(stripped, workspace_dir)
        if hit_file:
            print(f"WARN {lineno} {token} {hit_file}")
        else:
            print(f"DQ {lineno} {token}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
