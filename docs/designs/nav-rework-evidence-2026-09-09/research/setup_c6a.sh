#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.nimby/nim/bin:$PATH"
sudo apt-get update
sudo apt-get install -y --no-install-recommends build-essential ca-certificates curl git xz-utils libcurl4-openssl-dev
# Match the inherited Xeon comparison. Production Docker compiler is checked separately.
nimby use 2.2.6
git clone "$HOME/nav-throughput-baseline-20260909.bundle" "$HOME/coworld-nav-throughput-20260909"
cd "$HOME/coworld-nav-throughput-20260909"
git checkout --detach 20234cc7
nimby --global sync nimby.lock
tools/runtime_spike/fetch_deps.sh > "$HOME/nav-throughput-runtime-deps.env"
nim --version
lscpu
printf 'C6A SETUP DONE\n'
