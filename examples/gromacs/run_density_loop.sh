#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The amxagent authors
# Closed-loop density optimisation: run -> measure -> Gemma tunes -> repeat (<=5x).
#
# GOAL (task-defined): production-MD mean system density within
#   TARGET +/- TOL  kg/m^3   (default 1000 +/- 3).
# OPERATOR (Gemma) may change ONLY these md.mdp knobs between iterations:
#   ref_p (bar)   — pressure setpoint; higher ref_p compresses water -> higher density
#   tau_p (ps)    — barostat response time
#   nsteps        — production length (longer -> better-converged mean)
# Everything else (system, force field, equilibration) is fixed by this template.
#
# Equilibration (EM/NVT/NPT) runs ONCE; each loop iteration re-runs production only.
# The harness measures density objectively (last-half mean of density.xvg) and feeds
# the history to Gemma, which edits md.mdp for the next iteration.
#
# Usage:
#   ./run_density_loop.sh prep      # one-time: clean..NPT (real host gmx)
#   ./run_density_loop.sh base      # one production run + measure (no tuning)
#   ./run_density_loop.sh loop      # full closed loop (prep if needed, up to MAXIT)
#   ./run_density_loop.sh measure   # just print density of the latest density.xvg
#
# Env: SIF INSTANCE WORKDIR GMX_BIN GMX_NT TARGET TOL MAXIT MODEL_DIR
set -uo pipefail
umask 077    # codex rollout/state + run artifacts owner-only (content protection)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIF="${SIF:-${SCRIPT_DIR}/amxagent.sif}"
INSTANCE="${INSTANCE:-amxagent}"
WORKDIR="${WORKDIR:-${SCRIPT_DIR}/gromacs_work}"
GMX_BIN="${GMX_BIN:-gmx}"
GMX_NT="${GMX_NT:-64}"
MODEL_DIR="${MODEL_DIR:-${SCRIPT_DIR}/gemma-4-26B-A4B-it}"
PORT_PROXY="${PORT_PROXY:-8001}"
TARGET="${TARGET:-1000}"
TOL="${TOL:-3}"
MAXIT="${MAXIT:-5}"
CMD="${1:-loop}"

HIST="${WORKDIR}/loop_history.tsv"

