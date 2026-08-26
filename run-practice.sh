#!/bin/bash
# Practice rig for the LIVE renderer lane: one human seat (slot 0) + N bots.
# Serve-forever (maxGames 0) and a low minPlayers, so an iteration is a page
# reload rather than a relaunch of the server and every bot.
#
# PORT-SCOPED ON PURPOSE. Sibling lanes run their own servers and bots on this
# machine; a bare `pkill baseline.out` takes theirs down too. Everything here
# matches on this port's own websocket URL.
cd "$(dirname "$0")"
PORT=${PORT:-2137}
BOTS=${BOTS:-7}
pkill -f "ctf-server.*$PORT" 2>/dev/null
pkill -f "COGAME_PORT=$PORT" 2>/dev/null
for pid in $(pgrep -f 'bin/baseline.out'); do
  if ps eww "$pid" 2>/dev/null | grep -q "localhost:$PORT/player"; then kill "$pid"; fi
done
lsof -ti tcp:$PORT 2>/dev/null | xargs -r kill 2>/dev/null
sleep 0.5
rm -f /tmp/ctf-live-replay.bitreplay
COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
  COGAME_CONFIG_URI=file://$PWD/practice.json \
  COGAME_SAVE_REPLAY_URI=file:///tmp/ctf-live-replay.bitreplay \
  ./bin/ctf-server > /tmp/ctf-live-server.log 2>&1 &
sleep 1.5
for i in $(seq 1 $BOTS); do
  COWORLD_PLAYER_WS_URL="ws://localhost:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./bin/baseline.out > /tmp/ctf-live-bot-$i.log 2>&1 &
done
echo "live view : http://localhost:$PORT/client/play?slot=0&token=0xBADA55_0"
echo "stock view: http://localhost:$PORT/client/player?slot=0&token=0xBADA55_0"
