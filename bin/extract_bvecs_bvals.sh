set -euo pipefail
IFS=$'\n\t'

foldername="$1"

IFS=' ' read -r -a shell_folders <<< "$2"
IFS=' ' read -r -a shell_reps <<< "$3"

if [[ ${#shell_folders[@]} -ne ${#shell_reps[@]} ]]; then
    echo "[ERROR] Number of shell folders and repetition counts differ."
    echo "[ERROR] Shell folders: ${shell_folders[*]}"
    echo "[ERROR] Repetitions:   ${shell_reps[*]}"
    exit 1
fi

echo "[INFO] Shell/repetition mapping:"
for i in "${!shell_folders[@]}"; do
    echo "       method_${shell_folders[$i]} -> ${shell_reps[$i]} rep(s)"
done

# --- Collect all b0 indices globally ---
b0_file="${foldername}/b0_positions.txt"
if [[ ! -f "$b0_file" ]]; then
  echo "[ERROR] Missing b0_positions.txt in ${foldername}. Please run detect_b0s.sh first."
  exit 1
fi

echo "[DEBUG] shell_reps: ${shell_reps[*]}"
echo "[DEBUG] number of shells: ${#shell_reps[@]}"
mapfile -t b0_positions < <(grep -Eo '[0-9]+' "$b0_file" | sort -n)
echo "[INFO] b0 indices: ${b0_positions[*]}"

# --- Get total number of volumes from denoised data ---
merged="${foldername}/data_complex_denoised.nii.gz"
if [[ ! -f "$merged" ]]; then
  echo "[ERROR] Missing denoised dataset ${merged}"
  exit 1
fi

nvols=$(fslval "$merged" dim4)
echo "[INFO] Total number of volumes in merged dataset: $nvols"

# --- Build method file list in the exact user-specified shell order ---
method_files=()

for folder in "${shell_folders[@]}"; do

    mfile="${foldername}/method_${folder}"

    if [[ ! -f "$mfile" ]]; then
        echo "[ERROR] Method file not found: $mfile"
        exit 1
    fi

    if grep -q '^##\$BlipDownYN=Yes' "$mfile"; then
        echo "[ERROR] $(basename "$mfile") is marked as a blip-down acquisition."
        echo "[ERROR] Blip-down must not be included in --SHELL_FOLDER_NUMBERS."
        exit 1
    fi

    method_files+=( "$mfile" )
done

echo "[INFO] Processing method files in acquisition order:"
printf '       %s\n' "${method_files[@]}"

# --- Extract bvals and bvecs for each shell, then repeat per shell_reps ---
declare -a all_bvals
declare -a all_bvecs
declare -a all_bvals_single
declare -a all_bvecs_single

for idx in "${!method_files[@]}"; do
  mfile="${method_files[$idx]}"
  reps="${shell_reps[$idx]}"
  base=$(basename "$mfile")
  shellnum="${base#method_}"
  echo "[INFO] Processing ${base} with ${reps} rep(s)"

  bval_tmp="${foldername}/bvals_${shellnum}"
  bvec_tmp="${foldername}/bvecs_${shellnum}"

  # Extract bvals
  sed -n '/PVM_DwEffBval/,/PVM_DwGradVec/{ /PVM_DwEffBval/d; /PVM_DwGradVec/d; p }' "$mfile" \
    | tr " " "\n" | sed '/^[[:space:]]*$/d' | tr -d " \t\r" > "$bval_tmp"

  # Extract bvecs
  sed -n '/##\$PVM_DwDir=(/,/##\$PVM_DwDgSwitch/{ /PVM_DwDir/d; /##\$PVM_DwDgSwitch/d; p }' "$mfile" \
    | tr " " "\n" | sed '/^[[:space:]]*$/d' | tr -d " \t\r" | tr "\n" " " \
    | sed -e 's/\([^ ]* [^ ]* [^ ]*\) /\1\n/g' | sed '/^[[:space:]]*$/d' > "$bvec_tmp"

mapfile -t bvals_this_shell < "$bval_tmp"
mapfile -t bvecs_this_shell < "$bvec_tmp"

# bvecs already exclude b0s, so keep them as-is
shell_bvecs_filtered=( "${bvecs_this_shell[@]}" )

# Filter bvals to remove b0s
declare -a shell_bvals_filtered=()

for val in "${bvals_this_shell[@]}"; do
  [[ "$val" == @* ]] && continue   # drop @10*(16.9323250024545)
  [[ "$val" =~ ^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]] || continue

  awk -v v="$val" 'BEGIN { exit !(v >= 50) }' && shell_bvals_filtered+=( "$val" )
done

echo "[DEBUG] ${base}: raw bvals=${#bvals_this_shell[@]} raw bvecs=${#bvecs_this_shell[@]}"
echo "[DEBUG] ${base}: kept ${#shell_bvals_filtered[@]} diffusion bvals after removing b0s"
echo "[DEBUG] ${base}: kept ${#shell_bvecs_filtered[@]} diffusion bvecs"

if [[ ${#shell_bvals_filtered[@]} -ne ${#shell_bvecs_filtered[@]} ]]; then
  echo "[ERROR] ${base}: filtered bvals and bvecs lengths still do not match."
  exit 1
fi

# Keep one copy for the single-rep version
all_bvals_single+=( "${shell_bvals_filtered[@]}" )
all_bvecs_single+=( "${shell_bvecs_filtered[@]}" )


# Repeat this shell block according to shell_reps
for ((r=1; r<=reps; r++)); do
  all_bvals+=( "${shell_bvals_filtered[@]}" )
  all_bvecs+=( "${shell_bvecs_filtered[@]}" )
done
done

echo "[DEBUG] bvals remaining: ${#all_bvals[@]}"
echo "[DEBUG] bvecs remaining: ${#all_bvecs[@]}"

# --- Validate counts before inserting b0s ---

n_b0s=${#b0_positions[@]}
n_diffusion_vols=$((nvols - n_b0s))

echo "[DEBUG] Dataset volumes: $nvols"
echo "[DEBUG] b0 volumes:      $n_b0s"
echo "[DEBUG] diffusion vols:  $n_diffusion_vols"
echo "[DEBUG] diffusion bvals: ${#all_bvals[@]}"
echo "[DEBUG] diffusion bvecs: ${#all_bvecs[@]}"

if [[ ${#all_bvals[@]} -ne $n_diffusion_vols ]]; then
    echo "[ERROR] Number of diffusion bvals (${#all_bvals[@]}) does not match expected diffusion volumes ($n_diffusion_vols)."
    echo "[ERROR] Please check method file bvals and bvecs before re-running."
    exit 1
fi

if [[ ${#all_bvecs[@]} -ne $n_diffusion_vols ]]; then
    echo "[ERROR] Number of diffusion bvecs (${#all_bvecs[@]}) does not match expected diffusion volumes ($n_diffusion_vols)."
    echo "[ERROR] Please check method file bvals and bvecs before re-running."
    exit 1
fi

# --- Insert zeros for b0 indices globally ---

declare -a final_bvecs
declare -a final_bvals

for ((i=0; i<nvols; i++)); do
    if printf '%s\n' "${b0_positions[@]}" | grep -qx "$i"; then
        final_bvecs+=("0 0 0")
        final_bvals+=("0")
    else
        final_bvecs+=( "${all_bvecs[0]}" )
        all_bvecs=( "${all_bvecs[@]:1}" )

        final_bvals+=( "${all_bvals[0]}" )
        all_bvals=( "${all_bvals[@]:1}" )
    fi
done

# --- Write results ---
printf "%s " "${final_bvals[@]}" > "${foldername}/bvals"
printf "%s\n" "${final_bvecs[@]}" > "${foldername}/bvecs_temp"

awk '
{
    for (i=1; i<=NF; i++)  {
        a[NR,i] = $i
    }
}
NF>p { p = NF }
END {
    for(j=1; j<=p; j++) {
        str=a[1,j]
        for(i=2; i<=NR; i++){
            str=str"    "a[i,j];
        }
        print str
    }
}' "${foldername}/bvecs_temp" > "${foldername}/bvecs"
rm -f "${foldername}/bvecs_temp"

printf "%s " "${all_bvals_single[@]}" > "${foldername}/bvals_single_rep"
printf "%s\n" "${all_bvecs_single[@]}" > "${foldername}/bvecs_single_rep_temp"

awk '
{
    for (i=1; i<=NF; i++) {
        a[NR,i] = $i
    }
}
NF>p { p = NF }
END {
    for (j=1; j<=p; j++) {
        str=a[1,j]
        for (i=2; i<=NR; i++) {
            str=str"    "a[i,j]
        }
        print str
    }
}' "${foldername}/bvecs_single_rep_temp" > "${foldername}/bvecs_single_rep"

rm -f "${foldername}/bvecs_single_rep_temp"

# --- Sanity check ---
cols=$(awk 'NR==1{print NF}' "${foldername}/bvecs")
if [[ "$cols" -ne "$nvols" ]]; then
  echo "[ERROR] bvecs has $cols columns but dataset has $nvols volumes!"
  exit 1
fi

echo "[INFO] Extracted bvals and bvecs for ${nvols} volumes, with correct zeros at indices: ${b0_positions[*]}"
