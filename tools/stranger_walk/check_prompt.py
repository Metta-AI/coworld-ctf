#!/usr/bin/env python3
"""tools/stranger_walk/check_prompt.py [PATH ...]

Protocol v2 contamination gate (2026-09-09, owner ruling). The whole point
of Protocol v2 is that the stranger discovers the game's milestones on its
own — the prompt must never hand them out. This script is the enforcement:
it refuses (non-zero exit) if the text that would ACTUALLY be handed to a
stranger process mentions anything that would prime it toward a specific
milestone, page, or report format.

What "actually handed to a stranger" means: `run.sh`/`run_container.sh`
render `prompt.md` (or `smoke_prompt.md` for a smoke test) into
`prompt.rendered.md` by taking everything strictly AFTER the first line
that is exactly `---` and substituting `{{ENTRY_URL}}`. Everything before
that delimiter is contributor-facing documentation about the file itself
and is never shown to the stranger. `render_body()` below reproduces that
exact split so this check inspects precisely what the stranger sees — not
the doc comment above it, which is free to discuss the protocol by name.

Only `prompt.md` is covered by default: it is the one real, scored,
comparable protocol artifact. `smoke_prompt.md` is deliberately NOT
checked here — its whole job is a hard-stop clause that names
login/submit/upload verbs so a smoke run stops itself before attempting
them (see that file's own header); it is never used for an official
baseline or compared against another run, so the same contamination rule
does not apply to it. Pass it explicitly (`check_prompt.py smoke_prompt.md`)
if you ever want to sanity-check it anyway.

Usage:
    check_prompt.py                  # checks prompt.md, exit 0=clean 1=contaminated
    check_prompt.py PATH [PATH ...]  # check specific file(s) instead
    check_prompt.py --show-body PATH # print exactly what would render to the stranger, then exit

Exit codes: 0 clean, 1 contaminated, 2 usage/file error.
"""
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DELIMITER = "---"

# Case-insensitive substring bans. Anything here in the rendered body means
# the stranger was handed a fact it should have had to discover itself.
# "M1".."M8" milestone labels use a separate word-boundary regex below
# because they aren't safe to match as a plain substring (e.g. "M1" inside
# an unrelated token).
BANNED_PHRASES = [
    "milestone",
    "belief",
    "blocked",
    "submit",
    "coworld",
    "observatory",
    "wiki",
    "docs.softmax.com",
    "replay",
    "standings",
    "sign in",
    "github",
]
MILESTONE_LABEL_RE = re.compile(r"(?<![A-Za-z0-9])M[1-8](?![A-Za-z0-9])")

# Protocol v2 rule: if the owner's sentence itself contains one of the
# banned words/phrases, whitelist EXACTLY that occurrence (keyed by the
# exact substring of the rendered body it appears in) and say so in the PR
# — never widen the ban list to dodge it. Empty today: the current owner's
# sentence ("You are a competent developer who has never heard of
# Paintbot. Starting from {{ENTRY_URL}}, get a policy of your own onto the
# Paintbot ladder and make it climb. Think aloud as you go. Never post,
# message, or contact anyone. Never read files outside your working
# directory except what the public surfaces link to.") uses none of them.
WHITELIST = {
    # "phrase": ["exact substring(s) of the rendered body allowed to contain it"],
}


def render_body(path: Path) -> str:
    """Return exactly the text run.sh/run_container.sh render into
    prompt.rendered.md for this source file (before the {{ENTRY_URL}}
    substitution, which doesn't affect the contamination scan): everything
    strictly after the first line that is exactly '---'. A file with no
    such delimiter is treated as all-body (fail loud on the whole file
    rather than silently pass a malformed one)."""
    lines = path.read_text().splitlines()
    for i, line in enumerate(lines):
        if line.strip() == DELIMITER:
            return "\n".join(lines[i + 1 :])
    return "\n".join(lines)