log()  { printf '\n\033[1;34m[loop]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[warn]\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

command -v "${GMX_BIN}" >/dev/null 2>&1 || fail "gmx not found ('${GMX_BIN}')."
[ -f "${SIF}" ] || fail "sif not found: ${SIF} — set SIF=/path/to/amxagent.sif (or stage it beside this script / in $WORK)"
mkdir -p "${WORKDIR}"

# Activate the longer SSE idle timeout without rebuilding the .sif: stage the host
# config.toml.template into the run dir and point codex at it with a fresh
# CODEX_HOME so start_codex.sh regenerates config.toml with the longer timeout.
_CFG_TPL="${SCRIPT_DIR}/config.toml.template"
[ -f "$_CFG_TPL" ] || _CFG_TPL="${SCRIPT_DIR}/../../config.toml.template"   # repo root when run from examples/gromacs/
if [ -f "$_CFG_TPL" ]; then
    cp -f "$_CFG_TPL" "${WORKDIR}/config.toml.template"
    export APPTAINERENV_TEMPLATE=/work/config.toml.template
    export APPTAINERENV_CODEX_HOME=/work/.codex
    export APPTAINERENV_MODEL=/models
fi

# operator docs are regenerated on-site from the local GROMACS (not shipped)
if [ ! -f "${WORKDIR}/docs/mdp-options.txt" ] && [ -x "${WORKDIR}/gen_docs.sh" ]; then
    log "generating operator docs from local GROMACS (gen_docs.sh)"
    GMX_BIN="${GMX_BIN}" "${WORKDIR}/gen_docs.sh" || warn "gen_docs.sh failed — operator will lack docs/"
fi

# ---- backend (needed only for the Gemma tuning step) -------------------------
ensure_backend() {
    if curl -so /dev/null -w '%{http_code}' "http://localhost:${PORT_PROXY}/" 2>/dev/null | grep -qE '200|404'; then
        thread_proxy_auth_key   # backend already up — still thread the key so codex auths (avoids 401)
        return
    fi
    log "starting backend instance '${INSTANCE}'..."
    [ -d "${MODEL_DIR}" ] || fail "model dir not found: ${MODEL_DIR}"
    apptainer instance list 2>/dev/null | grep -q "^${INSTANCE} " \
        || apptainer instance start --bind "${MODEL_DIR}:/models" --bind "${WORKDIR}:/work" "${SIF}" "${INSTANCE}"
    # LOG_DIR=/work so sglang.log + proxy.log (incl. [perf] TTFT/prefill tok/s lines)
    # persist in the per-job run dir instead of dying inside the container instance.
    APPTAINERENV_LOG_DIR=/work apptainer exec "instance://${INSTANCE}" /opt/amxagent/bin/start_sglang.sh start
    for i in $(seq 1 120); do
        curl -so /dev/null -w '%{http_code}' "http://localhost:${PORT_PROXY}/" 2>/dev/null | grep -qE '200|404' && break
        [ "$i" -eq 120 ] && fail "proxy never came up"; sleep 2
    done
    thread_proxy_auth_key
}

# Pass the proxy auth key to the `apptainer run --app codex` calls. start_sglang.sh
# (in the backend instance) writes it to ~/.codex/amxagent_proxy.key on the shared
# host home; we forward the value via APPTAINERENV_OPENAI_API_KEY so codex
# authenticates regardless of whether its container mounts the same HOME.
# Set AMXAGENT_REQUIRE_AUTH=0 to run the proxy without auth (isolated hosts only).
thread_proxy_auth_key() {
    [ "${AMXAGENT_REQUIRE_AUTH:-1}" = "0" ] && return
    local keyf="${AMXAGENT_AUTH_FILE:-${HOME}/.codex/amxagent_proxy.key}"
    local n
    for n in $(seq 1 30); do [ -s "${keyf}" ] && break; sleep 1; done
    if [ -s "${keyf}" ]; then
        export APPTAINERENV_OPENAI_API_KEY="$(cat "${keyf}")"
    else
        echo "[ensure_backend] WARN: proxy auth key not found at ${keyf}; codex calls may get 401 (set AMXAGENT_REQUIRE_AUTH=0 to disable)" >&2
    fi
}

# ---- one-time equilibration (real host gmx), tee to prep.log -----------------
prep() {
    ( cd "${WORKDIR}"
      set -e
      echo "=== prep: clean..NPT  ($(date '+%H:%M:%S')) ==="
      grep -vE "HOH|WAT" 1AKI.pdb > 1AKI_clean.pdb
      ${GMX_BIN} pdb2gmx -f 1AKI_clean.pdb -o processed.gro -p topol.top -i posre.itp -ff oplsaa -water spce -ignh
      ${GMX_BIN} editconf -f processed.gro -o boxed.gro -c -d 1.0 -bt cubic
      ${GMX_BIN} solvate -cp boxed.gro -cs spc216.gro -o solvated.gro -p topol.top
      ${GMX_BIN} grompp -f ions.mdp -c solvated.gro -p topol.top -o ions.tpr -maxwarn 2
      printf "SOL\n" | ${GMX_BIN} genion -s ions.tpr -o ionized.gro -p topol.top -pname NA -nname CL -neutral
      ${GMX_BIN} grompp -f minim.mdp -c ionized.gro -p topol.top -o em.tpr -maxwarn 2
      ${GMX_BIN} mdrun -deffnm em -nt ${GMX_NT}
      ${GMX_BIN} grompp -f nvt.mdp -c em.gro -r em.gro -p topol.top -o nvt.tpr -maxwarn 2
      ${GMX_BIN} mdrun -deffnm nvt -nt ${GMX_NT}
      ${GMX_BIN} grompp -f npt.mdp -c nvt.gro -r nvt.gro -t nvt.cpt -p topol.top -o npt.tpr -maxwarn 2
      ${GMX_BIN} mdrun -deffnm npt -nt ${GMX_NT}
      echo "=== prep done  ($(date '+%H:%M:%S')) ==="
    ) 2>&1 | tee "${WORKDIR}/prep.log"
    return "${PIPESTATUS[0]}"
}

# ---- one production run with the current md.mdp ------------------------------
run_production() {
    ( cd "${WORKDIR}"
      set -e
      [ -f npt.gro ] || { echo "no npt.gro — run prep first"; exit 3; }
      ${GMX_BIN} grompp -f md.mdp -c npt.gro -t npt.cpt -p topol.top -o md.tpr -maxwarn 2
      ${GMX_BIN} mdrun -deffnm md -nt ${GMX_NT}
      printf "Density\n\n" | ${GMX_BIN} energy -f md.edr -s md.tpr -o density.xvg -xvg none
    ) 2>&1 | tee "${WORKDIR}/md_run.log"
    return "${PIPESTATUS[0]}"
}

# ---- objective measurement: last-half mean of density.xvg --------------------
measure_density() {
    awk 'NF>=2 && $1 !~ /^[#@]/ {n++; v[n]=$2}
         END{ if(n==0){print "NA"; exit} s=int(n/2); sum=0;c=0;
              for(i=s+1;i<=n;i++){sum+=v[i];c++} printf "%.2f", sum/c }' \
        "${WORKDIR}/density.xvg" 2>/dev/null
}
stable_ok() { grep -q "Finished mdrun" "${WORKDIR}/md_run.log" 2>/dev/null \
              && ! grep -qiE "nan|inf|Fatal error" "${WORKDIR}/md_run.log" 2>/dev/null; }
md_params() {  # ref_p tau_p nsteps  (tab-separated)
    awk -v OFS='\t' '
      /^[[:space:]]*ref_p/      {rp=$3}
      /^[[:space:]]*tau_p/      {tp=$3}
      /^[[:space:]]*nsteps/     {ns=$3}
      END{print rp, tp, ns}' "${WORKDIR}/md.mdp"
}

# ---- archive one iteration's artifacts into iter_<i>/ ------------------------
archive_iter() {
    local i="$1" dir="${WORKDIR}/iter_$(printf '%02d' "${i}")"
    mkdir -p "${dir}"
    # the exact inputs/outputs/logs of this iteration (best-effort; ignore missing)
    for f in md.mdp md.log md_run.log density.xvg md.edr md.tpr "codex_tune_${i}.txt"; do
        [ -f "${WORKDIR}/${f}" ] && cp -f "${WORKDIR}/${f}" "${dir}/" 2>/dev/null
    done
    log "iteration ${i} artifacts archived -> ${dir}"
}

# ---- Gemma operator: read history, edit md.mdp knobs -------------------------
gemma_tune() {
    local iter="$1" pf; pf="$(mktemp)"
    cat > "${pf}" <<EOF
OPERATOR TASK — density tuning, iteration ${iter}.

GOAL: make the production-MD mean system density equal ${TARGET} kg/m^3
(within +/- ${TOL}). The density was measured objectively from density.xvg.

You may change ONLY these three keywords in md.mdp, nothing else, no other file:
  ref_p   (bar)  — pressure setpoint. Higher ref_p compresses the water and
                   RAISES density; lower ref_p lowers it. (isothermal compress.
                   ~4.5e-5 /bar, so ~+45 bar shifts density by roughly +2 kg/m^3.)
  tau_p   (ps)   — barostat response time (1-5 ps typical).
  nsteps         — production length; longer gives a better-converged mean.

Results so far (tab-separated: iter  ref_p  tau_p  nsteps  density  error):
$(cat "${HIST}" 2>/dev/null)

Decide the SINGLE best adjustment to move density toward ${TARGET}, edit md.mdp
in place (change only those keyword lines), and report old->new for what you
changed and your reasoning in one or two sentences. Do NOT run gmx. Verify any
keyword against docs/mdp-options.txt if unsure.
EOF
    log "Gemma tuning (iter ${iter})..."
    apptainer run --bind "${WORKDIR}:/work" --app codex "${SIF}" \
        exec --skip-git-repo-check -s workspace-write -C /work \
             -o "/work/codex_tune_${iter}.txt" "$(cat "${pf}")"
}

# ---- the loop ----------------------------------------------------------------
do_loop() {
    [ -f "${WORKDIR}/npt.gro" ] || { log "no equilibrated state — running prep first"; prep || fail "prep failed"; }
    ensure_backend
    printf 'iter\tref_p\ttau_p\tnsteps\tdensity\terror\n' > "${HIST}"
    local best_err="9999" best_iter=0
    for i in $(seq 1 "${MAXIT}"); do
        log "================= ITERATION ${i}/${MAXIT} ================="
        if [ "${i}" -gt 1 ]; then ensure_backend; gemma_tune "${i}"; fi
        run_production || warn "production run had nonzero exit (continuing to measure)"
        local d p err
        d="$(measure_density)"; p="$(md_params)"
        if [ "${d}" = "NA" ] || ! stable_ok; then
            warn "iteration ${i}: unstable / no density (d=${d})"
            printf '%s\t%s\tUNSTABLE\n' "${i}" "${p}" >> "${HIST}"
            archive_iter "${i}"
            continue
        fi
        err="$(awk -v d="${d}" -v t="${TARGET}" 'BEGIN{e=d-t; if(e<0)e=-e; printf "%.2f", e}')"
        printf '%s\t%s\t%s\t%s\n' "${i}" "${p}" "${d}" "${err}" >> "${HIST}"
        archive_iter "${i}"
        log "iteration ${i}: density=${d} kg/m^3  (target ${TARGET}, error ${err})"
        if awk -v e="${err}" -v tol="${TOL}" 'BEGIN{exit !(e<=tol)}'; then
            log "*** GOAL REACHED at iteration ${i}: ${d} kg/m^3 (|err|=${err} <= ${TOL}) ***"
            best_iter="${i}"; best_err="${err}"; break
        fi
        if awk -v e="${err}" -v b="${best_err}" 'BEGIN{exit !(e<b)}'; then best_err="${err}"; best_iter="${i}"; fi
    done
    log "===================== SUMMARY ====================="
    column -t "${HIST}" 2>/dev/null || cat "${HIST}"
    log "best: iteration ${best_iter}, |error|=${best_err} kg/m^3 (target ${TARGET}+/-${TOL})"
}

case "${CMD}" in
    prep)    prep ;;
    base)    run_production; d="$(measure_density)"; log "density (last-half mean) = ${d} kg/m^3" ;;
    measure) log "density (last-half mean) = $(measure_density) kg/m^3" ;;
    loop)    do_loop ;;
    *)       fail "usage: $0 {prep|base|loop|measure}" ;;
esac
