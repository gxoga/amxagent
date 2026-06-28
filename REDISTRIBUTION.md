# Redistribution & licensing scope

This project has two very different distribution surfaces. The obligations differ,
so treat them separately. See `THIRD_PARTY_NOTICES.md` for the component detail.

## 1. Source / tarball publication (this repository)

What you publish: the files in this git repo (and the `git archive` / tarball).

- This repo's own code is **Apache-2.0** (`LICENSE`). Files carrying an SPDX header
  are unambiguously Apache-2.0; some docs / prompt / patch fixtures do not.
- The repo **does not vendor** codex, SGLang, PyTorch, the Python deps, or the
  Gemma model — they are cloned / pip-installed / downloaded at build or run time,
  each under its own license.
- `sglang-gemma4-cpu.patch` is a derivative of SGLang (Apache-2.0); see
  `THIRD_PARTY_NOTICES.md`.

Obligation when publishing source: keep `LICENSE`, `THIRD_PARTY_NOTICES.md`, and
this file. No third-party binaries are conveyed, so there is essentially nothing
else to ship.

## 2. Built image (`amxagent.sif`) redistribution

What you convey: a SquashFS image that **contains compiled third-party software**:

- codex (Apache-2.0); SGLang + the applied patch, and sgl-kernel (Apache-2.0)
- PyTorch (BSD-3-Clause); transformers / huggingface_hub / tokenizers (Apache-2.0);
  openai (Apache-2.0); fastapi (MIT); uvicorn / httpx / psutil (BSD); and their
  transitive Python dependencies (numpy, orjson, uvloop, pyzmq, pydantic, ...)
- the Ubuntu 24.04 base userland (glibc LGPL-2.1, coreutils GPL-3.0, etc.)

Handing the `.sif` to a third party **redistributes all of the above**, so their
licenses must travel with it. This image is built to satisfy that automatically:

- `LICENSE`, `THIRD_PARTY_NOTICES.md`, and this file are placed at
  **`/usr/share/amxagent/licenses/`**.
- `tools/collect_licenses.py` runs at build time and collects the available
  LICENSE / NOTICE / COPYING / METADATA from each installed Python distribution
  (from its dist-info, `License-File` metadata, and RECORD — best effort per
  package) and from the codex / SGLang source trees into
  **`/usr/share/amxagent/licenses/collected/`** (with a `MANIFEST.txt`). The build
  **fails** if this bundle is not produced, so an image cannot ship without it.
- The base-distro package licenses remain under **`/usr/share/doc/`** — the build
  does **not** delete it.

So a redistributed `.sif` carries the collected notices inside itself (the build
fails if the bundle is missing). The `runscript` header prints these locations.

### Not included in the image

- The **Gemma 4 model** (`google/gemma-4-26B-A4B-it`) is gated (Apache-2.0) and is
  never baked in or committed. Recipients download it themselves and accept
  Google's model terms.
- **GROMACS** (`gmx`) is provided by the host/site (LGPL-2.1); the image invokes
  it but does not contain it.

### Checklist before sharing a `.sif`

1. Confirm `/usr/share/amxagent/licenses/` (incl. `collected/MANIFEST.txt`) and
   `/usr/share/doc/` are present in the image.
2. Do **not** add the model to the image.
3. Keep `LICENSE`, `THIRD_PARTY_NOTICES.md`, and this file alongside any external
   description of the artifact.
