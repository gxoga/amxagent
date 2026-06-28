#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The amxagent authors
# Multi-objective closed loop: run -> measure (density AND temperature) -> Gemma
# tunes -> repeat (<=MAXIT). Tests whether the operator can satisfy two coupled
# targets at once.
#
# OBJECTIVES (task-defined), BOTH must hold:
#   density     -> DENS_TARGET +/- DENS_TOL   kg/m^3   (default 1000 +/- 3)
#   temperature -> TEMP_TARGET +/- TEMP_TOL   K        (default  310 +/- 0.5)
#
# The coupling that makes it non-trivial: temperature is set by ref_t, but raising
# temperature THERMALLY EXPANDS the water and LOWERS density — so hitting T=310
# pushes density down, and the operator must raise ref_p to compensate. Two knobs,
# two targets, cross-coupled; plus each mean sits near its statistical noise floor,
# so nsteps (averaging) trades wall-time for precision.
#
# Operator (Gemma) may change ONLY these md.mdp keywords:
#   ref_t (K, BOTH groups)  ref_p (bar)  tau_t (ps)  tau_p (ps)  nsteps
#
# Equilibration (prep) is reused from the density loop (npt.gro). Each iteration
# re-runs production only; the harness measures both objectives objectively and
# archives every iteration into iter_<i>/.
#
# Usage: ./run_multiobj_loop.sh {loop|base|measure}
# Env:   SIF INSTANCE WORKDIR GMX_BIN GMX_NT MAXIT
#        DENS_TARGET DENS_TOL TEMP_TARGET TEMP_TOL MODEL_DIR
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
DENS_TARGET="${DENS_TARGET:-1000}"; DENS_TOL="${DENS_TOL:-3}"
TEMP_TARGET="${TEMP_TARGET:-310}"; TEMP_TOL="${TEMP_TOL:-0.5}"
MAXIT="${MAXIT:-5}"
CMD="${1:-loop}"
HIST="${WORKDIR}/multiobj_history.tsv"

