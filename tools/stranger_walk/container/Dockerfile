# tools/stranger_walk/container/Dockerfile — Stranger Walk protocol v1.4
#
# Gives the stranger process its OWN Linux PID namespace, filesystem, and
# network namespace, instead of running as a bare `claude -p` process on the
# host. Closes the process-table visibility gap from Walk 1: `sonnet-c` ran
# `ps aux | grep -E "coworld|upload"` — ordinary behavior for a stranger
# checking on its own backgrounded upload — and saw the HOST's entire
# process table, because a fresh $HOME (run.sh's isolation mechanism)
# scopes environment variables, not the OS-level process list. See
# docs/designs/STRANGER_WALK.md, "Isolation gap found in Walk 1, NOT fixed"
# and the v1.3 protocol section.
#
# This image is intentionally plain: a competent developer's normal toolbox
# (git, curl, python3, uv, the docker CLI) plus the Claude Code CLI itself.
# It carries NO Softmax/Paintbot-specific tooling, credentials, or paths —
# only tools/stranger_walk/{entrypoint.sh,probe.sh} and the run dir (bind
# mounted at container run time by run_container.sh) know anything about
# this project.
#
# v1.4 adds a browser: Walk 1's strangers needed one (GitHub OAuth sign-in,
# watching replays) and container mode previously had none at all
# (`browser_enabled` was hardcoded `false` — see docs/designs/STRANGER_WALK.md
# v1.3, "What v1.3 still does not close: No browser inside the container").
# Two independent browser stacks share one Chromium download location
# ($PLAYWRIGHT_BROWSERS_PATH below): the Python `playwright` package (used by
# `entrypoint.sh`'s `selftest` mode for a scripted, no-credential screenshot
# proof) and the Node `@playwright/mcp` server (what the stranger's own
# `claude -p` session actually gets wired to via `--mcp-config`, mirroring
# `run.sh`'s existing host-mode browser wiring — see that script's header).
# If their exact browser revisions don't line up, each downloads its own
# revision subfolder into the same path at build time — no conflict, just a
# few hundred extra MB in the image; simpler and more robust than chasing
# exact version parity between the two ecosystems.
FROM node:20-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      curl \
      ca-certificates \
      python3 \
      python3-pip \
      python3-venv \
      jq \
      sqlite3 \
      procps \
      docker.io \
    && rm -rf /var/lib/apt/lists/*
# `docker.io` installs the `docker` CLIENT binary (what a stranger sees on
# PATH if it decides to `docker build` a policy image) alongside a dockerd
# binary this image never starts. With no socket mounted, `docker` inside
# the container cannot reach ANY daemon — host or otherwise — and every
# subcommand fails with "Cannot connect to the Docker daemon". That is the
# default, deliberate posture. run_container.sh's optional
# --enable-docker-socket flag mounts the HOST's /var/run/docker.sock to
# change this — see that script's header and docs/designs/STRANGER_WALK.md
# v1.3 for exactly what that flag exposes (root-equivalent host access) and
# why it defaults off.

# uv (fast Python package/venv manager) — a plausible thing a stranger
# developer reaches for when it starts building a policy.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Claude Code CLI itself — the stranger's own tool. Pinned loosely to
# whatever `latest` resolves to at build time; rebuild the image to pick up
# a newer release (there is no isolation reason to pin harder here — the
# stranger is a normal user of this tool, not testing it).
RUN npm install -g @anthropic-ai/claude-code

# v1.4: headless Chromium, two ways in. Shared download location, chmod'd
# world-readable+executable at the end so the RUNTIME non-root user (always
# the invoking host's own uid:gid — see the no-USER-directive note below,
# never the root this file builds as) can actually launch the browser.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers

# 1. The Node MCP server — what the stranger's `claude -p` session is
#    actually wired to via `--mcp-config` (see entrypoint.sh), same
#    `@playwright/mcp` package `run.sh` already uses for host-mode runs.
RUN npm install -g playwright @playwright/mcp@latest \
    && npx --yes playwright install --with-deps chromium

# 2. Python playwright — used by entrypoint.sh's `selftest` mode to prove
#    the browser mechanism with a scripted, no-Anthropic-credential-needed
#    screenshot fetch (see that script). Debian bookworm's system pip is
#    PEP 668 "externally managed" — --break-system-packages is deliberate,
#    this is a throwaway container image, not a host Python environment.
RUN pip3 install --no-cache-dir --break-system-packages playwright \
    && python3 -m playwright install --with-deps chromium \
    && chmod -R a+rX /opt/playwright-browsers

RUN mkdir -p /home/stranger
WORKDIR /home/stranger
ENV HOME=/home/stranger

COPY entrypoint.sh /entrypoint.sh
COPY probe.sh /probe.sh
RUN chmod +x /entrypoint.sh /probe.sh

# No USER directive: `run_container.sh` always launches this image with
# `docker run --user "$(id -u):$(id -g)"` — the INVOKING HOST USER's own
# uid:gid, never root. Found empirically while building this: `claude`'s own
# `--permission-mode bypassPermissions` (required for any non-interactive
# `-p` run) refuses to start as root/sudo ("cannot be used with root/sudo
# privileges for security reasons"), so a root-in-container stranger cannot
# run at all — and matching the host uid also means the bind-mounted run dir
# (host-owned) needs no chmod. See run_container.sh's header for the full
# rationale. (Building/pulling this image directly with plain `docker run`,
# with no --user override, WOULD run as root — don't do that for a `run`
# invocation; `probe`/`selftest` tolerate it, `run` will fail claude's own
# guard.)
ENTRYPOINT ["/entrypoint.sh"]
