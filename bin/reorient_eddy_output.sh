#!/bin/bash
set -euo pipefail

module load FSL/6.0.7.17

OUTDIR="$1"
# Directory containing this script
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DATA="${OUTDIR}/data_gibbs_eddy.nii.gz"
INPUT_BVECS="${OUTDIR}/data_gibbs_eddy.eddy_rotated_bvecs"

OUTPUT_DATA="${OUTDIR}/data_gibbs_eddy_reoriented.nii.gz"
OUTPUT_BVECS="${OUTDIR}/data_gibbs_eddy_reoriented.eddy_rotated_bvecs"

echo "[INFO] Reorienting Eddy outputs back into analysis space."

# --------------------------------------------------------------------------
# DWI
# --------------------------------------------------------------------------

cp "$INPUT_DATA" "$OUTPUT_DATA"

fslchpixdim \
    "$OUTPUT_DATA" \
    0.3 0.3 0.6

fslswapdim \
    "$OUTPUT_DATA" \
    x z -y \
    "$OUTPUT_DATA"

fslorient -setqform \
    0.3 0   0   0 \
    0   0.6 0   0 \
    0   0   0.3 0 \
    0   0   0   1 \
    "$OUTPUT_DATA"

fslorient -copyqform2sform "$OUTPUT_DATA"
fslorient -setqformcode 1 "$OUTPUT_DATA"
fslorient -setsformcode 1 "$OUTPUT_DATA"

# --------------------------------------------------------------------------
# Eddy-rotated bvecs
# --------------------------------------------------------------------------

cp \
    "$INPUT_BVECS" \
    "$OUTPUT_BVECS"

"${BIN_DIR}/reorient_bvecs.sh" \
    "$OUTPUT_BVECS" \
    forward

# --------------------------------------------------------------------------
# Final mask
# --------------------------------------------------------------------------

fslmaths \
    "$OUTPUT_DATA" \
    -mul 0 \
    -add 1 \
    "${OUTDIR}/ones_mask_reoriented"

fslroi \
    "${OUTDIR}/ones_mask_reoriented" \
    "${OUTDIR}/ones_mask_reoriented" \
    0 1

echo "[INFO] Eddy output reorientation complete."