#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The amxagent authors
#
# All-core AMX LLM benchmark.
#   1. verifies AMX is present,
#   2. ensures the SGLang CPU backend is up (starts it if needed),
#   3. sweeps client concurrency and reports prefill/decode tok/s + aggregate
#      throughput + per-core CPU utilization.
#
# The benchmark hits the RAW SGLang endpoint (:8000) directly, so it measures the
# all-core AMX inference itself, not the Responses-API proxy. No auth is needed on
# that endpoint locally.
#
# Env overrides:
#   PORT_BACKEND (8000), MODEL (/models), INPUT_TOKENS (512), OUTPUT_TOKENS (256),
#   CONCURRENCY ("1 2 4 8"), REQS_PER_LEVEL (4), KEEP_BACKEND (0),
#   SGLANG_START (path to start_sglang.sh)
set -euo pipefail
umask 077    # any written artifacts owner-only (content protection)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT_BACKEND="${PORT_BACKEND:-8000}"
BACKEND_URL="${BACKEND_URL:-http://localhost:${PORT_BACKEND}}"
MODEL="${MODEL:-/models}"
INPUT_TOKENS="${INPUT_TOKENS:-512}"
OUTPUT_TOKENS="${OUTPUT_TOKENS:-256}"
CONCURRENCY="${CONCURRENCY:-1 2 4 8}"
REQS_PER_LEVEL="${REQS_PER_LEVEL:-4}"

echo "=== AMX / CPU ==="
amx="$(grep -o 'amx[a-z_]*' /proc/cpuinfo | sort -u | paste -sd, - || true)"
if [ -z "${amx}" ]; then
    echo "WARNING: no AMX flags in /proc/cpuinfo — this node is not AMX-capable." >&2
else
    echo "AMX flags     : ${amx}"
fi
echo "physical cores: $(nproc)"
echo "TP_SIZE       : ${TP_SIZE:-<backend default>}"

# pick a python that has httpx (the bundled venv, else system)
PY="${PY:-}"
if [ -z "${PY}" ]; then
    for cand in "/opt/amxagent/venv/bin/python" "${VENV:-}/bin/python" "${SCRIPT_DIR}/../venv/bin/python" python3; do
        [ -n "${cand}" ] && command -v "${cand}" >/dev/null 2>&1 && PY="${cand}" && break
    done
fi
"${PY}" -c "import httpx" 2>/dev/null || { echo "ERROR: '${PY}' lacks httpx. Set PY=/path/to/venv/python." >&2; exit 1; }

# ensure backend
STARTED=0
SGLANG_START="${SGLANG_START:-/opt/amxagent/bin/start_sglang.sh}"
if ! curl -sf "${BACKEND_URL}/health" >/dev/null 2>&1; then
    echo "backend not up; starting via ${SGLANG_START} ..."
    "${SGLANG_START}" start
    STARTED=1
    for _ in $(seq 1 120); do curl -sf "${BACKEND_URL}/health" >/dev/null 2>&1 && break; sleep 2; done
fi
curl -sf "${BACKEND_URL}/health" >/dev/null 2>&1 || { echo "ERROR: backend not reachable at ${BACKEND_URL}" >&2; exit 1; }

cleanup() { [ "${STARTED}" = 1 ] && [ "${KEEP_BACKEND:-0}" = 0 ] && "${SGLANG_START}" stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo
echo "=== LLM throughput sweep (input≈${INPUT_TOKENS}, output=${OUTPUT_TOKENS}) ==="
for c in ${CONCURRENCY}; do
    echo "--- concurrency=${c} ---"
    "${PY}" "${SCRIPT_DIR}/llm_amx_benchmark.py" \
        --backend "${BACKEND_URL}" --model "${MODEL}" \
        --input-tokens "${INPUT_TOKENS}" --output-tokens "${OUTPUT_TOKENS}" \
        --concurrency "${c}" --num-requests "$(( c * REQS_PER_LEVEL ))"
    echo
done
echo "=== done ==="
