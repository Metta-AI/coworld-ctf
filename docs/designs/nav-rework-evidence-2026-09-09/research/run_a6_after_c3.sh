#!/usr/bin/env bash
set -euo pipefail
while kill -0 56947 2>/dev/null; do sleep 15; done
test -f "$HOME/nav-throughput-results-20260909/C3/DONE"
exec bash "$HOME/run_a6_screen.sh"