log()  { printf '\n\033[1;34m[mloop]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[warn]\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

command -v "${GMX_BIN}" >/dev/null 2>&1 || fail "gmx not found ('${GMX_BIN}')."
[ -f "${SIF}" ] || fail "sif not found: ${SIF} — set SIF=/path/to/amxagent.sif (or stage it beside this script / in $WORK)"
[ -f "${WORKDIR}/npt.gro" ] || fail "no equilibrated state — run: ./run_density_loop.sh prep"

# Activate the longer SSE idle timeout WITHOUT rebuilding the .sif. The image bakes
# config.toml.template (5-min default) and start_codex.sh only writes ~/.codex/
# config.toml if it does not already exist. So we stage the host template into the
# run dir and point codex at it with a FRESH CODEX_HOME, forcing regeneration with
# the longer stream_idle_timeout_ms. No-op if the template isn't beside the script.
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

run_production() {
    ( cd "${WORKDIR}"
      set -e
      ${GMX_BIN} grompp -f md.mdp -c npt.gro -t npt.cpt -p topol.top -o md.tpr -maxwarn 2
      ${GMX_BIN} mdrun -deffnm md -nt ${GMX_NT}
      printf "Density\n\n"     | ${GMX_BIN} energy -f md.edr -s md.tpr -o density.xvg     -xvg none
      printf "Temperature\n\n" | ${GMX_BIN} energy -f md.edr -s md.tpr -o temperature.xvg -xvg none
    ) 2>&1 | tee "${WORKDIR}/md_run.log"
    return "${PIPESTATUS[0]}"
}

# last-half mean of column 2 of an .xvg
mean_lasthalf() {
    awk 'NF>=2 && $1 !~ /^[#@]/ {n++; v[n]=$2}
         END{ if(n==0){print "NA"; exit} s=int(n/2); sum=0;c=0;
              for(i=s+1;i<=n;i++){sum+=v[i];c++} printf "%.3f", sum/c }' "$1" 2>/dev/null
}
# Stability check: "Finished mdrun" lands in md.log (not md_run.log);
# only a real "Fatal error" counts as failure (no fragile substring match).
stable_ok() {
    grep -q "Finished mdrun" "${WORKDIR}/md.log" 2>/dev/null \
    && ! grep -qE "Fatal error" "${WORKDIR}/md.log" "${WORKDIR}/md_run.log" 2>/dev/null
}
md_params() {  # ref_t  tau_t  ref_p  tau_p  nsteps
    awk -v OFS='\t' '
      /^[[:space:]]*ref_t/  {rt=$3}
      /^[[:space:]]*tau_t/  {tt=$3}
      /^[[:space:]]*ref_p/  {rp=$3}
      /^[[:space:]]*tau_p/  {tp=$3}
      /^[[:space:]]*nsteps/ {ns=$3}
      END{print rt, tt, rp, tp, ns}' "${WORKDIR}/md.mdp"
}
absdiff() { awk -v a="$1" -v b="$2" 'BEGIN{d=a-b; if(d<0)d=-d; printf "%.3f", d}'; }

archive_iter() {
    local i="$1" dir="${WORKDIR}/mobj_iter_$(printf '%02d' "${i}")"
    mkdir -p "${dir}"
    for f in md.mdp md.log md_run.log density.xvg temperature.xvg md.edr md.tpr "codex_mtune_${i}.txt"; do
        [ -f "${WORKDIR}/${f}" ] && cp -f "${WORKDIR}/${f}" "${dir}/" 2>/dev/null
    done
    log "iteration ${i} artifacts archived -> ${dir}"
}

gemma_tune() {
    local iter="$1" pf; pf="$(mktemp)"
    cat > "${pf}" <<EOF
OPERATOR TASK — multi-objective tuning, iteration ${iter}.

You must satisfy BOTH targets at the same time (measured from the last run):
  * density     = ${DENS_TARGET} kg/m^3   (within +/- ${DENS_TOL})
  * temperature = ${TEMP_TARGET} K         (within +/- ${TEMP_TOL})

These are COUPLED — read carefully:
  - ref_t (K) sets the temperature. It must be edited for BOTH coupling groups
    (the 'ref_t = A  A' line — set both numbers).
  - Raising temperature THERMALLY EXPANDS the water and LOWERS the density. So if
    you raise ref_t to fix temperature, density will drop and you must RAISE ref_p
    to compensate (isothermal compressibility ~4.5e-5 /bar: ~+45 bar ~= +2 kg/m^3).
  - ref_p (bar) is the density knob; tau_t / tau_p are coupling response times.
  - nsteps lengthens the run -> less noisy means (each mean sits near its noise
    floor; the density tolerance and especially temperature +/-${TEMP_TOL} K are tight).

Change ONLY these md.mdp keywords: ref_t (both groups), ref_p, tau_t, tau_p, nsteps.
Touch no other line and no other file. Do NOT run gmx.

Results so far (tab-separated: iter ref_t tau_t ref_p tau_p nsteps density temp dens_err temp_err):
$(cat "${HIST}" 2>/dev/null)

Pick the best joint adjustment to bring BOTH errors down, edit md.mdp in place,
and report old->new for each line you changed plus one or two sentences of
reasoning. Verify any keyword against docs/mdp-options.txt if unsure.
EOF
    log "Gemma multi-objective tuning (iter ${iter})..."
    apptainer run --bind "${WORKDIR}:/work" --app codex "${SIF}" \
        exec --skip-git-repo-check -s workspace-write -C /work \
             -o "/work/codex_mtune_${iter}.txt" "$(cat "${pf}")"
}

# Once the loop has converged, ask Gemma to write a human-readable Markdown report
# of the whole run to SUMMARY.md (it has file-write access in /work).
gemma_summary() {
    local final_iter="$1" pf; pf="$(mktemp)"
    cat > "${pf}" <<EOF
TASK — Write a concise Markdown report of this completed MD optimization run to a
file named SUMMARY.md in the current directory (/work). Use your file-writing tools;
do NOT run gmx and do NOT edit any .mdp file.

Context: you (an automated operator) tuned a GROMACS production run on a solvated
lysozyme (1AKI, OPLS-AA, SPC/E water, ~33,892 atoms) by changing ONLY ref_t, ref_p,
tau_t, tau_p, nsteps, to satisfy BOTH targets at once:
  * density     = ${DENS_TARGET} +/- ${DENS_TOL} kg/m^3   (realistic liquid water)
  * temperature = ${TEMP_TARGET} +/- ${TEMP_TOL} K         (310 K = body temperature)
Convergence was reached at iteration ${final_iter}.

Full iteration history (tab-separated: iter ref_t tau_t ref_p tau_p nsteps density
temp dens_err temp_err tune_s prod_s):
$(cat "${HIST}" 2>/dev/null)

Write SUMMARY.md with these sections (keep the whole file under ~40 lines):
  1. Objective — what had to be achieved and the physical reason for each target.
  2. Result — final converged density & temperature, the iteration reached, PASS.
  3. Iteration history — reproduce the data above as a Markdown table.
  4. Reasoning — the temperature<->density coupling (thermal expansion) and how
     ref_t was set first, then ref_p via isothermal compressibility (~4.5e-5 /bar).
  5. Takeaway — one line on the AI-in-the-loop tuning.
EOF
    log "Gemma writing run summary (SUMMARY.md)..."
    apptainer run --bind "${WORKDIR}:/work" --app codex "${SIF}" \
        exec --skip-git-repo-check -s workspace-write -C /work \
             -o "/work/codex_summary.txt" "$(cat "${pf}")"
    if [ -f "${WORKDIR}/SUMMARY.md" ]; then
        log "summary written -> ${WORKDIR}/SUMMARY.md"
    else
        warn "SUMMARY.md not found after summary step (see codex_summary.txt)"
    fi
}

do_loop() {
    ensure_backend
    printf 'iter\tref_t\ttau_t\tref_p\ttau_p\tnsteps\tdensity\ttemp\tdens_err\ttemp_err\ttune_s\tprod_s\n' > "${HIST}"
    local best_score="99999" best_iter=0 converged=0
    for i in $(seq 1 "${MAXIT}"); do
        log "================= ITERATION ${i}/${MAXIT} ================="
        local tune_s="-" prod_s="-" t0 t1
        # codex exec (Gemma operator) wall time — the whole tuning task
        if [ "${i}" -gt 1 ]; then
            ensure_backend
            t0="$(date +%s.%N)"; gemma_tune "${i}"; t1="$(date +%s.%N)"
            tune_s="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')"
            log "iteration ${i}: codex exec (Gemma tune) wall time = ${tune_s} s"
        fi
        # production (host gmx) wall time
        t0="$(date +%s.%N)"; run_production || warn "production run had nonzero exit (continuing to measure)"; t1="$(date +%s.%N)"
        prod_s="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')"
        local dens temp p de te
        dens="$(mean_lasthalf "${WORKDIR}/density.xvg")"
        temp="$(mean_lasthalf "${WORKDIR}/temperature.xvg")"
        p="$(md_params)"
        if [ "${dens}" = "NA" ] || [ "${temp}" = "NA" ] || ! stable_ok; then
            warn "iteration ${i}: unstable / missing data (dens=${dens} temp=${temp})"
            printf '%s\t%s\tUNSTABLE\t\t\t\t%s\t%s\n' "${i}" "${p}" "${tune_s}" "${prod_s}" >> "${HIST}"
            archive_iter "${i}"; continue
        fi
        de="$(absdiff "${dens}" "${DENS_TARGET}")"
        te="$(absdiff "${temp}" "${TEMP_TARGET}")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${i}" "${p}" "${dens}" "${temp}" "${de}" "${te}" "${tune_s}" "${prod_s}" >> "${HIST}"
        archive_iter "${i}"
        log "iteration ${i}: density=${dens} (err ${de}/${DENS_TOL})  temp=${temp} (err ${te}/${TEMP_TOL})"
        # both within tolerance?
        if awk -v de="${de}" -v dt="${DENS_TOL}" -v te="${te}" -v tt="${TEMP_TOL}" \
               'BEGIN{exit !(de<=dt && te<=tt)}'; then
            log "*** BOTH OBJECTIVES MET at iteration ${i}:  density=${dens}  temp=${temp} ***"
            best_iter="${i}"; converged=1; break
        fi
        # combined normalized score (each error in units of its tolerance)
        local score
        score="$(awk -v de="${de}" -v dt="${DENS_TOL}" -v te="${te}" -v tt="${TEMP_TOL}" \
                  'BEGIN{printf "%.4f", de/dt + te/tt}')"
        if awk -v s="${score}" -v b="${best_score}" 'BEGIN{exit !(s<b)}'; then best_score="${score}"; best_iter="${i}"; fi
    done
    log "===================== SUMMARY ====================="
    column -t "${HIST}" 2>/dev/null || cat "${HIST}"
    log "best iteration: ${best_iter}  (targets: density ${DENS_TARGET}+/-${DENS_TOL}, temp ${TEMP_TARGET}+/-${TEMP_TOL})"
    log "per-iteration evidence in ${WORKDIR}/mobj_iter_*/ ; index: ${HIST}"

    # On convergence, let Gemma write the final Markdown report.
    if [ "${converged}" -eq 1 ]; then
        ensure_backend
        gemma_summary "${best_iter}"
    else
        warn "did not converge within ${MAXIT} iterations — skipping Gemma summary"
    fi
}

case "${CMD}" in
    base)    run_production
             log "density=$(mean_lasthalf "${WORKDIR}/density.xvg")  temp=$(mean_lasthalf "${WORKDIR}/temperature.xvg")" ;;
    measure) log "density=$(mean_lasthalf "${WORKDIR}/density.xvg")  temp=$(mean_lasthalf "${WORKDIR}/temperature.xvg")" ;;
    loop)    do_loop ;;
    *)       fail "usage: $0 {loop|base|measure}" ;;
esac
