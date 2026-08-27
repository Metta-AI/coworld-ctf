#!/bin/bash
# Practice rig for the LIVE renderer lane: one human seat (slot 0) + N bots.
#
# PID DISCIPLINE (fleet rule, after the 2026-08-26 pattern-kill incidents).
# This script kills ONLY the pids it recorded at spawn, from the spawn itself.
# It never uses pkill, killall, pgrep or `lsof -ti <port> | xargs kill`.
#
# Why the previous, "port-scoped" version was still wrong: it enumerated with
# `pgrep -f bin/baseline.out` and then filtered on the port. Enumerating by
# pattern already reaches into every other session's fields and production, and
# the filter is the only thing standing between that reach and a kill -- one bad
# filter, one shared port, one truncated `ps` line and somebody else's
# experiment dies. `lsof -ti tcp:$PORT | xargs kill` was worse: it kills
# whatever holds the port, owner unknown, and 8899 is a port anyone might pick.
#
# If this rig ever leaks a process the pidfile does not know about, the fix is
# to ASK the owning session, never to guess with a pattern.
cd "$(dirname "$0")"
PORT=${PORT:-2137}
BOTS=${BOTS:-7}
PROBE_PORT=${PROBE_PORT:-8899}
PIDFILE=/tmp/ctf-liveview-rig-$PORT.pids

stop_recorded() {
  [ -f "$PIDFILE" ] || return 0
  while read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done < "$PIDFILE"
  rm -f "$PIDFILE"
  sleep 0.5
}

case "$1" in
  stop) stop_recorded; echo "stopped this rig's recorded pids"; exit 0 ;;
esac

stop_recorded
: > "$PIDFILE"

rm -f /tmp/ctf-live-replay.bitreplay
COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
  COGAME_CONFIG_URI=file://$PWD/practice.json \
  COGAME_SAVE_REPLAY_URI=file:///tmp/ctf-live-replay.bitreplay \
  ./bin/ctf-server > /tmp/ctf-live-server.log 2>&1 &
echo $! >> "$PIDFILE"
sleep 1.5

for i in $(seq 1 $BOTS); do
  COWORLD_PLAYER_WS_URL="ws://localhost:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./bin/baseline.out > /tmp/ctf-live-bot-$i.log 2>&1 &
  echo $! >> "$PIDFILE"
done

# The packet-probe static host, owned here so its pid is recorded too rather
# than reclaimed later by port.
if [ "$PROBE_PORT" != "0" ]; then
  ( cd client && exec python3 -m http.server "$PROBE_PORT" ) > /tmp/ctf-probe-host.log 2>&1 &
  echo $! >> "$PIDFILE"
fi

echo "live view : http://localhost:$PORT/client/play?slot=0&token=0xBADA55_0"
echo "stock view: http://localhost:$PORT/client/player?slot=0&token=0xBADA55_0"
echo "pids      : $PIDFILE  (stop with: ./run-practice.sh stop)"
