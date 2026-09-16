#!/bin/bash
# TEMPORARY: find one more pinned seed whose brpool16 draw is neither
# br-gen-5204 nor br-gen-5263, then run it at 16 and 32 seats.
set -uo pipefail
cd "$(dirname "$0")/.."
E=docs/designs/nav-rework-evidence-2026-09-09/research/cache-trace
port=21911
for seed in 679965 679966 679967 679968 679969; do
  python3 - "$seed" "$E" <<'PY'
import json, sys
seed = int(sys.argv[1]); E = sys.argv[2]
m = json.load(open('coworld_manifest_paintbot.json'))
base = [v for v in m['variants'] if v.get('name') == 'Battle Royale — Season 2'][0]['game_config']
c16 = json.loads(json.dumps(base)); c16['seed'] = seed
json.dump(c16, open(f'{E}/cfg_s2_16_{seed}.json', 'w'), indent=1)
c32 = json.loads(json.dumps(base)); c32['seed'] = seed
c32['slots'] = base['slots'] + base['slots']; c32['players'] = [{'name': f'Player{i+1}'} for i in range(32)]
c32['num_agents'] = 32; c32['minPlayers'] = 32
json.dump(c32, open(f'{E}/cfg_s2_32_{seed}.json', 'w'), indent=1)
PY
  tag="s2_16_$seed"
  echo "=== $tag port $port $(date -u +%FT%TZ)"
  NAVSRC_WAIT_LIMIT_S=2400 tools/nav_source_trace_run.sh "$E/cfg_${tag}.json" "$tag" "$port" || echo "run $tag FAILED"
  port=$((port + 1))
  map=$(grep -m1 '^NAVSRC sys' "tmp/navsrc/runs/$tag/server.log" | grep -o 'map=[^ ]*')
  echo "seed $seed drew $map"
  case "$map" in
    *5204|*5263) echo "repeat map; trying next seed"; continue ;;
  esac
  tag="s2_32_$seed"
  echo "=== $tag port $port $(date -u +%FT%TZ)"
  NAVSRC_WAIT_LIMIT_S=2400 tools/nav_source_trace_run.sh "$E/cfg_${tag}.json" "$tag" "$port" || echo "run $tag FAILED"
  break
done
echo "EXTRA DONE $(date -u +%FT%TZ)"
