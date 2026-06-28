#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The amxagent authors
# run_md.sh - lysozyme-in-water MD pipeline (fixed template — change only named parameters)
# Fixed pipeline template: the shape is fixed; operator
# tasks tune .mdp values or triage logs; they should NOT rewrite this script.
set -euo pipefail
exec > >(tee run_md.log) 2>&1

echo "=== [run_md] lysozyme-in-water pipeline start ==="

# 1. Strip crystal waters (HOH/WAT) in a SINGLE pass.
#    NB: never read and write the same file in one redirection — it truncates first.
grep -vE "HOH|WAT" 1AKI.pdb > 1AKI_clean.pdb

# 2. Topology + H (OPLS-AA / SPC/E), non-interactive via flags
gmx pdb2gmx -f 1AKI_clean.pdb -o processed.gro -p topol.top -i posre.itp \
    -ff oplsaa -water spce -ignh

# 3. Cubic box, 1.0 nm padding, centered
gmx editconf -f processed.gro -o boxed.gro -c -d 1.0 -bt cubic

# 4. Solvate with SPC/E water
gmx solvate -cp boxed.gro -cs spc216.gro -o solvated.gro -p topol.top

# 5. Add ions to neutralize (genion picks the SOL group on stdin)
gmx grompp -f ions.mdp -c solvated.gro -p topol.top -o ions.tpr -maxwarn 1
printf "SOL\n" | gmx genion -s ions.tpr -o ionized.gro -p topol.top \
    -pname NA -nname CL -neutral

# 6. Energy minimization
gmx grompp -f minim.mdp -c ionized.gro -p topol.top -o em.tpr -maxwarn 1
gmx mdrun -deffnm em

# 7. NVT equilibration (position-restrained)
gmx grompp -f nvt.mdp -c em.gro -r em.gro -p topol.top -o nvt.tpr -maxwarn 1
gmx mdrun -deffnm nvt

# 8. NPT equilibration (position-restrained)
gmx grompp -f npt.mdp -c nvt.gro -r nvt.gro -t nvt.cpt -p topol.top -o npt.tpr -maxwarn 1
gmx mdrun -deffnm npt

# 9. Production MD
gmx grompp -f md.mdp -c npt.gro -t npt.cpt -p topol.top -o md.tpr -maxwarn 1
gmx mdrun -deffnm md

# 10. Extraction for validation (energy terms by NAME; plain-text .xvg)
echo "=== [run_md] extracting analysis data ==="
printf "Potential\n\n"   | gmx energy -f md.edr -s md.tpr -o potential.xvg   -xvg none
printf "Temperature\n\n" | gmx energy -f md.edr -s md.tpr -o temperature.xvg -xvg none
printf "Pressure\n\n"    | gmx energy -f md.edr -s md.tpr -o pressure.xvg    -xvg none
printf "Density\n\n"     | gmx energy -f md.edr -s md.tpr -o density.xvg     -xvg none
printf "Backbone\nBackbone\n" | gmx rms    -s md.tpr -f md.xtc -o rmsd.xvg   -xvg none
printf "Protein\n"            | gmx gyrate -s md.tpr -f md.xtc -o gyrate.xvg -xvg none

echo "=== [run_md] pipeline finished successfully ==="
