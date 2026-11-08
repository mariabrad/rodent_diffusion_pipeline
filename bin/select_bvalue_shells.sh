#!/bin/bash
set -euo pipefail

module load FSL/6.0.7.17

INPUT_DIR="$1"
OUTPUT_DIR="$2"
REQUESTED_BVALS="$3"

DATA="${INPUT_DIR}/data.nii.gz"
BVALS="${INPUT_DIR}/bvals"
BVECS="${INPUT_DIR}/bvecs"
MASK="${INPUT_DIR}/nodif_brain_mask.nii.gz"

BVAL_TOLERANCE=100

mkdir -p "$OUTPUT_DIR"

echo "[INFO] Requested b-values: ${REQUESTED_BVALS}"
echo "[INFO] B-value matching tolerance: +/- ${BVAL_TOLERANCE} s/mm^2"

# ============================================================================
# ALL = use complete dataset
# ============================================================================

if [[ "${REQUESTED_BVALS^^}" == "ALL" ]]; then

    echo "[INFO] Using all available b-value shells."

    ln -sf "$(realpath "$DATA")" "${OUTPUT_DIR}/data.nii.gz"
    ln -sf "$(realpath "$BVALS")" "${OUTPUT_DIR}/bvals"
    ln -sf "$(realpath "$BVECS")" "${OUTPUT_DIR}/bvecs"
    ln -sf "$(realpath "$MASK")" "${OUTPUT_DIR}/nodif_brain_mask.nii.gz"

    exit 0
fi

# ============================================================================
# Read bvals and bvecs
# ============================================================================

IFS=',' read -r -a requested <<< "$REQUESTED_BVALS"

read -r -a all_bvals < "$BVALS" || true

if (( ${#all_bvals[@]} == 0 )); then
    echo "[ERROR] No b-values found in: $BVALS"
    exit 1
fi

mapfile -t bvec_lines < "$BVECS"

read -r -a bx <<< "${bvec_lines[0]}"
read -r -a by <<< "${bvec_lines[1]}"
read -r -a bz <<< "${bvec_lines[2]}"

# ============================================================================
# Check that every requested shell exists
# ============================================================================

for requested_b in "${requested[@]}"; do

    found=false

    for b in "${all_bvals[@]}"; do

        if awk -v b="$b" -v target="$requested_b" -v tol="$BVAL_TOLERANCE" \
            'BEGIN {
                d=b-target
                if (d<0) d=-d
                exit !(d<=tol)
            }'
        then
            found=true
            break
        fi

    done

    if [[ "$found" == false ]]; then
        echo "[ERROR] Requested b-value shell ${requested_b} was not found."
        echo "[ERROR] B-value matching tolerance: +/- ${BVAL_TOLERANCE} s/mm^2"
        exit 1
    fi

done

# ============================================================================
# Select requested volumes
# ============================================================================

selected_vols=()
selected_bvals=()
selected_x=()
selected_y=()
selected_z=()

for i in "${!all_bvals[@]}"; do

    b="${all_bvals[$i]}"
    keep=false

    for requested_b in "${requested[@]}"; do

        if awk -v b="$b" -v target="$requested_b" -v tol="$BVAL_TOLERANCE" \
            'BEGIN {
                d=b-target
                if (d<0) d=-d
                exit !(d<=tol)
            }'
        then
            keep=true
            break
        fi

    done

    if [[ "$keep" == true ]]; then

        vol="${OUTPUT_DIR}/vol_${i}.nii.gz"

        fslroi "$DATA" "$vol" "$i" 1

        selected_vols+=( "$vol" )
        selected_bvals+=( "$b" )
        selected_x+=( "${bx[$i]}" )
        selected_y+=( "${by[$i]}" )
        selected_z+=( "${bz[$i]}" )

    fi

done

# ============================================================================
# Create selected dataset
# ============================================================================

if (( ${#selected_vols[@]} == 0 )); then
    echo "[ERROR] No volumes matched requested b-values: ${REQUESTED_BVALS}"
    exit 1
fi

fslmerge -t \
    "${OUTPUT_DIR}/data.nii.gz" \
    "${selected_vols[@]}"

(
    IFS=' '
    echo "${selected_bvals[*]}"
) > "${OUTPUT_DIR}/bvals"

{
    printf "%s " "${selected_x[@]}"
    echo

    printf "%s " "${selected_y[@]}"
    echo

    printf "%s " "${selected_z[@]}"
    echo

} > "${OUTPUT_DIR}/bvecs"

cp "$MASK" "${OUTPUT_DIR}/nodif_brain_mask.nii.gz"

# Remove temporary individual volumes
rm -f "${OUTPUT_DIR}"/vol_*.nii.gz

echo "[INFO] B-value shell selection complete."
echo "[INFO] Requested b-values: ${REQUESTED_BVALS}"
echo "[INFO] B-value tolerance: +/- ${BVAL_TOLERANCE} s/mm^2"
echo "[INFO] Selected ${#selected_vols[@]} volumes."