def check_body(body: str, label: str) -> list[str]:
    problems = []
    lowered = body.lower()
    for phrase in BANNED_PHRASES:
        allowed_contexts = WHITELIST.get(phrase, [])
        start = 0
        while True:
            idx = lowered.find(phrase, start)
            if idx == -1:
                break
            start = idx + len(phrase)
            context = body[max(0, idx - 25) : idx + len(phrase) + 25]
            if any(allowed in context or allowed in body for allowed in allowed_contexts):
                continue
            problems.append(
                f"{label}: banned phrase {phrase!r} at body offset {idx} — ...{context!r}..."
            )
    for m in MILESTONE_LABEL_RE.finditer(body):
        context = body[max(0, m.start() - 25) : m.end() + 25]
        problems.append(
            f"{label}: milestone label {m.group()!r} at body offset {m.start()} — ...{context!r}..."
        )
    return problems


def check_file(path: Path) -> list[str]:
    if not path.exists():
        return [f"{path}: does not exist"]
    return check_body(render_body(path), path.name)


def selftest() -> int:
    """Repeatable regression test for the gate itself (no pytest dependency
    in this tree): (1) the real prompt.md must pass clean today, (2) a
    synthetic contaminated body must be refused, (3) the header-only doc
    comment above the `---` delimiter must NOT be scanned (it's allowed to
    discuss the protocol by name), (4) a real Walk 1 (Protocol v1) rendered
    prompt — which really did leak milestones — must be refused. Run this
    any time prompt.md or check_prompt.py itself changes."""
    failures = []

    real_problems = check_file(SCRIPT_DIR / "prompt.md")
    if real_problems:
        failures.append(f"prompt.md should be clean today but got: {real_problems}")

    import tempfile

    with tempfile.TemporaryDirectory() as td:
        contaminated = Path(td) / "contaminated.md"
        contaminated.write_text(
            "# doc header, never shown to the stranger — mentions MILESTONE freely\n---\n"
            "You must reach M3 and post a MILESTONE: line, then submit to coworld.\n"
        )
        problems = check_body(render_body(contaminated), "contaminated.md")
        if not problems:
            failures.append("synthetic contaminated body was NOT flagged (false negative)")

        header_only_clean = Path(td) / "header_only.md"
        header_only_clean.write_text(
            "# doc header talking about MILESTONE/BELIEF freely — never shown to the stranger\n"
            "---\n"
            "Just the owner's plain sentence, nothing else.\n"
        )
        problems2 = check_body(render_body(header_only_clean), "header_only.md")
        if problems2:
            failures.append(
                f"header-only mention wrongly flagged the body (false positive): {problems2}"
            )

    walk1_prompt = Path(
        "/Users/maxwellstarr/projects/stranger-walk-runs/sonnet-a/prompt.rendered.md"
    )
    if walk1_prompt.exists():
        walk1_problems = check_file(walk1_prompt)
        if not walk1_problems:
            failures.append(
                "Walk 1's real rendered prompt (sonnet-a) should be flagged contaminated but wasn't"
            )

    if failures:
        print("check_prompt --selftest: FAIL", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("check_prompt --selftest: PASS (prompt.md clean; synthetic contamination caught; "
          "header-only mentions not false-flagged; Walk 1's real leaked prompt caught)")
    return 0


def main(argv):
    if argv and argv[0] == "--selftest":
        return selftest()

    if argv and argv[0] == "--show-body":
        if len(argv) != 2:
            print("usage: check_prompt.py --show-body PATH", file=sys.stderr)
            return 2
        path = Path(argv[1])
        if not path.is_absolute():
            path = SCRIPT_DIR / path
        if not path.exists():
            print(f"check_prompt: {path} does not exist", file=sys.stderr)
            return 2
        sys.stdout.write(render_body(path))
        return 0

    targets = argv or ["prompt.md"]
    all_problems = []
    for t in targets:
        path = Path(t)
        if not path.is_absolute():
            path = SCRIPT_DIR / t
        all_problems.extend(check_file(path))

    if all_problems:
        print("check_prompt: REFUSING — contaminated prompt body:", file=sys.stderr)
        for p in all_problems:
            print(f"  - {p}", file=sys.stderr)
        return 1
    print(f"check_prompt: clean ({', '.join(targets)})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
