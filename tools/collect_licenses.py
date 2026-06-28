#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The amxagent authors
"""Collect the license texts of everything baked into the image.

Intended to run at build time with the TARGET venv's python, so it can enumerate
the packages actually installed in the image:

    /opt/amxagent/venv/bin/python tools/collect_licenses.py \
        /usr/share/amxagent/licenses/collected \
        --src /opt/amxagent/codex --src /opt/amxagent/sglang

For each installed Python distribution it copies license-like files (LICENSE* /
NOTICE* / COPYING* / AUTHORS / PATENTS) plus METADATA into
<dest>/python/<name>-<version>/, **preserving each file's path** so that
path-distinct files with the same basename are all kept (e.g. a package that ships
several vendored LICENSE files). It looks in:
  - the distribution's RECORD (any license-named file, wherever it is recorded),
  - the .dist-info directory (top level) and its `licenses/` subtree, and
  - the `License-File` metadata entries, resolved relative to `.dist-info/licenses/`
    per the packaging spec (with a fallback to the `.dist-info/` root).
For each --src tree it copies top-level license files into <dest>/source/<name>/.
A <dest>/MANIFEST.txt indexes everything collected.

De-duplication is by destination relative path (not by basename), so distinct
files are never silently dropped. Best-effort per package: a distribution that
ships its license under a non-standard, unrecorded path may still be missed. The
build verifies the bundle was produced (see amxagent.def); this script raises on a
catastrophic failure (cannot enumerate packages) so the build does not silently
continue without a bundle.
"""
import argparse
import os
import re
import shutil

LIC_RE = re.compile(r"(LICEN[CS]E|NOTICE|COPYING|AUTHORS|PATENTS)", re.IGNORECASE)


def dist_info_dir(dist):
    """Best-effort path to a distribution's *.dist-info directory."""
    p = getattr(dist, "_path", None)
    if p and os.path.isdir(str(p)):
        return str(p)
    return None


def collect_python(dest, manifest):
    """Collect per-distribution license texts (path-preserving). Returns #dists.

    importlib.metadata is stdlib (3.8+); a failure to import it is catastrophic and
    is allowed to propagate so the build aborts rather than ship no bundle.
    """
    import importlib.metadata as im

    seen_dists = set()
    for dist in im.distributions():
        try:
            name = (dist.metadata["Name"] or "unknown").strip()
            ver = (dist.version or "0").strip()
        except Exception:
            continue
        key = f"{name}-{ver}"
        if key in seen_dists:
            continue
        seen_dists.add(key)
        outdir = os.path.join(dest, "python", key)
        seen_paths = set()
        copied = [0]

        def put(src_abs, rel):
            """Copy src_abs to outdir/rel (path-preserving), dedup by rel path."""
            if not src_abs or not os.path.isfile(src_abs):
                return
            rel = str(rel).replace("\\", "/").lstrip("/")
            # normalise any .. segments to keep everything under outdir
            rel = os.path.normpath(rel).replace("\\", "/").lstrip("./")
            if not rel or rel.startswith("..") or rel in seen_paths:
                return
            d = os.path.join(outdir, rel)
            try:
                os.makedirs(os.path.dirname(d), exist_ok=True)
                shutil.copy2(src_abs, d)
                seen_paths.add(rel)
                copied[0] += 1
            except OSError:
                pass

        info = dist_info_dir(dist)
        distinfo_base = os.path.basename(info) if info else None

        # 1) RECORD: license-named files anywhere, preserving site-packages-relative path
        try:
            for f in dist.files or []:
                if LIC_RE.search(os.path.basename(str(f))):
                    put(str(dist.locate_file(f)), str(f))
        except Exception:
            pass

        if info and distinfo_base:
            # 2) dist-info top-level license files (covers RECORD-less installs)
            for n in sorted(os.listdir(info)):
                p = os.path.join(info, n)
                if os.path.isfile(p) and LIC_RE.search(n):
                    put(p, os.path.join(distinfo_base, n))
            # 3) the whole licenses/ subtree (PEP 639), path-preserving
            lic_sub = os.path.join(info, "licenses")
            if os.path.isdir(lic_sub):
                for root, _dirs, files in os.walk(lic_sub):
                    for n in files:
                        ap = os.path.join(root, n)
                        rel = os.path.join(distinfo_base, os.path.relpath(ap, info))
                        put(ap, rel)
            # 4) METADATA (declares the license)
            meta = os.path.join(info, "METADATA")
            if os.path.isfile(meta):
                put(meta, os.path.join(distinfo_base, "METADATA"))
            # 5) License-File entries: spec places them under .dist-info/licenses/;
            #    fall back to the .dist-info root for older tooling.
            for lf in dist.metadata.get_all("License-File", []) or []:
                cand_spec = os.path.join(info, "licenses", lf)
                cand_root = os.path.join(info, lf)
                if os.path.isfile(cand_spec):
                    put(cand_spec, os.path.join(distinfo_base, "licenses", lf))
                elif os.path.isfile(cand_root):
                    put(cand_root, os.path.join(distinfo_base, lf))

        lic = (dist.metadata.get("License", "") or "").replace("\n", " ").strip()
        classifiers = [c for c in (dist.metadata.get_all("Classifier", []) or []) if "License" in c]
        manifest.append(
            f"python\t{name}\t{ver}\tfiles={copied[0]}\tlicense={lic[:70]}\t{';'.join(classifiers)[:140]}"
        )
    return len(seen_dists)


def collect_sources(dest, srcs, manifest):
    for s in srcs:
        name = os.path.basename(os.path.normpath(s))
        outdir = os.path.join(dest, "source", name)
        copied = 0
        if os.path.isdir(s):
            for n in sorted(os.listdir(s)):
                p = os.path.join(s, n)
                if os.path.isfile(p) and LIC_RE.search(n):
                    try:
                        os.makedirs(outdir, exist_ok=True)
                        shutil.copy2(p, os.path.join(outdir, n))
                        copied += 1
                    except OSError:
                        pass
        manifest.append(f"source\t{name}\t-\tfiles={copied}\t{s}")


def main():
    ap = argparse.ArgumentParser(description="Collect third-party license texts.")
    ap.add_argument("dest", help="output directory for the collected bundle")
    ap.add_argument("--src", action="append", default=[],
                    help="upstream source tree to scan (repeatable)")
    args = ap.parse_args()

    os.makedirs(args.dest, exist_ok=True)
    manifest = ["# kind\tname\tversion\tinfo  (machine-collected; see REDISTRIBUTION.md)"]
    npy = collect_python(args.dest, manifest)
    collect_sources(args.dest, args.src, manifest)
    with open(os.path.join(args.dest, "MANIFEST.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(manifest) + "\n")
    print(f"collect_licenses: {npy} python distributions -> {args.dest}")
    if npy == 0:
        raise SystemExit("collect_licenses: no Python distributions found — refusing to continue")


if __name__ == "__main__":
    main()
