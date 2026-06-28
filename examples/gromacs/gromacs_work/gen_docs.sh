#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The amxagent authors
# gen_docs.sh — populate ./docs/ from the LOCAL GROMACS installation.
#
# Why: the operator (Gemma) consults ./docs/ to verify .mdp keywords and gmx
# command behaviour before editing.  We do NOT redistribute GROMACS' own
# documentation in this repo / the .sif — instead each site regenerates docs/
# from its *own* installed GROMACS (e.g. after `module load GROMACS`).
# The per-command pages come from `gmx help <cmd>`; the user-guide pages are the
# clean reStructuredText sources shipped inside the GROMACS package
# ($prefix/share/doc/gromacs/html/_sources/user-guide/*.rst.txt).
#
# Usage:
#   module load GROMACS        # (or source GMXRC / apt install gromacs
#   ./gen_docs.sh              # regenerates ./docs/ next to this script
#   GMX_BIN=gmx_mpi ./gen_docs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCS_DIR="${SCRIPT_DIR}/docs"
GMX_BIN="${GMX_BIN:-gmx}"

log()  { printf '\033[1;34m[gen_docs]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[gen_docs] WARN:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[gen_docs] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v "${GMX_BIN}" >/dev/null 2>&1 || \
    fail "'${GMX_BIN}' not found. Run 'module load GROMACS' first (or set GMX_BIN)."

log "gmx: $(command -v "${GMX_BIN}")  ($("${GMX_BIN}" --version 2>/dev/null | awk -F: '/GROMACS version/{print $2}' | xargs))"
mkdir -p "${DOCS_DIR}"

# --- locate the GROMACS data prefix and user-guide RST sources ------------------
GMX_PREFIX="$("${GMX_BIN}" --version 2>/dev/null | awk -F: '/Data prefix/{gsub(/^[ \t]+/,"",$2);print $2}')"
[ -n "${GMX_PREFIX:-}" ] || GMX_PREFIX="$(dirname "$(dirname "$(command -v "${GMX_BIN}")")")"

UG=""
for cand in \
    "${GMX_PREFIX}/share/doc/gromacs/html/_sources/user-guide" \
    "${GMX_PREFIX}/share/gromacs/html/_sources/user-guide" \
    "${GMX_PREFIX}"/share/doc/gromacs*/html/_sources/user-guide ; do
    [ -d "${cand}" ] && { UG="${cand}"; break; }
done
# last-resort search under the prefix (guard: find may return nothing -> dirname '' = '.')
if [ -z "${UG}" ]; then
    _hit="$(find "${GMX_PREFIX}" -name mdp-options.rst.txt 2>/dev/null | head -1)"
    [ -n "${_hit}" ] && UG="$(dirname "${_hit}")"
fi

# Many GROMACS modules strip the docs. Fall back to GROMACS' own versioned RST
# on GitLab (matching this gmx version). Needs internet -> run on the front-end.
GMX_VER="$("${GMX_BIN}" --version 2>/dev/null | awk -F: '/GROMACS version/{gsub(/[ \t]/,"",$2);print $2}')"
GITLAB_BASE="https://gitlab.com/gromacs/gromacs/-/raw/v${GMX_VER}/docs/user-guide"

# --- 1. user-guide pages: local RST first, else fetch matching version ----------
UG_DOCS="mdp-options system-preparation run-time-errors getting-started flow"
[ -n "${UG}" ] && log "user-guide RST sources (local): ${UG}"
for d in ${UG_DOCS}; do
    if [ -n "${UG}" ] && [ -f "${UG}/${d}.rst.txt" ]; then
        cp "${UG}/${d}.rst.txt" "${DOCS_DIR}/${d}.txt"
        log "  + ${d}.txt (local)"
    elif command -v curl >/dev/null 2>&1 && [ -n "${GMX_VER}" ] \
         && curl -fsSL "${GITLAB_BASE}/${d}.rst" -o "${DOCS_DIR}/${d}.txt" 2>/dev/null \
         && [ -s "${DOCS_DIR}/${d}.txt" ]; then
        log "  + ${d}.txt (fetched v${GMX_VER})"
    else
        rm -f "${DOCS_DIR}/${d}.txt"
        warn "  user-guide page '${d}' unavailable (no local RST + no network) — run gen_docs.sh on the front-end"
    fi
done

# --- 2. per-command help (generated locally from gmx itself) --------------------
CMDS="pdb2gmx editconf solvate genion grompp mdrun energy rms gyrate make_ndx trjconv"
log "per-command help via '${GMX_BIN} help <cmd>'"
for c in ${CMDS}; do
    if "${GMX_BIN}" help "${c}" > "${DOCS_DIR}/gmx-${c}.txt" 2>/dev/null && \
       [ -s "${DOCS_DIR}/gmx-${c}.txt" ]; then
        log "  + gmx-${c}.txt"
    else
        rm -f "${DOCS_DIR}/gmx-${c}.txt"
        warn "  '${GMX_BIN} ${c}' not available — gmx-${c}.txt skipped"
    fi
done

log "done. docs/ generated from the local GROMACS install:"
ls -1 "${DOCS_DIR}" | sed 's/^/    /'
[ -f "${DOCS_DIR}/mdp-options.txt" ] || \
    warn "mdp-options.txt is absent — the operator cannot verify .mdp keywords until docs are available."
