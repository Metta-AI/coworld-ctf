## Prints the bot's tunable-constant registry as JSON and exits.
## Build & run:  nim r players/baseline/dump_tunables.nim > tunables.json
## Consumed by the tuning harness (cogamer: cogames/ctf/team/bin/tune.py
## sync-params --manifest tunables.json).

import baseline/params

when isMainModule:
  echo tunablesManifest()
