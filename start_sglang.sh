#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The amxagent authors
# SGLang CPU backend + Responses-API proxy launcher.
#
# Layout assumed (created by README install steps):
#   amxagent/
#     ├── venv/                       Python venv with sglang + sgl-kernel-cpu
#     ├── sglang/                     SGLang source (patched, used for layout only)
#     ├── responses_proxy.py
#     └── models/<model-dir>/         HF snapshot of the model
#
# Usage:  ./start_sglang.sh {start|stop|status}

set -e
umask 077    # sglang.log / proxy.log / pid files owner-only (content protection)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Locate responses_proxy.py. Host layout keeps it beside this script; the
# Apptainer image puts this script in bin/ with the proxy one level up. Allow
# an explicit override via PROXY_PY, otherwise search the likely locations.
if [ -z "${PROXY_PY:-}" ]; then
    for cand in \
        "${SCRIPT_DIR}/responses_proxy.py" \
        "${SCRIPT_DIR}/../responses_proxy.py" \
        "/opt/amxagent/responses_proxy.py"; do
        if [ -f "$cand" ]; then PROXY_PY="$(cd "$(dirname "$cand")" && pwd)/$(basename "$cand")"; break; fi
    done
fi

VENV="${VENV:-${SCRIPT_DIR}/venv}"
MODEL="${MODEL:-${SCRIPT_DIR}/models/gemma-4-26B-A4B-it}"
PORT_BACKEND="${PORT_BACKEND:-8000}"
PORT_PROXY="${PORT_PROXY:-8001}"
# Bind same-node only. All traffic (codex→proxy→SGLang) is localhost, so there is
# no reason to expose ports on a shared host network. Override only if proxy
# and backend run on different hosts.
HOST_BIND="${HOST_BIND:-127.0.0.1}"
TP_SIZE="${TP_SIZE:-4}"
CHUNKED_PREFILL_SIZE="${CHUNKED_PREFILL_SIZE:-2048}"
AMXAGENT_REQUIRE_AUTH="${AMXAGENT_REQUIRE_AUTH:-1}"
TRUST_REMOTE_CODE="${TRUST_REMOTE_CODE:-1}"
AMXAGENT_LOG_MODEL_OUTPUT="${AMXAGENT_LOG_MODEL_OUTPUT:-0}"
# KV-cache sizing. Without these, SGLang auto-grabs ~90% of RAM and reserves a
# KV pool for ~1.8M tokens / 3531 concurrent reqs (86 GB/worker). This is a
# single-user CLI coding agent (codex context = 32K), so cap context and the
# total token pool explicitly. Drops total RSS from ~428 GB to ~90 GB with no
# numeric/quality change (weights stay BF16, KV stays bf16).
CONTEXT_LENGTH="${CONTEXT_LENGTH:-32768}"
MAX_TOTAL_TOKENS="${MAX_TOTAL_TOKENS:-65536}"
MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-2}"
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}}"
AUTH_HOME="${HOME:-/tmp}"
AUTH_TOKEN_FILE="${AMXAGENT_AUTH_FILE:-${AUTH_HOME}/.codex/amxagent_proxy.key}"

# Required for SGLang CPU mode
export SGLANG_USE_CPU_ENGINE=1
# Use native PyTorch KV cache copy (Triton is GPU-only)
export SGLANG_NATIVE_MOVE_KV_CACHE=1

# Intel OpenMP tuning. Do NOT set KMP_AFFINITY — SGLang manages thread binding
# itself via init_cpu_threads_env(). External KMP_AFFINITY breaks NUMA detection
# and segfaults TP workers.
export KMP_BLOCKTIME=1
export KMP_TPAUSE=0
export KMP_FORKJOIN_BARRIER_PATTERN="dist,dist"
export KMP_PLAIN_BARRIER_PATTERN="dist,dist"
export KMP_REDUCTION_BARRIER_PATTERN="dist,dist"

# Pre-load tcmalloc + Intel OpenMP. libiomp5 is provided either by the venv's
# torch install or by Intel oneAPI; let the user point LD_PRELOAD via env.
if [ -z "${LD_PRELOAD:-}" ]; then
    _IOMP=""
    for cand in \
        "${VENV}/lib/libiomp5.so" \
        "/opt/intel/oneapi/compiler/latest/lib/libiomp5.so" \
        "/usr/lib/x86_64-linux-gnu/libiomp5.so"; do
        if [ -f "$cand" ]; then _IOMP="$cand"; break; fi
    done
    # Preload exactly ONE allocator. Stacking tcmalloc + tcmalloc_minimal +
    # tbbmalloc together makes them fight over the heap ("Attempt to free
    # invalid pointer") and aborts even basic tools like fuser/sleep.
    _LIBS=""
    for cand in \
        "/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4" \
        "/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4" \
        "/usr/lib/x86_64-linux-gnu/libtbbmalloc.so.2"; do
        if [ -f "$cand" ]; then _LIBS="$cand"; break; fi
    done
    if [ -n "$_IOMP" ]; then _LIBS="${_LIBS}${_LIBS:+:}$_IOMP"; fi
    if [ -n "$_LIBS" ]; then export LD_PRELOAD="$_LIBS"; fi
fi

# Activate venv if present
if [ -f "${VENV}/bin/activate" ]; then
    # shellcheck disable=SC1091
    source "${VENV}/bin/activate"
fi

