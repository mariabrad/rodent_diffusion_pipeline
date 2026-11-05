#!/bin/bash
set -euo pipefail

module add fsl

# ============================================================================
# Inputs
# ============================================================================

OUTDIR="$1"
IFS=',' read -r -a shell_sizes_arr <<< "$2"
IFS=',' read -r -a reps_arr <<< "$3"

INPUT_DATA="${OUTDIR}/data_gibbs_eddy_reoriented.nii.gz"
INPUT_BVALS="${OUTDIR}/bvals"
INPUT_BVECS="${OUTDIR}/data_gibbs_eddy_reoriented.eddy_rotated_bvecs"

FITTING_DIR="${OUTDIR}/fitting_input"
TMP_DIR="${OUTDIR}/avg_tmp"

echo "==========================================="
echo " COMBINING ACQUISITION REPETITIONS"
echo "==========================================="

echo "[INFO] Shell sizes: ${shell_sizes_arr[*]}"
echo "[INFO] Repetitions: ${reps_arr[*]}"

# ============================================================================
# Validate inputs
# ============================================================================

if [[ ${#shell_sizes_arr[@]} -ne ${#reps_arr[@]} ]]; then
    echo "[ERROR] Number of shell sizes does not match number of repetition counts."
    exit 1
fi

for file in "$INPUT_DATA" "$INPUT_BVALS" "$INPUT_BVECS"; do
    if [[ ! -f "$file" ]]; then
        echo "[ERROR] Required input not found: $file"
        exit 1
    fi
done

# Check that each shell divides evenly into repetitions
for s in "${!shell_sizes_arr[@]}"; do

    total_vols="${shell_sizes_arr[$s]}"
    reps="${reps_arr[$s]}"

    if (( reps < 1 )); then
        echo "[ERROR] Invalid repetition count for shell $s: $reps"
        exit 1
    fi

    if (( total_vols % reps != 0 )); then
        echo "[ERROR] Shell $s has $total_vols volumes and $reps repetitions."
        echo "        Volumes do not divide evenly between repetitions."
        exit 1
    fi

done

# ============================================================================
# Read bvals and Eddy-rotated bvecs
# ============================================================================

read -r -a all_bvals < "$INPUT_BVALS"

mapfile -t bvec_lines < "$INPUT_BVECS"

if (( ${#bvec_lines[@]} != 3 )); then
    echo "[ERROR] Eddy rotated bvec file should contain exactly 3 rows."
    exit 1
fi

read -r -a all_x <<< "${bvec_lines[0]}"
read -r -a all_y <<< "${bvec_lines[1]}"
read -r -a all_z <<< "${bvec_lines[2]}"

n_data=$(fslval "$INPUT_DATA" dim4)

if (( ${#all_bvals[@]} != n_data ||
      ${#all_x[@]} != n_data ||
      ${#all_y[@]} != n_data ||
      ${#all_z[@]} != n_data )); then

    echo "[ERROR] Eddy data, bvals and bvecs have different numbers of volumes."
    echo "        data  = $n_data"
    echo "        bvals = ${#all_bvals[@]}"
    echo "        bvecs = ${#all_x[@]}"
    exit 1
fi

# Check that shell sizes describe the complete dataset
expected_vols=0

for n in "${shell_sizes_arr[@]}"; do
    expected_vols=$(( expected_vols + n ))
done

if (( expected_vols != n_data )); then
    echo "[ERROR] Shell sizes describe $expected_vols volumes,"
    echo "        but Eddy output contains $n_data volumes."
    exit 1
fi

# ============================================================================
# Prepare output directories
# ============================================================================

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
mkdir -p "$FITTING_DIR"

# Arrays containing the final fitting data
avg_vols=()
final_bvals=()
final_x=()
final_y=()
final_z=()

offset=0

# ============================================================================
# Combine repetitions
# ============================================================================

for s in "${!shell_sizes_arr[@]}"; do

    total_vols="${shell_sizes_arr[$s]}"
    reps="${reps_arr[$s]}"
    vols_per_rep=$(( total_vols / reps ))

    echo "[INFO] Shell $s: $total_vols volumes, $reps repetitions, $vols_per_rep volumes/rep"

    for ((v=0; v<vols_per_rep; v++)); do

        rep_vols=()
        rep_indices=()

        # --------------------------------------------------------------------
        # Find corresponding volumes from each repetition
        # --------------------------------------------------------------------

        for ((r=0; r<reps; r++)); do

            idx=$(( offset + r * vols_per_rep + v ))

            rep_indices+=( "$idx" )

            vol="${TMP_DIR}/shell${s}_vol${v}_rep${r}.nii.gz"

            fslroi "$INPUT_DATA" "$vol" "$idx" 1

            rep_vols+=( "$vol" )

        done

        # --------------------------------------------------------------------
        # Check b-values match between repetitions
        # --------------------------------------------------------------------

        ref_idx="${rep_indices[0]}"
        ref_bval="${all_bvals[$ref_idx]}"

        for idx in "${rep_indices[@]}"; do

            if [[ "${all_bvals[$idx]}" != "$ref_bval" ]]; then
                echo "[ERROR] b-values do not match between repetitions."
                echo "        Shell $s, volume $v"
                exit 1
            fi

        done

        final_bvals+=( "$ref_bval" )

        # --------------------------------------------------------------------
        # Construct representative Eddy-rotated bvec
        # --------------------------------------------------------------------

        # b0
        if awk -v b="$ref_bval" 'BEGIN { exit !(b == 0) }'; then

            final_x+=( "0" )
            final_y+=( "0" )
            final_z+=( "0" )

        # diffusion-weighted volume
        else

            ref_x="${all_x[$ref_idx]}"
            ref_y="${all_y[$ref_idx]}"
            ref_z="${all_z[$ref_idx]}"

            sum_x=0
            sum_y=0
            sum_z=0

            for idx in "${rep_indices[@]}"; do

                x="${all_x[$idx]}"
                y="${all_y[$idx]}"
                z="${all_z[$idx]}"

                # Sign-align with first repetition.
                #
                # g and -g represent the same diffusion direction, so flip
                # the vector if it points in the opposite direction.
                read -r x y z < <(
                    awk \
                        -v rx="$ref_x" \
                        -v ry="$ref_y" \
                        -v rz="$ref_z" \
                        -v x="$x" \
                        -v y="$y" \
                        -v z="$z" \
                        'BEGIN {
                            dot = rx*x + ry*y + rz*z

                            if (dot < 0) {
                                x = -x
                                y = -y
                                z = -z
                            }

                            print x, y, z
                        }'
                )

                sum_x=$(awk -v a="$sum_x" -v b="$x" 'BEGIN {print a+b}')
                sum_y=$(awk -v a="$sum_y" -v b="$y" 'BEGIN {print a+b}')
                sum_z=$(awk -v a="$sum_z" -v b="$z" 'BEGIN {print a+b}')

            done

            # Normalize the mean vector to unit length
            read -r mean_x mean_y mean_z < <(
                awk \
                    -v x="$sum_x" \
                    -v y="$sum_y" \
                    -v z="$sum_z" \
                    'BEGIN {
                        norm = sqrt(x*x + y*y + z*z)

                        if (norm == 0) {
                            exit 1
                        }

                        printf "%.10f %.10f %.10f\n",
                               x/norm,
                               y/norm,
                               z/norm
                    }'
            ) || {
                echo "[ERROR] Could not calculate mean bvec."
                echo "        Shell $s, volume $v"
                exit 1
            }

            final_x+=( "$mean_x" )
            final_y+=( "$mean_y" )
            final_z+=( "$mean_z" )

        fi

        # --------------------------------------------------------------------
        # Average image volumes
        # --------------------------------------------------------------------

        mean="${TMP_DIR}/mean_shell${s}_vol${v}.nii.gz"

        if (( reps == 1 )); then

            cp "${rep_vols[0]}" "$mean"

        else

            stack="${TMP_DIR}/stack_shell${s}_vol${v}.nii.gz"

            fslmerge -t "$stack" "${rep_vols[@]}"
            fslmaths "$stack" -Tmean "$mean"

        fi

        avg_vols+=( "$mean" )

    done

    offset=$(( offset + total_vols ))

done

# ============================================================================
# Write final fitting data
# ============================================================================

echo "[INFO] Creating final repetition-averaged dataset."

fslmerge -t \
    "${FITTING_DIR}/data.nii.gz" \
    "${avg_vols[@]}"

printf "%s " "${final_bvals[@]}" |
    sed 's/[[:space:]]*$//' \
    > "${FITTING_DIR}/bvals"

{
    printf "%s " "${final_x[@]}"
    echo

    printf "%s " "${final_y[@]}"
    echo

    printf "%s " "${final_z[@]}"
    echo

} > "${FITTING_DIR}/bvecs"

cp \
    "${OUTDIR}/ones_mask_reoriented.nii.gz" \
    "${FITTING_DIR}/nodif_brain_mask.nii.gz"

# ============================================================================
# Final validation
# ============================================================================

n_final_data=$(fslval "${FITTING_DIR}/data.nii.gz" dim4)
n_final_bvals=$(wc -w < "${FITTING_DIR}/bvals")
n_final_bvecs=$(awk 'NR==1 {print NF}' "${FITTING_DIR}/bvecs")

if (( n_final_data != n_final_bvals ||
      n_final_data != n_final_bvecs )); then

    echo "[ERROR] Final fitting inputs do not match."
    echo "        data volumes = $n_final_data"
    echo "        bvals        = $n_final_bvals"
    echo "        bvecs        = $n_final_bvecs"
    exit 1
fi

# Remove temporary individual/stacked volumes
rm -rf "$TMP_DIR"

echo "==========================================="
echo " REPETITION COMBINATION COMPLETE"
echo "==========================================="
echo "[INFO] Number of fitting volumes: $n_final_data"
echo "[INFO] Model inputs written to:"
echo "       ${FITTING_DIR}/data.nii.gz"
echo "       ${FITTING_DIR}/bvals"
echo "       ${FITTING_DIR}/bvecs"
echo "       ${FITTING_DIR}/nodif_brain_mask.nii.gz"