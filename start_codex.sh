#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The amxagent authors
# codex launcher. Expects the backend (SGLang + proxy) to be up already.
set -e
umask 077    # codex rollout/state + config owner-only (content protection)

PORT_BACKEND="${PORT_BACKEND:-8000}"
PORT_PROXY="${PORT_PROXY:-8001}"
AMXAGENT_REQUIRE_AUTH="${AMXAGENT_REQUIRE_AUTH:-1}"
AUTH_HOME="${HOME:-/tmp}"
AUTH_TOKEN_FILE="${AMXAGENT_AUTH_FILE:-${AUTH_HOME}/.codex/amxagent_proxy.key}"

# Render the codex config on first use so the CLI knows to talk to the local
# proxy. Lives in the (bind-mounted) host home; override dir via CODEX_HOME.
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$CODEX_HOME"; chmod 700 "$CODEX_HOME" 2>/dev/null || true   # lock rollout/state dir
CONFIG="${CODEX_HOME}/config.toml"
TEMPLATE="${TEMPLATE:-/opt/amxagent/config.toml.template}"
if [ ! -f "$CONFIG" ] && [ -f "$TEMPLATE" ]; then
    mkdir -p "$CODEX_HOME"
    sed "s|{{MODEL}}|${MODEL:-/models}|g" "$TEMPLATE" > "$CONFIG"
    echo "Wrote codex config -> $CONFIG (model=${MODEL:-/models})"
fi

if [ "${AMXAGENT_REQUIRE_AUTH}" != "0" ]; then
    if { [ -z "${OPENAI_API_KEY:-}" ] || [ "${OPENAI_API_KEY}" = "dummy" ]; } && [ -s "${AUTH_TOKEN_FILE}" ]; then
        export OPENAI_API_KEY="$(cat "${AUTH_TOKEN_FILE}")"
    fi
    if [ -z "${OPENAI_API_KEY:-}" ] || [ "${OPENAI_API_KEY}" = "dummy" ]; then
        echo "ERROR: proxy auth is enabled but no API key is available."
        echo "       Start the backend first or set AMXAGENT_AUTH_FILE / OPENAI_API_KEY."
        exit 1
    fi
else
    export OPENAI_API_KEY="${OPENAI_API_KEY:-dummy}"
fi

if ! curl -sf "http://localhost:${PORT_BACKEND}/health" > /dev/null 2>&1; then
    echo "ERROR: SGLang (:${PORT_BACKEND}) is not responding. Run ./start_sglang.sh first."
    exit 1
fi
if ! curl -so /dev/null -w "%{http_code}" "http://localhost:${PORT_PROXY}/" 2>/dev/null | grep -qE "200|404"; then
    echo "ERROR: Proxy (:${PORT_PROXY}) is not responding. Run ./start_sglang.sh first."
    exit 1
fi

echo "Backend OK (SGLang :${PORT_BACKEND} + Proxy :${PORT_PROXY})"
exec codex "$@"