ensure_proxy_api_key() {
    if [ "${AMXAGENT_REQUIRE_AUTH}" = "0" ]; then
        unset PROXY_API_KEY
        return
    fi

    mkdir -p "$(dirname "${AUTH_TOKEN_FILE}")"
    if [ -n "${OPENAI_API_KEY:-}" ] && [ "${OPENAI_API_KEY}" != "dummy" ]; then
        _key="${OPENAI_API_KEY}"
    elif [ -s "${AUTH_TOKEN_FILE}" ]; then
        _key="$(cat "${AUTH_TOKEN_FILE}")"
    else
        _key="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        umask 077
        printf '%s' "${_key}" > "${AUTH_TOKEN_FILE}"
    fi
    chmod 600 "${AUTH_TOKEN_FILE}" 2>/dev/null || true
    export OPENAI_API_KEY="${_key}"
    export PROXY_API_KEY="${_key}"
}

# Stop ONLY the processes this launcher started (tracked via pid files). Never
# `fuser -k <port>` or `pkill -f <name>`: those hit co-tenants / unrelated
# same-user processes on a shared host or multi-instance setup.
stop_tracked() {
    for pf in "${LOG_DIR}/sglang.pid" "${LOG_DIR}/proxy.pid"; do
        [ -f "${pf}" ] || continue
        _p="$(cat "${pf}" 2>/dev/null || true)"
        if [ -n "${_p}" ] && kill -0 "${_p}" 2>/dev/null; then
            pkill -TERM -P "${_p}" 2>/dev/null || true
            kill  -TERM "${_p}"    2>/dev/null || true
            for _ in 1 2 3 4 5; do kill -0 "${_p}" 2>/dev/null || break; sleep 1; done
            pkill -KILL -P "${_p}" 2>/dev/null || true
            kill  -KILL "${_p}"    2>/dev/null || true
        fi
        rm -f "${pf}"
    done
}

case "${1:-start}" in
    start)
        if [ ! -d "${MODEL}" ]; then
            echo "ERROR: model dir not found: ${MODEL}"
            echo "       set MODEL=... or place the snapshot at the default path."
            exit 1
        fi

        echo "=== SGLang CPU + Responses-API proxy ==="
        echo "Model        : ${MODEL}"
        echo "Backend port : ${PORT_BACKEND}"
        echo "Proxy port   : ${PORT_PROXY}"
        echo "TP size      : ${TP_SIZE}"
        echo "Auth required: ${AMXAGENT_REQUIRE_AUTH}"

        if [ "${TRUST_REMOTE_CODE}" = "1" ]; then
            TRUST_REMOTE_CODE_FLAG=(--trust-remote-code)
            echo "Remote code  : enabled"
        else
            TRUST_REMOTE_CODE_FLAG=()
            echo "Remote code  : disabled"
        fi

        ensure_proxy_api_key
        export AMXAGENT_LOG_MODEL_OUTPUT
        if [ "${AMXAGENT_REQUIRE_AUTH}" != "0" ]; then
            echo "Auth file    : ${AUTH_TOKEN_FILE}"
        fi

        # Clear only a previous instance started by THIS launcher (tracked PIDs);
        # never blast the port or pkill by name (shared-host / multi-instance safety).
        stop_tracked
        sleep 1

        echo "Starting SGLang on :${PORT_BACKEND} ..."
        numactl --interleave=all python -m sglang.launch_server \
            --model "${MODEL}" \
            --device cpu \
            --host "${HOST_BIND}" \
            --port "${PORT_BACKEND}" \
            "${TRUST_REMOTE_CODE_FLAG[@]}" \
            --disable-overlap-schedule \
            --tp "${TP_SIZE}" \
            --disable-cuda-graph \
            --chunked-prefill-size "${CHUNKED_PREFILL_SIZE}" \
            --context-length "${CONTEXT_LENGTH}" \
            --max-total-tokens "${MAX_TOTAL_TOKENS}" \
            --max-running-requests "${MAX_RUNNING_REQUESTS}" \
            > "${LOG_DIR}/sglang.log" 2>&1 &
        BACKEND_PID=$!; echo "${BACKEND_PID}" > "${LOG_DIR}/sglang.pid"
        echo "Backend PID: ${BACKEND_PID}"

        echo "Waiting for backend (model load can take ~30s) ..."
        for i in $(seq 1 600); do
            if curl -s "http://localhost:${PORT_BACKEND}/health" > /dev/null 2>&1; then
                echo "Backend ready."
                break
            fi
            if [ "$i" -eq 600 ]; then
                echo "ERROR: backend failed to start. See ${LOG_DIR}/sglang.log"
                exit 1
            fi
            sleep 2
        done

        echo "Starting proxy on :${PORT_PROXY} ..."
        python "${PROXY_PY:-${SCRIPT_DIR}/responses_proxy.py}" \
            --host "${HOST_BIND}" \
            --port "${PORT_PROXY}" \
            --backend "http://localhost:${PORT_BACKEND}" \
            > "${LOG_DIR}/proxy.log" 2>&1 &
        PROXY_PID=$!; echo "${PROXY_PID}" > "${LOG_DIR}/proxy.pid"
        echo "Proxy PID: ${PROXY_PID}"

        echo ""
        echo "=== Ready ==="
        echo "  ./start_codex.sh"
        ;;

    stop)
        echo "Stopping (tracked PIDs only) ..."
        stop_tracked
        echo "Done."
        ;;

    status)
        echo "=== Status ==="
        if curl -s "http://localhost:${PORT_BACKEND}/health" > /dev/null 2>&1; then
            echo "Backend (:${PORT_BACKEND}): RUNNING"
        else
            echo "Backend (:${PORT_BACKEND}): NOT RUNNING"
        fi
        if curl -so /dev/null -w "%{http_code}" "http://localhost:${PORT_PROXY}/" 2>/dev/null | grep -qE "200|404"; then
            echo "Proxy   (:${PORT_PROXY}): RUNNING"
        else
            echo "Proxy   (:${PORT_PROXY}): NOT RUNNING"
        fi
        ;;

    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
