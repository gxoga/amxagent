# Third-party notices

This file has two scopes, because the project is distributed two ways. See
`REDISTRIBUTION.md` for the obligation split between the two.

## Scope A — this repository (source / tarball)

This project's own source is **Apache-2.0** (`LICENSE`). Implementation source
files and executable scripts carry an `SPDX-License-Identifier: Apache-2.0`
header; some documentation, prompt and patch files do not.

The repo **does not vendor** any third-party software — codex, SGLang, PyTorch,
the Python dependencies, and the Gemma model are cloned / pip-installed /
downloaded at build or run time, each under its own license.

- **`sglang-gemma4-cpu.patch`** — a unified diff authored here that adapts SGLang's
  CPU (Intel AMX) build/runtime for Gemma 4. It contains short SGLang source
  excerpts as diff *context*; SGLang is Apache-2.0, so this derivative is
  distributed consistently with that license. Applying it yields a modified SGLang
  governed by SGLang's own `LICENSE`.
- **GROMACS demo** — the `.mdp` files are standard GROMACS parameters (values that
  also appear in the GROMACS manual) with original comments; the pipeline is the
  standard protocol, not a copyrightable expression. PDB **1AKI** is not included
  (download from the [RCSB PDB](https://www.rcsb.org/structure/1AKI)). `gmx`
  (LGPL-2.1) is invoked, not redistributed.
- No secret material is committed in this repository.

## Scope B — the built image (`amxagent.sif`)

The image **contains compiled third-party software** and therefore redistributes
it. The machine-collected license texts ship **inside the image**:

```
/usr/share/amxagent/licenses/            LICENSE, THIRD_PARTY_NOTICES.md, REDISTRIBUTION.md
/usr/share/amxagent/licenses/collected/  per-package LICENSE/NOTICE/COPYING/METADATA (best effort,
                                         from Python distributions + codex/SGLang source) + MANIFEST.txt
/usr/share/doc/                          Ubuntu base-package licenses (kept on purpose; not deleted)
```

Principal components baked into the image:

| Component | License | Present in image as |
|---|---|---|
| codex | Apache-2.0 | compiled binary (`/usr/local/bin/codex`) + source tree |
| SGLang (+ `sglang-gemma4-cpu.patch`) | Apache-2.0 | installed package + source tree |
| sgl-kernel (CPU / Intel AMX) | Apache-2.0 | compiled extension |
| PyTorch (CPU) | BSD-3-Clause | installed wheel |
| transformers, huggingface_hub, tokenizers | Apache-2.0 | installed wheels |
| openai | Apache-2.0 | installed wheel (OpenAI-compatible client lib) |
| fastapi | MIT | installed wheel (used by `responses_proxy.py`) |
| uvicorn, httpx, psutil | BSD-3-Clause | installed wheels |
| numpy, orjson, uvloop, pyzmq, pydantic, … (transitive) | BSD / MIT / Apache (each) | installed wheels — see `collected/` |
| Ubuntu 24.04 base userland (glibc, coreutils, …) | LGPL-2.1 / GPL-3.0 / MIT / BSD (each) | base image — see `/usr/share/doc/` |

The exact component set and versions for any given build are listed in
`/usr/share/amxagent/licenses/collected/MANIFEST.txt` (produced by
`tools/collect_licenses.py` at build time).

## Model (not in the image)

`google/gemma-4-26B-A4B-it` — Apache-2.0, **gated**. Downloaded by the user; never
baked into the image or committed here. Recipients accept Google's model terms.
