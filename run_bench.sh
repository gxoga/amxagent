#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The amxagent authors
# Full non-interactive benchmark lifecycle, INSIDE the container.
#   start SGLang+proxy  ->  wait for health  ->  codex exec <prompt>  ->  stop
#
# This is the non-interactive batch execution model: one self-contained run that needs
# no foreground keepalive and no interactive TUI. The backend lives only for
# the duration of the codex task, then is torn down on exit.
#
# Prompt resolution (first non-empty wins):
#   1. "$1"                      (positional arg)
#   2. $BENCH_PROMPT             (env)
#   3. $BENCH_PROMPT_FILE        (path to a file holding the prompt)
#
# Other env knobs:
#   BENCH_WORKDIR  working dir codex operates in   (default /work)
#   BENCH_OUTPUT   file to capture the final agent message (default $WORKDIR/codex_last_message.txt)
#   MODEL          model path inside container     (default /models)
#   TP_SIZE, PORT_BACKEND, PORT_PROXY, CHUNKED_PREFILL_SIZE  -> forwarded to start_sglang.sh
set -euo pipefail
umask 077    # codex rollout/state + artifacts owner-only (content protection)

PORT_BACKEND="${PORT_BACKEND:-8000}"
PORT_PROXY="${PORT_PROXY:-8001}"
WORKDIR="${BENCH_WORKDIR:-/work}"
OUTFILE="${BENCH_OUTPUT:-${WORKDIR}/codex_last_message.txt}"

# ---- resolve prompt ----------------------------------------------------------
PROMPT="${1:-}"
if [ -z "${PROMPT}" ] && [ -n "${BENCH_PROMPT:-}" ]; then
    PROMPT="${BENCH_PROMPT}"
fi
if [ -z "${PROMPT}" ] && [ -n "${BENCH_PROMPT_FILE:-}" ] && [ -f "${BENCH_PROMPT_FILE}" ]; then
    PROMPT="$(cat "${BENCH_PROMPT_FILE}")"
fi
if [ -z "${PROMPT}" ]; then
    echo "ERROR: no prompt. Pass as arg, or set BENCH_PROMPT / BENCH_PROMPT_FILE." >&2
    exit 2
fi

mkdir -p "${WORKDIR}"

# ---- render codex config (points at the local proxy) -------------------------
CODEX_HOME="${CODEX_HOME:-${WORKDIR}/.codex}"
export CODEX_HOME
mkdir -p "${CODEX_HOME}"
chmod 700 "${CODEX_HOME}" 2>/dev/null || true   # lock the dir holding rollout/state
sed "s|{{MODEL}}|${MODEL:-/models}|g" /opt/amxagent/config.toml.template > "${CODEX_HOME}/config.toml"
export AMXAGENT_AUTH_FILE="${AMXAGENT_AUTH_FILE:-${CODEX_HOME}/amxagent_proxy.key}"
AMXAGENT_REQUIRE_AUTH="${AMXAGENT_REQUIRE_AUTH:-1}"

# ---- tear down the backend no matter how we exit -----------------------------
cleanup() { /opt/amxagent/bin/start_sglang.sh stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

# ---- 1. start backend (start_sglang.sh blocks until /health is ready) --------
echo "=== [run_bench] starting backend ==="
/opt/amxagent/bin/start_sglang.sh start

# ---- 2. wait for the proxy (codex talks to :PORT_PROXY) ----------------------
echo "=== [run_bench] waiting for proxy on :${PORT_PROXY} ==="
for i in $(seq 1 60); do
    code="$(curl -so /dev/null -w '%{http_code}' "http://localhost:${PORT_PROXY}/" 2>/dev/null || true)"
    case "${code}" in 200|404) echo "proxy ready (${code})"; break ;; esac
    if [ "${i}" -eq 60 ]; then echo "ERROR: proxy not responding" >&2; exit 1; fi
    sleep 1
done

# ---- 3. run the benchmark autonomously ---------------------------------------
if [ -s "${AMXAGENT_AUTH_FILE}" ]; then
    export OPENAI_API_KEY="$(cat "${AMXAGENT_AUTH_FILE}")"
elif [ "${AMXAGENT_REQUIRE_AUTH}" != "0" ]; then
    echo "ERROR: proxy auth is enabled but ${AMXAGENT_AUTH_FILE} was not created." >&2
    exit 1
else
    export OPENAI_API_KEY="${OPENAI_API_KEY:-dummy}"
fi

echo "=== [run_bench] codex exec ==="
echo "--- prompt ---"; printf '%s\n' "${PROMPT}"; echo "--------------"
cd "${WORKDIR}"
codex exec --skip-git-repo-check -s workspace-write -C "${WORKDIR}" \
    -o "${OUTFILE}" \
    "${PROMPT}"
rc=$?

echo "=== [run_bench] codex exec exit code: ${rc} ==="
if [ -f "${OUTFILE}" ]; then
    echo "--- final agent message (${OUTFILE}) ---"
    cat "${OUTFILE}"
    echo "----------------------------------------"
fi
exit "${rc}"
