# amxagent — token-cost-free CLI coding agent on CPU (Intel AMX)

A self-hosted, **GPU-free** coding agent for AMX-capable Intel Xeon CPUs. It
packages the [codex](https://github.com/openai/codex) CLI, an OpenAI-compatible
inference backend ([SGLang](https://github.com/sgl-project/sglang) CPU, Intel AMX
kernels) and a small Responses-API proxy into a single
[Apptainer](https://apptainer.org/) image, serving a 26B-class MoE model
(`gemma-4-26B-A4B-it`, ~3B active params) — no GPU, no per-token API cost.

```
codex CLI ──Responses API──> responses_proxy.py ──Chat Completions──> SGLang CPU
 (TUI / headless)              (port 8001)                              (port 8000)
                                                                  Gemma 4 (AMX BF16/INT8)
```

## Build

```bash
apptainer build amxagent.sif amxagent.def     # ~1 GB image, ~1 h, model NOT included
```

Requirements: an AMX-capable Intel Xeon (`amx_bf16`/`amx_tile`/`amx_int8`), Linux
x86-64, Apptainer with working `--fakeroot`, internet during the build, and
~100+ GB RAM to run. The model and all upstreams are fetched/built by the recipe,
never vendored. Pinned upstream commits live in `amxagent.def`.

## Run (local smoke test)

```bash
# one-shot: start backend -> codex solves a tiny task -> stop
mkdir -p benchwork
apptainer run --app bench \
  --bind <model-dir>:/models --bind ./benchwork:/work \
  amxagent.sif "$(cat bench_prompt.txt)"
```

For an interactive session, start the backend as a persistent instance and run
`codex` against it — see `start_sglang.sh` / `start_codex.sh`.

## AMX throughput benchmark

```bash
apptainer run --app llmbench --bind <model-dir>:/models amxagent.sif
```
Drives the raw SGLang endpoint and reports TTFT, prefill/decode tok/s, aggregate
throughput, and per-core CPU usage (the per-core breakdown needs `psutil`; without
it the benchmark still runs and prints the rest). Tunables: `CONCURRENCY`,
`INPUT_TOKENS`, `OUTPUT_TOKENS`. See `bench/`.

## Notes

- **AMX required** — the CPU must expose `amx_bf16 amx_tile amx_int8` in
  `/proc/cpuinfo` (a non-AMX node aborts with SIGILL).
- **`TP_SIZE` ≤ the node's NUMA-node count** (default 4).
- **`CHUNKED_PREFILL_SIZE=2048`** avoids a BF16 overflow in the GDN attention
  kernel on long prompts; do not raise it blindly.
- The backend and proxy bind `127.0.0.1` (same-node only).

## The model

`google/gemma-4-26B-A4B-it` is gated (Apache-2.0). Accept the terms on Hugging
Face, download it yourself, and bind the directory at `/models` when you run. It
is never baked into the image.

## Licenses

This repository's own source is **Apache-2.0** (see `LICENSE`; implementation
source files and executable scripts carry an SPDX header — some docs, prompt and
patch files do not). It does not vendor codex / SGLang / Gemma — those are
fetched at build/run time under their own licenses. See `THIRD_PARTY_NOTICES.md`.
Publishing the source vs. redistributing the built `amxagent.sif` carry different
obligations — see **`REDISTRIBUTION.md`**. The image bundles the collected
third-party license texts under `/usr/share/amxagent/licenses/` (plus base-distro
licenses in `/usr/share/doc/`).
