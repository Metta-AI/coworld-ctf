"""Prepare isolated C9 integration, proving retained C2 normalization first."""
from pathlib import Path
import sys

research = Path(__file__).resolve().parents[1]
target = Path(sys.argv[1]).resolve()
assert target.name == "nav-deferred-cache"

def normalize(source):
    replacements = {
        "visited: seq[uint32]": "visited: seq[uint8]",
        "visitGeneration: uint32": "visitGeneration: uint8",
        "seat.dangerWorkspace.visited.capacity * sizeof(uint32)":
            "seat.dangerWorkspace.visited.capacity * sizeof(uint8)",
        "result.workspace.visited = newSeq[uint32](size)":
            "result.workspace.visited = newSeq[uint8](size)",
        "seat.dangerWorkspace.visitGeneration == high(uint32)":
            "seat.dangerWorkspace.visitGeneration == high(uint8)",
        "    if sourceCache.bits.capacity > 0:":
            "    result.allocatorOverhead += SequenceAllocationOverhead\n    if sourceCache.bits.capacity > 0:",
    }
    for old, new in replacements.items():
        assert source.count(old) == 1, old
        source = source.replace(old, new)
    start = source.index("template dangerStage(")
    end = source.index("proc sourceCacheSlot(", start)
    source = source[:start] + source[end:]
    lines = source.splitlines(keepends=True)
    result = []
    wrapper_indent = None
    for line in lines:
        stripped = line.lstrip()
        if stripped.startswith(("## C5 attribution markers", "## marker per source", "# C5 v2:", "# below stay outside")):
            continue
        indent = len(line) - len(stripped)
        if wrapper_indent is not None and stripped.strip() and indent <= wrapper_indent:
            wrapper_indent = None
        if stripped.startswith('dangerStage("'):
            assert wrapper_indent is None
            wrapper_indent = indent
            continue
        if wrapper_indent is not None:
            if stripped.strip() and indent <= wrapper_indent:
                wrapper_indent = None
            elif stripped.strip():
                line = line[2:]
        result.append(line)
    return "".join(result)

parent = (research / "C9/full/snapshots/parent-body_nav.nim").read_text()
candidate = (research / "C9/full/snapshots/candidate-body_nav.nim").read_text()
path = target / "src/shell/body_nav.nim"
assert normalize(parent) == path.read_text(), "Retained parent differs; inspect before changing source"
path.write_text(normalize(candidate))
