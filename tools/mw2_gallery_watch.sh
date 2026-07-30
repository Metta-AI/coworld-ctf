#!/bin/bash
# Watches for delivered MW2 map snippets and floor art, rebuilding the gallery
# whenever any of them changes. The gallery page itself polls status.json every
# 5s, so a browser left open at the gallery URL updates on its own.
# Usage: tools/mw2_gallery_watch.sh   (Ctrl-C to stop)
cd "$(dirname "$0")/.."
LAST=""
while true; do
  # Fingerprint every input: the six map snippets and the six floor textures.
  NOW=$(ls -la /tmp/mw2map_*.nim data/*_floor.png 2>/dev/null | md5)
  if [ "$NOW" != "$LAST" ]; then
    echo "[$(date +%H:%M:%S)] inputs changed — regenerating gallery"
    python3 tools/mw2_gallery_regen.py 2>&1 | tail -3
    LAST="$NOW"
  fi
  sleep 10
done
