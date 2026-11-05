#!/bin/bash
# Usage: detect_b0s.sh <merged_data.nii.gz> <outputdir> "<shell_sizes>" <b0_file>
# this script detects b0 volumes in a merged 4D diffusion dataset, based on the signal intensity of each volume based on the mean intensity of volumes in each shell. It outputs the mean signal per volume and the detected b0 positions.

set -euo pipefail

data_4d="$1"
outputdir="$2"
shell_sizes_str="$3"
b0_file="$4"

mkdir -p "$outputdir"

means_file="${outputdir}/volume_means.txt"
> "$b0_file"
> "$means_file"
log_file="${outputdir}/b0_detection.log"

echo "[INFO] Starting per-shell b0 detection" | tee -a "$log_file"

# Convert shell_sizes string → bash array
read -r -a shell_sizes <<< "$shell_sizes_str"

nvols=$(fslval "$data_4d" dim4)
echo "[INFO] Total merged volumes: $nvols" | tee -a "$log_file"
echo "[INFO] Shell sizes: ${shell_sizes[*]}" | tee -a "$log_file"

# -------------------------------
# Compute mean intensity per volume
# -------------------------------
echo "[INFO] Computing per-volume mean signal..." | tee -a "$log_file"

tmpvol="${outputdir}/_tmpvol"

for ((i=0; i<nvols; i++)); do
    fslroi "$data_4d" "$tmpvol" "$i" 1
    mean=$(fslstats "$tmpvol" -M | awk '{print $1}')
    echo "$i $mean" >> "$means_file"
done

rm -f "${tmpvol}.nii.gz"

# -------------------------------
# Process each shell independently
# -------------------------------
start=0

for size in "${shell_sizes[@]}"; do
    end=$((start + size - 1))

    echo "[INFO] Shell block: volumes $start to $end (size $size)" | tee -a "$log_file"

    # Extract means for this shell
    shell_means=$(awk -v s="$start" -v e="$end" \
                  '($1>=s && $1<=e){print $2}' "$means_file")

    # Median for this shell
    median=$(echo "$shell_means" | sort -n | \
             awk '{a[NR]=$1} END{ if(NR%2){print a[(NR+1)/2]} else {print (a[NR/2]+a[NR/2+1])/2} }')

    threshold=$(awk -v med="$median" 'BEGIN{print med*1.13}')

    echo "[INFO] Shell median = $median ; threshold = $threshold" | tee -a "$log_file"

    # Detect b0 volumes for this shell only
    b0s=$(awk -v s="$start" -v e="$end" -v thr="$threshold" \
             '($1>=s && $1<=e && $2>thr){print $1}' "$means_file")

    # Fallback: if shell has no b0 detected, take first volume
    if [[ -z "$b0s" ]]; then
        echo "[WARN] No b0 detected in shell; defaulting to volume $start" | tee -a "$log_file"
        b0s="$start"
    fi

    # Write b0s to b0_positions.txt (one per line)
    echo "$b0s" | tr ' ' '\n' >> "$b0_file"

    # Move to next shell block
    start=$((end + 1))
done

echo "[INFO] b0 detection complete." | tee -a "$log_file"
echo "[INFO] b0_positions.txt written to ${outputdir}" | tee -a "$log_file"

# Print for parent script
cat "$b0_file"
