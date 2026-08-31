# Lane A body-benchmark image for the x86 freeze input (1-vCPU devbox runs).
# House pattern: the repo root Dockerfile's toolchain pins (debian bookworm,
# nimby 0.1.26, nim 2.2.4, nimby.lock sync). STENCIL-FREE by construction:
# only bench_body.nim (P0 portable rows) and bench_body_port.nim (committed
# port probe) are built; nothing lab-dependent enters the image.
#
# Build (on the devbox):
#   docker build --platform linux/amd64 \
#     -f tools/body_bench/body-bench.Dockerfile -t ctf-body-bench:amd64 .
# Run (quota mechanism aligned to lane C's runbook):
#   docker run --rm --platform linux/amd64 --cpus 1 -v $OUT:/out \
#     ctf-body-bench:amd64 free --seeds ... --output /out/....json
#   docker run --rm --platform linux/amd64 --cpus 1 -v $OUT:/out \
#     ctf-body-bench:amd64 port --seeds ... --output /out/....json
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/ctf
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
RUN nim c -d:release --nimcache:/tmp/bench-free-nimcache \
    --out:bench_body tools/bench_body.nim && \
  nim c -d:release --nimcache:/tmp/bench-port-nimcache \
    --out:bench_body_port tools/bench_body_port.nim

# Run image: the two binaries plus the fixture the port probe reads at
# runtime, laid out at the repo-relative path it expects.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/ctf
COPY --from=build /workspace/ctf/bench_body /bin/bench_body
COPY --from=build /workspace/ctf/bench_body_port /bin/bench_body_port
COPY --from=build /workspace/ctf/tests/fixtures/br-golden-map.json \
  tests/fixtures/br-golden-map.json

COPY <<'EOF' /bin/bench-entry.sh
#!/bin/sh
set -e
kind="$1"
shift
case "$kind" in
  free) exec /bin/bench_body "$@" ;;
  port) exec /bin/bench_body_port "$@" ;;
  *) echo "usage: (free|port) [bench args...]" >&2; exit 2 ;;
esac
EOF
RUN chmod +x /bin/bench-entry.sh

ENTRYPOINT ["/bin/bench-entry.sh"]
