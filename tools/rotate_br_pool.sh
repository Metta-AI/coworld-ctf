#!/bin/bash
## rotate_br_pool.sh — rolling replacement for the Season 2 BR map pool.
##
##   tools/rotate_br_pool.sh --replace 16
##
## Certifies N fresh candidate maps through the IDENTICAL 18-gate
## `validateBr` allPass suite the pool was built with (tools/brmapkit
## `generate` refuses to write a failing draw at all — rejection-gated,
## no --lenient, no hand edits; this script re-asserts `gates.all` from
## `metrics --json` as belt and braces) and swaps out the N OLDEST pool
## entries (oldest by certifiedAt, ties by seed). Invariants:
##   1. pool SIZE never changes — only membership;
##   2. recorded episodes stay valid forever (each replay pinned its own
##      mapSpec at parse time; playback never consults the pool);
##   3. selection stays deterministic per episode seed over the CURRENT
##      pool — the same seed maps to a different member across pool
##      generations, which is intended;
##   4. any candidate that is not 18/18 is refused (never shipped).
## Candidate seeds ascend from max(pool seeds)+1, so a rotated-out map can
## never re-enter by seed collision.
##
## Draw params are PINNED to the battle-royale-s2 shape (#354, br-gen-8024):
## --groups 8 --scale 1.8384776 (GiantScale/sqrt(2)). Expect a low certify
## yield (~0.5-2% of draws pass all 18 gates; measured 2026-09-01) — a
## --replace 16 run makes on the order of a few thousand draws, a few
## minutes of wall time.
##
## The updated pool + ledger lands as a normal diff for a PR; cadence is
## operational (recommended: a weekly automation opens the rotation PR).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
POOL="$REPO_ROOT/data/br_s2_map_pool.json"
REPLACE=""
SCALE=1.8384776
## NB: not "GROUPS" -- that is a readonly special bash variable (the
## user's group ids); an assignment to it is silently ignored and it
## expands to gid 20 (staff) on macOS. Caught by the --replace 1 smoke run.
DRAW_GROUPS=8
while [ $# -gt 0 ]; do
  case "$1" in
    --replace) REPLACE="$2"; shift 2 ;;
    --pool) POOL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPLACE" ] || { echo "usage: $0 --replace N [--pool path]" >&2; exit 2; }
[ -f "$POOL" ] || { echo "pool file missing: $POOL" >&2; exit 2; }

BIN=/tmp/rotate-br-pool-bin
mkdir -p "$BIN"
for tool in brmapkit br_spec_to_ctf; do
  if [ ! -x "$BIN/$tool" ] || [ "$REPO_ROOT/tools/$tool.nim" -nt "$BIN/$tool" ]; then
    echo "building $tool (release)..." >&2
    (cd "$REPO_ROOT" && nim c -d:release --hints:off -o:"$BIN/$tool" "tools/$tool.nim")
  fi
done

WORK=$(mktemp -d /tmp/rotate-br-pool.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

NEXT_SEED=$(python3 -c "
import json,sys
pool=json.load(open('$POOL'))
assert isinstance(pool,list) and pool, 'pool must be a non-empty array'
assert $REPLACE <= len(pool), '--replace $REPLACE exceeds pool size %d' % len(pool)
print(max(e['seed'] for e in pool)+1)")

echo "pool: $POOL  replace: $REPLACE  first candidate seed: $NEXT_SEED" >&2
certified=0
attempts=0
seed=$NEXT_SEED
while [ "$certified" -lt "$REPLACE" ]; do
  attempts=$((attempts+1))
  draw="$WORK/br_$seed.json"
  if "$BIN/brmapkit" generate --seed "$seed" --groups "$DRAW_GROUPS" --scale "$SCALE" \
       -o "$draw" > "$WORK/gen_$seed.log" 2>&1 && [ -s "$draw" ]; then
    "$BIN/br_spec_to_ctf" "$draw" -o "$WORK/ctf_$seed.json" > "$WORK/conv_$seed.log" 2>&1
    "$BIN/brmapkit" metrics "$draw" --json -o "$WORK/gates_$seed.json" > "$WORK/met_$seed.log" 2>&1
    if python3 -c "
import json,sys
sys.exit(0 if json.load(open('$WORK/gates_$seed.json'))['pass']['all'] else 1)"; then
      echo "$seed" >> "$WORK/certified.txt"
      certified=$((certified+1))
      echo "certified $certified/$REPLACE: seed $seed ($attempts draws so far)" >&2
    else
      echo "REFUSING seed $seed: written draw failed gates.all re-check" >&2
    fi
  fi
  seed=$((seed+1))
done

python3 - "$POOL" "$WORK" "$REPLACE" "$attempts" <<'PYEOF'
import json, sys, datetime
pool_path, work, replace, attempts = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
pool = json.load(open(pool_path))
size = len(pool)
oldest = sorted(pool, key=lambda e: (e['certifiedAt'], e['seed']))[:replace]
removed = {(e['certifiedAt'], e['seed']) for e in oldest}
kept = [e for e in pool if (e['certifiedAt'], e['seed']) not in removed]
today = datetime.date.today().isoformat()
added = []
for line in open(f'{work}/certified.txt'):
    s = int(line.strip())
    spec = json.load(open(f'{work}/ctf_{s}.json'))
    gates = json.load(open(f'{work}/gates_{s}.json'))['pass']
    assert gates['all'] is True, f'seed {s} not 18/18 — refusing to ship'
    added.append({'name': f'br-gen-{s}', 'seed': s, 'certifiedAt': today,
                  'gates': gates, 'spec': spec})
out = kept + added
assert len(out) == size, f'rotation changed pool size {size} -> {len(out)}'
json.dump(out, open(pool_path, 'w'), indent=2, ensure_ascii=True)
open(pool_path, 'a').write('\n')
print(f'rotated {replace} of {size}: removed ' +
      ', '.join(f"{e['name']} ({e['certifiedAt']})" for e in oldest))
print('added   ' + ', '.join(e['name'] for e in added) +
      f'  ({attempts} draws for {replace} certifications)')
PYEOF
