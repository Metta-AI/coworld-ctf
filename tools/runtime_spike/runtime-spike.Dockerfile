# syntax=docker/dockerfile:1

FROM debian:bookworm-slim AS toolchain-base

ARG TARGETARCH
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    xz-utils && \
  rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in \
    amd64) nimby_asset=nimby-Linux-X64 ;; \
    arm64) nimby_asset=nimby-Linux-ARM64 ;; \
    *) echo "unsupported Docker target architecture: $TARGETARCH" >&2; exit 1 ;; \
  esac && \
  curl -fsSL \
    -o /usr/local/bin/nimby \
    "https://github.com/treeform/nimby/releases/download/0.1.26/$nimby_asset" && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"
WORKDIR /workspace/ctf
COPY nimby.lock .
RUN nimby --global sync nimby.lock

FROM toolchain-base AS wasmtime-c-api

ARG TARGETARCH
RUN case "$TARGETARCH" in \
    amd64) \
      archive=wasmtime-v48.0.1-x86_64-linux-c-api.tar.xz; \
      digest=67683d04b416a8b91f0e607e7b4c22bd32f18f947c10b5372eb8c277ae3b883a ;; \
    arm64) \
      archive=wasmtime-v48.0.1-aarch64-linux-c-api.tar.xz; \
      digest=1c521a9be661644541158b360df8f7c7ec5bc2d88d23ff4dbbc12f639247c266 ;; \
    *) echo "unsupported Docker target architecture: $TARGETARCH" >&2; exit 1 ;; \
  esac && \
  curl -fsSL \
    -o "/tmp/$archive" \
    "https://github.com/bytecodealliance/wasmtime/releases/download/v48.0.1/$archive" && \
  echo "$digest  /tmp/$archive" | sha256sum -c - && \
  mkdir -p /opt/wasmtime-c-api && \
  tar -xJf "/tmp/$archive" --strip-components=1 -C /opt/wasmtime-c-api

FROM toolchain-base AS hello-toolchain

ARG TARGETARCH
RUN nimby use 2.2.6
RUN case "$TARGETARCH" in \
    amd64) \
      archive=wasi-sdk-33.0-x86_64-linux.tar.gz; \
      digest=0ba8b5bfaeb2adf3f29bab5841d76cf5318ab8e1642ea195f88baba1abd47bce ;; \
    arm64) \
      archive=wasi-sdk-33.0-arm64-linux.tar.gz; \
      digest=4f98ee738c7abb45c81a94d1461fc53cc569d1cd01498951c8184d841a027844 ;; \
    *) echo "unsupported Docker target architecture: $TARGETARCH" >&2; exit 1 ;; \
  esac && \
  curl -fsSL \
    -o "/tmp/$archive" \
    "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-33/$archive" && \
  echo "$digest  /tmp/$archive" | sha256sum -c - && \
  mkdir -p /opt/wasi-sdk && \
  tar -xzf "/tmp/$archive" --strip-components=1 -C /opt/wasi-sdk && \
  nim --version && \
  /opt/wasi-sdk/bin/clang --version && \
  touch /opt/hello-toolchain-ready

COPY tools/runtime_spike/hello_config.nims tools/runtime_spike/hello_play.nim tools/runtime_spike/hello_play.nims tools/runtime_spike/hello_imports.h /workspace/ctf/tools/runtime_spike/
RUN mkdir -p /workspace/ctf/tools/runtime_spike/.build && \
  WASI_SDK_PATH=/opt/wasi-sdk \
  nim c /workspace/ctf/tools/runtime_spike/hello_play.nim

FROM toolchain-base AS host-toolchain

COPY --from=wasmtime-c-api /opt/wasmtime-c-api /opt/wasmtime-c-api
COPY --from=hello-toolchain /opt/hello-toolchain-ready /opt/hello-toolchain-ready
COPY --from=hello-toolchain /workspace/ctf/tools/runtime_spike/.build/hello_play.wasm /opt/runtime-spike/hello_play.wasm
COPY tools/runtime_spike/runtime_spike.nim tools/runtime_spike/tick_models.nim tools/runtime_spike/wasm_emitter.nim tools/runtime_spike/wasm_fixtures.nim tools/runtime_spike/wasmtime_c.nim tools/runtime_spike/wasmtime_shim.h /workspace/ctf/tools/runtime_spike/
COPY src /workspace/ctf/src
RUN nim --version && \
  test -f /opt/wasmtime-c-api/include/wasmtime.h && \
  test -f /opt/wasmtime-c-api/lib/libwasmtime.so && \
  test -f /opt/hello-toolchain-ready && \
  nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on \
    --nimcache:/tmp/runtime-spike-nimcache \
    --passC:-I/opt/wasmtime-c-api/include \
    --passC:-I/workspace/ctf/tools/runtime_spike \
    --passL:-L/opt/wasmtime-c-api/lib \
    --passL:-lwasmtime \
    --passL:-Wl,-rpath,/usr/local/lib \
    --out:/opt/runtime-spike/runtime_spike \
    /workspace/ctf/tools/runtime_spike/runtime_spike.nim

FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates && \
  rm -rf /var/lib/apt/lists/*
COPY --from=host-toolchain /opt/wasmtime-c-api/lib/libwasmtime.so /usr/local/lib/libwasmtime.so
COPY --from=host-toolchain /opt/hello-toolchain-ready /opt/hello-toolchain-ready
COPY --from=host-toolchain /opt/runtime-spike /opt/runtime-spike
RUN ldconfig && \
  ldconfig -p | grep -F libwasmtime.so && \
  test -f /opt/hello-toolchain-ready && \
  ldd /opt/runtime-spike/runtime_spike | grep -F /usr/local/lib/libwasmtime.so

ENV RUNTIME_SPIKE_HELLO=/opt/runtime-spike/hello_play.wasm
ENV RUNTIME_SPIKE_CONTAINER_PLATFORM=docker

LABEL org.opencontainers.image.title="coworld-ctf runtime spike"
LABEL org.opencontainers.image.version="wasmtime-v48.0.1"
ENTRYPOINT ["/opt/runtime-spike/runtime_spike"]
CMD ["smoke"]
