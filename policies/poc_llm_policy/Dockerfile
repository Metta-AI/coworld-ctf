# The PoC policy image: the harness plus a playbook of wasm plays baked in.
#
# Build from the REPOSITORY ROOT, because the playbook is compiled from
# play_sdk/ during the image build:
#
#   docker build -f policies/poc_llm_policy/Dockerfile -t poc-llm-policy .
#
# Run against a play seat:
#
#   docker run --rm --network host \
#     -e POC_HOST=127.0.0.1 -e POC_PORT=21815 \
#     -e POC_SLOT=0 -e POC_TOKEN=0xBADA55_0 \
#     poc-llm-policy --canned
#
# NO MODEL CREDENTIALS ARE BAKED IN, and none should be. In a hosted
# tournament the platform injects AWS_ENDPOINT_URL_BEDROCK_RUNTIME and
# BEDROCK_MODEL into the pod and the harness takes the Bedrock sidecar path on
# its own; upload with `--use-bedrock --bedrock-model <id>`. For local
# development only, pass your own `-e OPENROUTER_API_KEY=...`.

# ── Stage 1: compile the playbook ─────────────────────────────────────────
# Pinned to linux/amd64 because the official Nim image publishes no arm64
# manifest. Wasm is architecture-neutral, so an emulated builder produces
# modules the engine loads identically; only the runtime stage follows the
# host. (The blobs are not byte-identical to a host build -- the generated C
# carries build-path detail -- so the server's module_ready sha256 for `pact`
# differs between an image build and a `build_playbook.sh` run.)
FROM --platform=linux/amd64 nimlang/nim:2.2.6 AS playbook

ARG WASI_SDK_VERSION=33
ARG WASI_SDK_RELEASE=33.0
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)  wasi_target=x86_64-linux ;; \
      aarch64) wasi_target=arm64-linux ;; \
      *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;; \
    esac; \
    archive="wasi-sdk-${WASI_SDK_RELEASE}-${wasi_target}.tar.gz"; \
    curl -fsSL -o /tmp/wasi-sdk.tar.gz \
      "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION}/${archive}"; \
    mkdir -p /opt/wasi-sdk; \
    tar -xzf /tmp/wasi-sdk.tar.gz --strip-components=1 -C /opt/wasi-sdk; \
    rm /tmp/wasi-sdk.tar.gz
ENV WASI_SDK_PATH=/opt/wasi-sdk

WORKDIR /src
# The playbook build reads only the play SDK and the build script; nothing
# else from the repo is needed to produce the wasm blobs.
COPY play_sdk ./play_sdk
COPY tools/runtime_spike ./tools/runtime_spike
COPY policies/poc_llm_policy/build_playbook.sh ./policies/poc_llm_policy/
RUN chmod +x policies/poc_llm_policy/build_playbook.sh \
    && policies/poc_llm_policy/build_playbook.sh /playbook

# ── Stage 2: the harness ──────────────────────────────────────────────────
FROM python:3.12-slim

RUN pip install --no-cache-dir "websockets>=13"

WORKDIR /app
COPY policies/poc_llm_policy/wire.py \
     policies/poc_llm_policy/brain.py \
     policies/poc_llm_policy/poc_policy.py ./
COPY --from=playbook /playbook /app/playbook

ENV POC_PLAYBOOK=/app/playbook \
    POC_HOST=127.0.0.1 \
    POC_PORT=21815 \
    POC_SLOT=0 \
    PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "/app/poc_policy.py"]
