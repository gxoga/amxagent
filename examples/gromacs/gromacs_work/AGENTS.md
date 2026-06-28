# GROMACS work area — OPERATOR role

The MD pipeline in this directory is a fixed template. Do not restructure it:

- `run_md.sh`  — the full lysozyme-in-water pipeline (clean → pdb2gmx → editconf →
  solvate → genion → EM → NVT → NPT → production → analysis extraction).
- `minim.mdp` `ions.mdp` `nvt.mdp` `npt.mdp` `md.mdp` — the parameter files.

**Your role is OPERATOR.** You perform small, well-scoped tasks on top of this
template — e.g. tune a named parameter, organize/triage logs, summarize results.
You do **not** redesign the pipeline.

## Hard rules
1. **Do NOT restructure `run_md.sh` or rewrite whole `.mdp` files.** Change only the
   specific lines the task names. Leave every other line byte-for-byte intact.
2. **`gmx` is not available to you** — never run it. You edit text files and read
   logs/outputs only.
3. **Verify any GROMACS keyword you touch against `./docs/`** before editing:
   - `.mdp` keywords → `docs/mdp-options.txt`
   - `gmx <cmd>` behavior → `docs/gmx-<cmd>.txt`
   Quote the option rather than guessing. If a keyword is not in the docs, stop and
   say so instead of inventing one.
4. **Never read and write the same file in one shell redirection** (`x > x`
   truncates it first). Edit files in place with your editor tools.
5. Keep changes minimal and report exactly what you changed (a short diff of the
   touched lines).

## docs/ index
`mdp-options.txt` (full .mdp reference) · `system-preparation.txt` · `flow.txt` ·
`getting-started.txt` · `run-time-errors.txt` · `gmx-*.txt` (per-command help).

These files are **generated on-site** from the locally installed GROMACS by
`gen_docs.sh` (run automatically by the launcher; needs a GROMACS module on PATH).
If `docs/` is empty, the docs step has not run yet — say so rather than guessing
keywords.

## Out of scope (do not attempt)
Adding/removing pipeline stages, changing force field or water model, altering the
analysis set, or anything that changes the *shape* of `run_md.sh`. If a task seems
to require that, say so and stop.
