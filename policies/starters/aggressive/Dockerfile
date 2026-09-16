# The AGGRESSIVE starter policy image. Build from the REPOSITORY ROOT (the
# playbook is compiled from play_sdk/ during the build):
#
#   docker build -f policies/starters/aggressive/Dockerfile -t starter-aggressive .
#
# Run against a play seat (canned = offline, no model credentials):
#
#   docker run --rm -e POC_HOST=host.docker.internal -e POC_PORT=21815 \
#     -e POC_SLOT=0 -e POC_TOKEN=<token> starter-aggressive --canned
#
# The three starter Dockerfiles are identical except for the persona
# directory they copy and the entrypoint. No model credentials are baked in;
# backends select exactly as in the PoC (hosted sidecar > OPENROUTER_API_KEY
# > canned) -- see policies/poc_llm_policy/README.md.

# ── Stage 1: compile the playbook (every reference play) ──────────────────
# Pinned to linux/amd64 because the official Nim image publishes no arm64
# manifest; wasm is architecture-neutral.
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
COPY play_sdk ./play_sdk
COPY tools/runtime_spike ./tools/runtime_spike
COPY policies/starters/common/build_playbook.sh ./policies/starters/common/
RUN chmod +x policies/starters/common/build_playbook.sh \
    && policies/starters/common/build_playbook.sh /playbook

# ── Stage 2: the harness ──────────────────────────────────────────────────
FROM python:3.12-slim

RUN pip install --no-cache-dir "websockets>=13"

WORKDIR /app
COPY policies/poc_llm_policy/wire.py \
     policies/poc_llm_policy/brain.py \
     policies/poc_llm_policy/poc_policy.py ./policies/poc_llm_policy/
COPY policies/starters/common/plays.py \
     policies/starters/common/starter_harness.py ./policies/starters/common/
COPY policies/starters/aggressive/policy.py \
     policies/starters/aggressive/system_prompt.md \
     ./policies/starters/aggressive/
COPY --from=playbook /playbook /app/playbook

ENV POC_PLAYBOOK=/app/playbook \
    POC_HOST=127.0.0.1 \
    POC_PORT=21815 \
    POC_SLOT=0 \
    PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "/app/policies/starters/aggressive/policy.py"]
