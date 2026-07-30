#!/bin/bash
# Serves a recorded MW2-map replay to the broadcast viewer for local review.
cd "$(dirname "$0")"
REPLAY="${REPLAY:-mw2-rust-fixture.bitreplay}"
export COGAME_HOST=127.0.0.1 COGAME_PORT="${PORT:-21500}"
export COGAME_LOAD_REPLAY_URI="file://$PWD/$REPLAY"
echo "serving $REPLAY at http://127.0.0.1:${PORT:-21500}/client/replay"
exec ./bin/ctf-server
