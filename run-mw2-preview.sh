#!/bin/bash
# Serves a recorded MW2-map episode to the broadcast viewer for review.
# Usage: MAP=afghan ./run-mw2-preview.sh   (default: rust)
# Replays are recorded by:
#   PORT=21071 tools/record_fixture.sh mw2-<map>-play.bitreplay 42 5000 '{"mapPath":"<map>"}'
cd "$(dirname "$0")"
MAP="${MAP:-rust}"
REPLAY="${REPLAY:-mw2-$MAP-play.bitreplay}"
export COGAME_HOST=127.0.0.1 COGAME_PORT="${PORT:-21500}"
export COGAME_LOAD_REPLAY_URI="file://$PWD/$REPLAY"
echo "serving $REPLAY at http://127.0.0.1:${PORT:-21500}/client/replay?fixtures=file://$PWD"
exec ./bin/ctf-server
