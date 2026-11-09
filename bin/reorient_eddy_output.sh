#!/bin/bash
set -euo pipefail
module load FSL/6.0.7.17
OUTDIR="$1"
cp "${OUTDIR}/data_gibbs_eddy.nii.gz" "${OUTDIR}/data_gibbs_eddy_reoriented.nii.gz"
cp "${OUTDIR}/data_gibbs_eddy.eddy_rotated_bvecs" "${OUTDIR}/data_gibbs_eddy_reoriented.eddy_rotated_bvecs"
fslmaths "${OUTDIR}/data_gibbs_eddy_reoriented.nii.gz" -mul 0 -add 1 "${OUTDIR}/ones_mask_reoriented"
fslroi "${OUTDIR}/ones_mask_reoriented" "${OUTDIR}/ones_mask_reoriented" 0 1
echo "[INFO] Reorientation skipped (temporary): outputs copied."
