#!/bin/bash
module add FSL/6.0.7.17
source $FSLDIR/etc/fslconf/fsl.sh
module add MRtrix/3.0.4-foss-2022b
module load MATLAB/2024b

export PATH=~/local_bin:$PATH

# Use really strict error handling. If any command fails, the script will exit immediately rather than keep running silently.
set -euo pipefail

# set pipeline subscript paths flexibly for each users download
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SUBDIR_PATH="${PIPELINE_DIR}/bin"

# Default values
RAWDIR=""
OUTDIR=""
BLIPDOWNFILE=""
SHELL_NAMES=""
SHELL_FOLDER_NUMBERS=""
COMPLEX_RECON_FOLDER_NUMBERS=""
SPECIES=""
CONDITION=""
TOPUPCNF=""
INDEXTXT=""
DRIFT_METHOD="b0"
COMBINE_REPS="FALSE"
RUN_BEDPOSTX="FALSE"
RUN_NODDI="FALSE"
NODDI_DOT="FALSE"
DTIDKI_BVALS="ALL"
BEDPOSTX_BVALS="ALL"
NODDI_BVALS="ALL"

# DEFINE MINI FUNCTIONS
# handle incorrect input of list arguments (e.g., if user inputs with spaces or with/without brackets) by converting all into a consistent bash array format.
normalize_list() {
  local s="$1"
  s="${s//[\[\]\{\} ]/}"
  s="${s//\'/}"
  s="${s//\"/}"
  printf '%s' "$s"
}

convert_csv_array() {
  local raw
  raw="$(normalize_list "$1")"
  local -n out=$2
  IFS=', ' read -r -a out <<< "$raw"
}

# convert bash arrays into Matlab formats (cell array for names, numeric array for folder numbers) for passing as arguments to the matlab script
to_matlab_names() {
  local out="{"
  local sep=""
  for x in "$@"; do
    out+="${sep}'${x}'"
    sep=","
  done
  out+="}"
  printf '%s' "$out"
}

to_matlab_numbers() {
  local out="["
  local sep=""
  for x in "$@"; do
    out+="${sep}${x}"
    sep=","
  done
  out+="]"
  printf '%s' "$out"
}

detect_dimensionality() {
  local mfile="$1"
  local dim raw line

  [[ -f "$mfile" ]] || { echo "2D"; return; }  # safe default

  # 1) Try PVM_SpatDimEnum inline first (e.g., ##$PVM_SpatDimEnum=<3D>)
  line=$(grep -m1 "##\$PVM_SpatDimEnum=" "$mfile" | tr -d '\r')
  if [[ -n "$line" ]]; then
    dim=$(echo "$line" | grep -Eio '[23][d]' | head -n1)
  fi

  # 2) If empty, try the next line after PVM_SpatDimEnum
  if [[ -z "$dim" ]]; then
    raw=$(grep -A1 -m1 "##\$PVM_SpatDimEnum=" "$mfile" | tail -n1 | tr -d '\r <>()')
    dim=$(echo "$raw" | grep -Eio '[23][d]' | head -n1)
  fi

  # 3) Fallback: PVM_SpatDim=2D/3D variants
  if [[ -z "$dim" ]]; then
    line=$(grep -m1 "##\$PVM_SpatDim=" "$mfile" | tr -d '\r')
    dim=$(echo "$line" | grep -Eio '[23][d]' | head -n1)
  fi

  # Normalize and return
  case "${dim^^}" in
    3D) echo "3D"; return ;;
    2D) echo "2D"; return ;;
  esac

  # Last resort: don't force 2D based on NSlices (it can exist in some 3D protocols)
  echo "2D"
}

while [[ $# -gt 0 ]]; do
  arg="$1"
  shift

  # If the user inputs the help flag then print usage information and exit
  if [[ "$arg" == "--help" || "$arg" == "-h" || "$arg" == "--h" || "$arg" == "-help" ]]; then
    echo "Help flag used. Please use the following usage information carefully to help you run the pipeline correctly."
    echo ""
echo "Usage: $0 --RAWDIR=PATH --BLIPDOWNFILE=FILE_PATH --SHELL_NAMES=b1k,b2k,...,bn --SHELL_FOLDER_NUMBERS=N1,N2,...,Nn --COMPLEX_RECON_FOLDER_NUMBERS=N1,N2,...,Nn --SPECIES=NAME --CONDITION=TYPE --OUTDIR=PATH [options]"    echo ""
    echo "Make sure to provide all the required arguments, with correct spelling."
    echo "Required arguments:"
    echo "  --RAWDIR=PATH
    Input directory containing Bruker data"
    echo ""
    echo "  --BLIPDOWNFILE=FILE_PATH
    Input file for the separate blipdown acquisition/image used for TOPUP"
    echo ""
    echo "  --SHELL_NAMES=b1k,b2k,...,bn
    Comma-separated list of diffusion shell names. Do not include blipdown. Folder names should be concisely descriptive of shell parameters and contain no spaces"
    echo ""
    echo "  --SHELL_FOLDER_NUMBERS=N1,N2,...,Nn
    Comma-separated list of folder numbers for each diffusion shell. Do not include blipdown."
    echo ""
    echo "  --COMPLEX_RECON_FOLDER_NUMBERS=N1,N2,...,Nn
    Comma-separated list of folder numbers that contain the complex reconstructions for each diffusion shell. Do not include blipdown."
    echo ""
    echo "  --SPECIES=NAME
    Species ('mouse' or 'rat')"
    echo ""
    echo "  --CONDITION=TYPE
    Acquisition type ('exvivo' or 'invivo')"
    echo ""
    echo "  --OUTDIR=PATH
    Output directory for results"
    echo ""
    echo "Optional arguments"
    echo "  --TOPUPCNF=FILE
    Use custom TOPUP configuration file (.cnf). If not provided, the script will auto-select based on SPECIES, CONDITION, and matrix size."
    echo ""
    echo "  --INDEXTXT=FILE
    Optional custom index.txt file to use for eddy. If not provided, the script will use the auto-generated index.txt."
    echo ""
    echo "  --DRIFT_METHOD=METHOD
    Drift correction method: 'b0' (default) or 'shell'.
    'b0' estimates global signal drift from interleaved b0 volumes.
    'shell' performs linear voxel-wise detrending independently within each b-value shell.
    If 'b0' is selected but the b0 volumes are not sufficiently interleaved, the pipeline automatically falls back to 'shell'."
    echo ""
    echo "  --COMBINE_REPS=TRUE|FALSE
    Average corresponding diffusion volumes across acquisition repetitions
    after Eddy correction. Default: FALSE.
    If FALSE, all repetitions are retained for model fitting."
    echo ""
    echo "  --RUN_BEDPOSTX=TRUE|FALSE
    Run BedpostX model fitting. Default: FALSE."
    echo ""
    echo "  --RUN_NODDI=TRUE|FALSE
    Run NODDI model fitting. Default: FALSE."
    echo ""
    echo "  --NODDI_DOT=TRUE|FALSE
    Include the dot compartment in the NODDI model.
    Only used when --RUN_NODDI=TRUE. Default: FALSE."
    echo ""
    echo "  --DTIDKI_BVALS=BVALUES
    Comma-separated b-value shells to use for DTI/DKI fitting.
    Example: --DTIDKI_BVALS=0,1000,2000. Default: ALL."
    echo ""
    echo "  --BEDPOSTX_BVALS=BVALUES
    Comma-separated b-value shells to use for BedpostX.
    Example: --BEDPOSTX_BVALS=0,1000,2000. Default: ALL."
    echo ""
    echo "  --NODDI_BVALS=BVALUES
    Comma-separated b-value shells to use for NODDI.
    Example: --NODDI_BVALS=0,1000,2000. Default: ALL."
    echo ""
    exit 0
  fi

  case "$arg" in
    --RAWDIR=*) RAWDIR="${arg#*=}" ;;
    --BLIPDOWNFILE=*) BLIPDOWNFILE="${arg#*=}" ;;
    --OUTDIR=*) OUTDIR="${arg#*=}" ;;
    --SHELL_NAMES=*) SHELL_NAMES="${arg#*=}" ;;
    --SHELL_FOLDER_NUMBERS=*) SHELL_FOLDER_NUMBERS="${arg#*=}" ;;
    --COMPLEX_RECON_FOLDER_NUMBERS=*) COMPLEX_RECON_FOLDER_NUMBERS="${arg#*=}" ;;
    --SPECIES=*) SPECIES="${arg#*=}" ;;
    --CONDITION=*) CONDITION="${arg#*=}" ;;
    --TOPUPCNF=*) TOPUPCNF="${arg#*=}" ;;
    --INDEXTXT=*) INDEXTXT="${arg#*=}" ;;
    --DRIFT_METHOD=*) DRIFT_METHOD="${arg#*=}" ;;
    --COMBINE_REPS=*) COMBINE_REPS="${arg#*=}" ;;
    --RUN_BEDPOSTX=*) RUN_BEDPOSTX="${arg#*=}" ;;
    --RUN_NODDI=*) RUN_NODDI="${arg#*=}" ;;
    --NODDI_DOT=*) NODDI_DOT="${arg#*=}" ;;
    --DTIDKI_BVALS=*) DTIDKI_BVALS="${arg#*=}" ;;
    --BEDPOSTX_BVALS=*) BEDPOSTX_BVALS="${arg#*=}" ;;
    --NODDI_BVALS=*) NODDI_BVALS="${arg#*=}" ;;
    *)
      echo "Unknown option: $arg"
      exit 1
      ;;
  esac
done

# check that all required arguments are provided
if [[ -z "${RAWDIR:-}" || -z "${BLIPDOWNFILE:-}" || -z "${OUTDIR:-}" || -z "${SHELL_NAMES:-}" || -z "${SHELL_FOLDER_NUMBERS:-}" || -z "${COMPLEX_RECON_FOLDER_NUMBERS:-}" || -z "${SPECIES:-}" || -z "${CONDITION:-}" ]]; then
  echo "Error: Missing required arguments."
  echo "Usage: $0 --RAWDIR=PATH  --BLIPDOWNFILE=FILE_PATH --SHELL_NAMES=b1k,b2k,...,bn --SHELL_FOLDER_NUMBERS=N1,N2,...,Nn --COMPLEX_RECON_FOLDER_NUMBERS=N1,N2,...,Nn --SPECIES=NAME --CONDITION=TYPE --OUTDIR=PATH [options]"
  exit 1
fi

# create the output directory if missing
if [[ -d "$OUTDIR" ]]; then
  echo "Output directory exists. All pipeline outputs will be stored in: $OUTDIR once processing is complete."
else
  echo "Creating output directory: $OUTDIR"
  mkdir -p "$OUTDIR"
fi
mkdir -p "${OUTDIR}/logs"

# convert comma-separated string arguments into bash arrays
convert_csv_array "$SHELL_NAMES" shell_names_arr
convert_csv_array "$SHELL_FOLDER_NUMBERS" shell_folders_arr
convert_csv_array "$COMPLEX_RECON_FOLDER_NUMBERS" complex_recon_arr

# Check that at least one shell is provided
if [[ ${#shell_names_arr[@]} -eq 0 ]]; then
  echo "[ERROR] No shell names provided."
  exit 1
fi

# Check that the number of shell names, folder numbers, and complex recon folder numbers match
if [[ ${#shell_names_arr[@]} -ne ${#shell_folders_arr[@]} || ${#shell_names_arr[@]} -ne ${#complex_recon_arr[@]} ]]; then
  echo "[ERROR] SHELL_NAMES, SHELL_FOLDER_NUMBERS, and COMPLEX_RECON_FOLDER_NUMBERS must have the same number of entries."
  exit 1
fi
echo "[INFO] Detected shells: ${shell_names_arr[*]}"

# Check that the species and condition are provided correctly
SPECIES=$(echo "$SPECIES" | tr '[:upper:]' '[:lower:]')
CONDITION=$(echo "$CONDITION" | tr '[:upper:]' '[:lower:]')
DRIFT_METHOD=$(echo "$DRIFT_METHOD" | tr '[:upper:]' '[:lower:]')
COMBINE_REPS="${COMBINE_REPS^^}"
RUN_BEDPOSTX="${RUN_BEDPOSTX^^}"
RUN_NODDI="${RUN_NODDI^^}"
NODDI_DOT="${NODDI_DOT^^}"

# Validate SPECIES
if [[ "$SPECIES" != "mouse" && "$SPECIES" != "rat" ]]; then
  echo "[ERROR] Invalid --SPECIES value: '$SPECIES'"
  echo "[ERROR] Allowed values are exactly: mouse or rat"
  exit 1
fi

# Validate CONDITION
if [[ "$CONDITION" != "invivo" && "$CONDITION" != "exvivo" ]]; then
  echo "[ERROR] Invalid --CONDITION value: '$CONDITION'"
  echo "[ERROR] Allowed values are exactly: invivo or exvivo"
  exit 1
fi

# Validate DRIFT_METHOD
if [[ "$DRIFT_METHOD" != "b0" && "$DRIFT_METHOD" != "shell" ]]; then
    echo "[ERROR] Invalid --DRIFT_METHOD value: '$DRIFT_METHOD'"
    echo "[ERROR] Allowed values are: b0 or shell"
    exit 1
fi

# Validate COMBINE_REPS, RUN_BEDPOSTX, RUN_NODDI, NODDI_DOT
for flag in COMBINE_REPS RUN_BEDPOSTX RUN_NODDI NODDI_DOT; do
    value="${!flag}"
    if [[ "$value" != "TRUE" && "$value" != "FALSE" ]]; then
        echo "[ERROR] Invalid --${flag} value: '$value'"
        echo "[ERROR] Allowed values are: TRUE or FALSE"
        exit 1
    fi
done

# Validate b-value shell selections
for flag in DTIDKI_BVALS BEDPOSTX_BVALS NODDI_BVALS; do
    value="${!flag}"

    if [[ "${value^^}" == "ALL" ]]; then
        continue
    fi

    if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?(,[0-9]+([.][0-9]+)?)*$ ]]; then
        echo "[ERROR] Invalid --${flag} value: '$value'"
        echo "[ERROR] Use ALL or comma-separated b-values, e.g. 0,1000,2000"
        exit 1
    fi
done

# force exit to encourage rerunning if noddi was intended to be run. Because selecting noddi_dot=true doesn't automatically do anything if run_noddi=true was not selected
if [[ "$NODDI_DOT" == "TRUE" && "$RUN_NODDI" != "TRUE" ]]; then
    echo "[ERROR] --NODDI_DOT=TRUE has no effect because --RUN_NODDI=FALSE. If you meant to run NODDI, rerun with --RUN_NODDI=TRUE"
    exit 1
fi

# Check the input directory exists
if [[ ! -d "$RAWDIR" ]]; then
  echo "Error: Input directory does not exist: $RAWDIR"
  exit 1
fi

# Check the blipdown file exists
if [[ ! -f "$BLIPDOWNFILE" ]]; then
    echo "Error: Blipdown nifti file does not exist: $BLIPDOWNFILE"
    exit 1
fi
cp "$BLIPDOWNFILE" "${OUTDIR}/blipdown.nii.gz"
echo "[INFO] Extracting first volume from blipdown image if there is more than one volume."
fslroi "${OUTDIR}/blipdown.nii.gz" "${OUTDIR}/blipdown.nii.gz" 0 1


# Check that each shell folders exist inside the input directory
for shell in "${shell_folders_arr[@]}"; do
  shell_path="${RAWDIR}/${shell}"
  if [[ ! -d "$shell_path" ]]; then
    echo "Error: Shell directory not found: $shell_path"
    exit 1
  fi
done

for shell in "${shell_folders_arr[@]}"; do
    cp "${RAWDIR}/${shell}/method" "${OUTDIR}/method_${shell}"
done

METHOD_FILE="${OUTDIR}/method_${shell_folders_arr[0]}"

# Detect acquisition dimensionality (2D vs 3D) from Bruker method file of the first shell
ACQ_DIM="$(detect_dimensionality "$METHOD_FILE")"
echo "[INFO] Detected acquisition dimensionality: ${ACQ_DIM}"

SHELL_NAMES_MATLAB=$(to_matlab_names "${shell_names_arr[@]}")
SHELL_FOLDER_NUMBERS_MATLAB=$(to_matlab_numbers "${shell_folders_arr[@]}")
COMPLEX_RECON_FOLDER_NUMBERS_MATLAB=$(to_matlab_numbers "${complex_recon_arr[@]}")

# Read matrix dimensions from first method file
if [[ "$ACQ_DIM" == "2D" ]]; then
  read -r d1 d2 < <(awk '/^##\$PVM_Matrix=\( 2 \)/ { getline; print $1, $2; exit }' "$METHOD_FILE")
  d3=$(awk '/^##\$PVM_SPackArrNSlices=\( 1 \)/ { getline; print $1; exit }' "$METHOD_FILE")
else
  read -r d1 d2 d3 < <(awk '/^##\$PVM_Matrix=\( 3 \)/ { getline; print $1, $2, $3; exit }' "$METHOD_FILE")
fi

# Decide odd/even
if (( d1 % 2 == 0 && d2 % 2 == 0 && d3 % 2 == 0 )); then
  matrix="even"
else
  matrix="odd"
fi

# Determine TOPUP configuration file
config_dir="${BIN_SUBDIR_PATH}/configuration_files"
if [[ -z "${TOPUPCNF:-}" ]]; then
  echo "[INFO] No custom TOPUP config provided (optional)."
  candidate="${config_dir}/topup_${SPECIES}_${CONDITION}_${matrix}.cnf"

  if [[ -f "$candidate" ]]; then
    TOPUPCNF="$candidate"
    echo "[INFO] Auto-selected TOPUP config for ${SPECIES}_${CONDITION}_${matrix}: $TOPUPCNF"
  else
    echo "[WARN] No SPECIES/CONDITION-specific config found: ${candidate}. Check that your --SPECIES and --CONDITION flags are correct. If you are running an uncommon acquisition type or SPECIES, you may need to create a custom TOPUP config file and provide it with the --TOPUPCNF flag."
    echo "[INFO] Falling back to default ex-vivo mouse config."
    TOPUPCNF="${config_dir}/topup_mouse_exvivo_even.cnf"
  fi
else
  if [[ ! -f "$TOPUPCNF" ]]; then
    echo "[ERROR] Specified TOPUP config file does not exist: $TOPUPCNF"
    exit 1
  fi
  echo "[INFO] Using user-supplied TOPUP config: $TOPUPCNF"
fi

# Start of the pipeline
echo "==========================================="
echo " STARTING DIFFUSION PIPELINE EXECUTION "
echo "==========================================="

echo ">>> [CHECKPOINT 1]: Reading complex data and reconstructing nifti images from Bruker 2dseq files"
# note to self: check that the order of data in the complex matrix output is consistent across acquisitions/slice orientations. My current script assumes that the input is: [Nro, Npe, junk, junk, Nslice, Nvols, Nreps, Nch]
matlab -batch "addpath('${BIN_SUBDIR_PATH}'); ronan_read_2dseq_all_acqs_function_inVivo('$RAWDIR','$OUTDIR',$SHELL_NAMES_MATLAB,$SHELL_FOLDER_NUMBERS_MATLAB,$COMPLEX_RECON_FOLDER_NUMBERS_MATLAB,'$ACQ_DIM')"

magn="${OUTDIR}/all_shells/all_shells_combined_mag_sum.nii.gz"
phase="${OUTDIR}/all_shells/all_shells_combined_pha_sum.nii.gz"
name="data_complex_denoised"
domain="complex"
aux=""
echo ">>> [CHECKPOINT 2]: Running NORDIC complex denoising"
matlab -batch "try; addpath('${BIN_SUBDIR_PATH}'); run_NORDIC_steen('${magn}', '${phase}', '${OUTDIR}/', '${name}', '${domain}', '${aux}'); catch ME; disp(getReport(ME)); exit(1); end; exit(0);" | tee "${OUTDIR}/logs/log_${name}.out"
cp "$magn" "${OUTDIR}/raw_data_combined.nii.gz"

# ============================================================================
# SELF WARNING: Hard coded reorientations!!! DELETE LATER FOR BRUKER RAW!!!!
# ============================================================================

echo ">>> Reorienting denoised diffusion data"

inputdata_original="${OUTDIR}/data_complex_denoised.nii.gz"
inputdata="${OUTDIR}/data_complex_denoised_reoriented.nii.gz"

cp "$inputdata_original" "$inputdata"

# Set correct voxel dimensions before swapping axes

echo "[INFO] Reoriented data written to:"
echo "       $inputdata"

# Generate acp.txt and index.txt using the first shell method file. Doesn't actually matter which shells method file is used, assuming all shells were acquired with the same PE polarity and number of phase encodings (which is common)
echo ">>> [CHECKPOINT 3]: Generating acp.txt, index.txt, bvecs and bvals files for TOPUP and Eddy"
${BIN_SUBDIR_PATH}/file_generation.sh "${OUTDIR}" "${METHOD_FILE}" "${inputdata}" "${INDEXTXT}"
shell_sizes=$(awk -F'\t' '
{
    split($2,a," / ")
    shell=tolower(a[1])
    if (!(shell in seen)) order[++n]=shell
    seen[shell]++
}
END {
    for (i=1;i<=n;i++) printf "%s%s", seen[order[i]], (i<n?" ":"")
}
' "${OUTDIR}/all_shells/all_shells_volume_order.txt")
${BIN_SUBDIR_PATH}/detect_b0s.sh "${inputdata}" "${OUTDIR}" "${shell_sizes}" "${OUTDIR}/b0_positions.txt"
reps=""
reps_list=""
for FOLDER in "${shell_folders_arr[@]}"; do
    METHOD_FILE="${OUTDIR}/method_${FOLDER}"
    # Exit if BlipDownYN=Yes
    if grep -q '^##\$BlipDownYN=Yes' "$METHOD_FILE"; then
        echo "[ERROR] BlipDownYN=Yes found in $METHOD_FILE within the shell folders."
        echo "[ERROR] Please ensure that the blipdown acquisition is separate from the diffusion shells."
        exit 1
    fi
    # Extract repetitions value
    reps=$(grep -m1 '^##\$PVM_NRepetitions=' "$METHOD_FILE" | cut -d'=' -f2)
    reps_list+="${reps} "
done
# Trim trailing space
reps_list=$(echo "$reps_list" | sed 's/[[:space:]]*$//')

shell_folders_list="${shell_folders_arr[*]}"
# auto-detect bvecs and bvals from the method files and write to the output directory. This script will also check that the number of bvecs and bvals matches the number of volumes in the nifti data.
${BIN_SUBDIR_PATH}/extract_bvecs_bvals.sh "${OUTDIR}" "$shell_folders_list" "$reps_list"

# ============================================================================
# SELF WARNING: Hard coded reorientations!!! DELETE LATER FOR BRUKER RAW!!!!
# ============================================================================
# Preserve raw extracted gradients for QC
cp "${OUTDIR}/bvecs" "${OUTDIR}/bvecs_raw_extracted"

python3 ${BIN_SUBDIR_PATH}/transform_bvecs.py "${OUTDIR}/bvecs" "${OUTDIR}/bvecs"

cp "${OUTDIR}/bvecs" "${OUTDIR}/bvecs_original_image_space"


# CHECKPOINT 4: Drift correction. Decide what method to use based on: 1. if b0s are sufficiently interleaved; 2. the users optional DRIFT_METHOD input
B0_POSITIONS="${OUTDIR}/b0_positions.txt"
MAX_DWI_BETWEEN_B0=20

[[ -f "${B0_POSITIONS}" ]] || {
    echo "[ERROR] b0 positions file not found: ${B0_POSITIONS}"
    exit 1
}

REQUESTED_DRIFT_METHOD="${DRIFT_METHOD}"
EFFECTIVE_DRIFT_METHOD="${DRIFT_METHOD}"

# Check whether b0s are sufficiently interleaved for b0-based correction
read -ra B0_POS <<< "$(tr '\n' ' ' < "${B0_POSITIONS}")"
B0_INTERLEAVED=true
FALLBACK_REASON=""

if (( ${#B0_POS[@]} < 2 )); then
    B0_INTERLEAVED=false
    FALLBACK_REASON="only ${#B0_POS[@]} b0 volume(s) detected"
else
    for ((i=1; i<${#B0_POS[@]}; i++)); do
        n_between=$(( B0_POS[i] - B0_POS[i-1] - 1 ))

        if (( n_between > MAX_DWI_BETWEEN_B0 )); then
            B0_INTERLEAVED=false
            FALLBACK_REASON="${n_between} volumes between b0s ${B0_POS[i-1]} and ${B0_POS[i]} (maximum=${MAX_DWI_BETWEEN_B0})"
            break
        fi
    done
fi

# b0 method requires sufficiently interleaved b0s
if [[ "${REQUESTED_DRIFT_METHOD}" == "b0" && "${B0_INTERLEAVED}" == false ]]; then
    EFFECTIVE_DRIFT_METHOD="shell"
fi

echo ">>> [CHECKPOINT 4]: Drift Correction"
echo ">>> Requested method: ${REQUESTED_DRIFT_METHOD}"
echo ">>> b0 interleaving suitable: ${B0_INTERLEAVED}"

if [[ "${EFFECTIVE_DRIFT_METHOD}" != "${REQUESTED_DRIFT_METHOD}" ]]; then
    echo ">>> WARNING: ${FALLBACK_REASON}"
    echo ">>> Falling back to shell-wise correction"
fi

echo ">>> Effective method: ${EFFECTIVE_DRIFT_METHOD}"

# Run correction
if [[ "${EFFECTIVE_DRIFT_METHOD}" == "shell" ]]; then

    python ${BIN_SUBDIR_PATH}/linear_shellwise_drift_correcion.py \
        -d "${inputdata}" \
        -b "${OUTDIR}/bvals" \
        -o "${OUTDIR}/data_detrended.nii.gz"

else

    python ${BIN_SUBDIR_PATH}/b0_based_drift_correction.py \
        -d "${inputdata}" \
        --b0-positions "${B0_POSITIONS}" \
        -o "${OUTDIR}/data_detrended.nii.gz" \
        --qc-prefix "${OUTDIR}/b0_drift"

fi

inputdata="${OUTDIR}/data_detrended.nii.gz"

# perform Gibbs ringing correction on the merged data
echo ">>> [CHECKPOINT 5]: Gibbs ringing correction"
if [[ "${ACQ_DIM}" == "3D" ]]; then
  echo "[INFO] 3D acquisition detected — Gibbs correction SKIPPED (temporary)"
  cp "${inputdata}" "${OUTDIR}/data_gibbs.nii.gz"
else
  echo "[INFO] 2D acquisition detected — using MRtrix mrdegibbs"
  mrdegibbs -force "${inputdata}" "${OUTDIR}/data_gibbs.nii.gz" &> "${OUTDIR}/logs/mrdegibbs.log"
fi


# ============================================================================
# Temporarily return data to original orientation for TOPUP / Eddy
# ============================================================================

echo "[INFO] Returning Gibbs-corrected data to original orientation for Eddy."

EDDY_DATA="${OUTDIR}/data_gibbs_eddyspace.nii.gz"

cp "${OUTDIR}/data_gibbs.nii.gz" "$EDDY_DATA"

# Inverse of: x z -y
#
# new x = old x
# new y = -old z
# new z = old y

fslswapdim \
    "$EDDY_DATA" \
    x -z y \
    "$EDDY_DATA"

# Original voxel dimensions
fslchpixdim \
    "$EDDY_DATA" \
    0.3 0.3 0.6

cp "${OUTDIR}/bvecs" "${OUTDIR}/bvecs_eddyspace"

${BIN_SUBDIR_PATH}/reorient_bvecs.sh "${OUTDIR}/bvecs_eddyspace" inverse

# prepare TOPUP input by extracting the first b0 and merging with blipdown
FIRST_SHELL_B0="${OUTDIR}/all_shells/all_shells_combined_mag_sum.nii.gz"

if [[ ! -f "$FIRST_SHELL_B0" ]]; then
    echo "[ERROR] First-shell b0 not found:"
    echo "        $FIRST_SHELL_B0"
    exit 1
fi

if ! grep -qx '0' "${OUTDIR}/b0_positions.txt"; then
    echo "[ERROR] Volume 0 is not listed as a b0 in ${OUTDIR}/b0_positions.txt"
    exit 1
fi

echo "[INFO] Confirmed volume 0 is a b0."
echo "[INFO] Using first volume of first shell as TOPUP blip-up."

# Extract blip-up
fslroi "${RAWDIR}/9/pdata/1/nifti/BCAN_15_2e_T2w_QSM_Diffusion_9_1_1.nii" "${OUTDIR}/b0_blipup.nii.gz" 0 1

# --------------------------------------------------------------------------
# Check matrix dimensions before copying geometry
# --------------------------------------------------------------------------

for axis in 1 2 3; do

    up=$(fslval "${OUTDIR}/b0_blipup.nii.gz" "dim${axis}")
    down=$(fslval "${OUTDIR}/blipdown.nii.gz" "dim${axis}")

    if [[ "$up" != "$down" ]]; then
        echo "[ERROR] Blip-up/down dim${axis} mismatch: ${up} vs ${down}"
        exit 1
    fi

done

# --------------------------------------------------------------------------
# TEMP FIX:
# Copy known blip-down geometry to reconstructed blip-up
# --------------------------------------------------------------------------

echo "[INFO] Copying blip-down geometry to blip-up."

fslcpgeom "${OUTDIR}/blipdown.nii.gz" "${OUTDIR}/b0_blipup.nii.gz"

# --------------------------------------------------------------------------
# Merge TOPUP input
# --------------------------------------------------------------------------

B0_TOPUP="${OUTDIR}/b0_topup.nii.gz"

fslmerge -t "$B0_TOPUP" "${OUTDIR}/b0_blipup.nii.gz" "${OUTDIR}/blipdown.nii.gz"

echo "[INFO] TOPUP input created:"
echo "       $B0_TOPUP"

# note to self: I might need to add a reorientation to b0_topup here as the topup input cannot have PE in the z direction.
# --scale IS A TEMP FIX UNTIL BRUKER RAW IMPLEMENTATION
echo ">>> [CHECKPOINT 6]: Running TOPUP for susceptibility bias field estimation"
topup --imain="$B0_TOPUP" --datain="${OUTDIR}/acp.txt" --config="$TOPUPCNF" --out="${OUTDIR}/topup_output" --fout="${OUTDIR}/topup_field" --iout="${OUTDIR}/topup_unwarped_images" --logout="${OUTDIR}/logs/topup.log" --scale=1 --verbose

fslmaths "$EDDY_DATA" -mul 0 -add 1 "${OUTDIR}/ones_mask_eddyspace"
fslroi "${OUTDIR}/ones_mask_eddyspace" "${OUTDIR}/ones_mask_eddyspace" 0 1

if [[ $(wc -w <<< "$shell_sizes") -gt 1 ]]; then
    shelled=true
else
    shelled=false
fi
echo ">>> [CHECKPOINT 7]: Running eddy for susceptibility, motion, eddy-current, and outlier correction"

if [[ "$shelled" == true ]]; then
    jid_eddy=`fsl_sub --coprocessor cuda -q gpu_long -l "${OUTDIR}/logs/eddy.log" eddy_cuda --imain="$EDDY_DATA" --mask="${OUTDIR}/ones_mask_eddyspace" --acqp="${OUTDIR}/acp.txt" --index="${OUTDIR}/index.txt" --bvecs="${OUTDIR}/bvecs_eddyspace" --bvals="${OUTDIR}/bvals" --topup="${OUTDIR}/topup_output" --repol --out="${OUTDIR}/data_gibbs_eddy" --data_is_shelled`
else
    jid_eddy=`fsl_sub --coprocessor cuda -q gpu_long -l "${OUTDIR}/logs/eddy.log" eddy_cuda --imain="$EDDY_DATA" --mask="${OUTDIR}/ones_mask_eddyspace" --acqp="${OUTDIR}/acp.txt" --index="${OUTDIR}/index.txt" --bvecs="${OUTDIR}/bvecs_eddyspace" --bvals="${OUTDIR}/bvals" --topup="${OUTDIR}/topup_output" --repol --out="${OUTDIR}/data_gibbs_eddy"`
fi
echo "Submitted eddy job: $jid_eddy"

jid_reorient_eddy=$(fsl_sub -j "$jid_eddy" -q short -l "${OUTDIR}/logs/reorient_eddy.log" ${BIN_SUBDIR_PATH}/reorient_eddy_output.sh "${OUTDIR}")

shell_sizes_post="${shell_sizes// /,}"
reps_list_post="${reps_list// /,}"

if [[ "$COMBINE_REPS" == "TRUE" ]]; then
    echo ">>> [CHECKPOINT 8]: Combining repetitions and correcting bvecs/bvals accordingly"
    echo "[INFO] Repetition averaging requested."
    jid_pre_fitting=$(fsl_sub -j "$jid_reorient_eddy" -q short -l "${OUTDIR}/logs/combine_reps.log" ${BIN_SUBDIR_PATH}/combine_reps.sh "${OUTDIR}" "${shell_sizes_post}" "${reps_list_post}")
    echo "Submitted repetition-combination job: ${jid_pre_fitting}"
else
    echo ">>> [CHECKPOINT 8]: Skipping repetition combination"
    echo "[INFO] COMBINE_REPS=FALSE: retaining individual repetitions."
    jid_pre_fitting=$(fsl_sub -j "$jid_reorient_eddy" -q short -l "${OUTDIR}/logs/prepare_fitting_input.log" \
        bash -c "
            set -euo pipefail
            mkdir -p '${OUTDIR}/fitting_input'
            cp '${OUTDIR}/data_gibbs_eddy_reoriented.nii.gz' '${OUTDIR}/fitting_input/data.nii.gz'
            cp '${OUTDIR}/bvals' '${OUTDIR}/fitting_input/bvals'
            cp '${OUTDIR}/data_gibbs_eddy_reoriented.eddy_rotated_bvecs' '${OUTDIR}/fitting_input/bvecs'
            cp '${OUTDIR}/ones_mask_reoriented.nii.gz' '${OUTDIR}/fitting_input/nodif_brain_mask.nii.gz'
        ")
    echo "Submitted fitting-input preparation job: ${jid_pre_fitting}"
fi

FITTING_DIR="${OUTDIR}/fitting_input"
DTIDKI_DIR="${OUTDIR}/dtidki_input"
echo ">>> [CHECKPOINT 9]: Submitting DTI + DKI model fitting"

jid_dtidki_input=$(fsl_sub -j "$jid_pre_fitting" -q short -l "${OUTDIR}/logs/dtidki_input.log" ${BIN_SUBDIR_PATH}/select_bvalue_shells.sh "${FITTING_DIR}" "${DTIDKI_DIR}" "${DTIDKI_BVALS}")

jid_dtifit=$(fsl_sub -j "$jid_dtidki_input" -q short -l "${OUTDIR}/logs/dtifit.log" \
    bash -c "
        set -euo pipefail
        mkdir -p '${OUTDIR}/dtifit'
        dtifit -k '${DTIDKI_DIR}/data.nii.gz' -m '${DTIDKI_DIR}/nodif_brain_mask.nii.gz' -b '${DTIDKI_DIR}/bvals' -r '${DTIDKI_DIR}/bvecs' -o '${OUTDIR}/dtifit/dtifit' --kurtdir

        # Rename axial kurtosis map for clarity
        mv '${OUTDIR}/dtifit/dtifit_kurt1.nii.gz' '${OUTDIR}/dtifit/dtifit_AK.nii.gz'

        # Mean Kurtosis (MK)
        fslmaths '${OUTDIR}/dtifit/dtifit_AK.nii.gz' \
            -add '${OUTDIR}/dtifit/dtifit_kurt2.nii.gz' \
            -add '${OUTDIR}/dtifit/dtifit_kurt3.nii.gz' \
            -div 3 \
            '${OUTDIR}/dtifit/dtifit_MK.nii.gz'

        # Radial Kurtosis (RK)
        fslmaths \
            '${OUTDIR}/dtifit/dtifit_kurt2.nii.gz' \
            -add '${OUTDIR}/dtifit/dtifit_kurt3.nii.gz' \
            -div 2 \
            '${OUTDIR}/dtifit/dtifit_RK.nii.gz'
    ")
echo "[INFO] Submitted DTI/DKI job: ${jid_dtifit}"

if [[ "$RUN_BEDPOSTX" == "TRUE" ]]; then
    echo ">>> [CHECKPOINT 10]: Submitting BedpostX model fitting"
    BEDPOSTX_DIR="${OUTDIR}/bedpostx_input"
    jid_bedpostx_input=$(fsl_sub -j "$jid_pre_fitting" -q short -l "${OUTDIR}/logs/bedpostx_input.log" ${BIN_SUBDIR_PATH}/select_bvalue_shells.sh "${FITTING_DIR}" "${BEDPOSTX_DIR}" "${BEDPOSTX_BVALS}")

    jid_bedpostX=$(fsl_sub -j "$jid_bedpostx_input" --coprocessor cuda -q gpu_long -l "${OUTDIR}/logs/bedpostx.log" bedpostx_gpu "${BEDPOSTX_DIR}")
    echo "[INFO] Submitted BedpostX job: ${jid_bedpostX}"
else
    echo ">>> [CHECKPOINT 10]: Skipping BedpostX (--RUN_BEDPOSTX=FALSE is default)"
fi

if [[ "$RUN_NODDI" == "TRUE" ]]; then
    echo ">>> [CHECKPOINT 11]: Submitting NODDI model fitting"
    NODDI_DIR="${OUTDIR}/noddi_input"

    jid_noddi_input=$(fsl_sub -j "$jid_pre_fitting" -q short -l "${OUTDIR}/logs/noddi_input.log" ${BIN_SUBDIR_PATH}/select_bvalue_shells.sh "${FITTING_DIR}" "${NODDI_DIR}" "${NODDI_BVALS}")

    NODDI_CONFIG="${OUTDIR}/noddi_configuration_file.sh"

    cat > "${NODDI_CONFIG}" <<EOF
#!/bin/bash
# Auto-generated NODDI configuration file

DATA_DIR="${NODDI_DIR}"
MODEL_DIR="${OUTDIR}/noddi"
LOG_DIR="${OUTDIR}/logs"
SPECIES="${SPECIES}"
CONDITION="${CONDITION}"
DWI="\${DATA_DIR}/data.nii.gz"
BVECS="\${DATA_DIR}/bvecs"
BVALS="\${DATA_DIR}/bvals"
MASK="\${DATA_DIR}/nodif_brain_mask.nii.gz"
EOF

    echo "[INFO] NODDI configuration file written: ${NODDI_CONFIG}"
    # Determine acquisition-specific NODDI parameters
    if [[ "$CONDITION" == "invivo" ]]; then
        MODEL_FLAG="--invivo"
    elif [[ "$CONDITION" == "exvivo" ]]; then
        MODEL_FLAG="--exvivo"
    else
        echo "[ERROR] Unknown CONDITION: ${CONDITION}"
        exit 1
    fi

    # Add dot compartment if requested
    NODDI_ARGS=(
        "${NODDI_CONFIG}"
        "${MODEL_FLAG}"
    )

    if [[ "$NODDI_DOT" == "TRUE" ]]; then
        echo "[INFO] NODDI dot compartment enabled."
        NODDI_ARGS+=( "--with_dot" )
    else
        echo "[INFO] NODDI dot compartment disabled."
    fi

    # jid_noddi=$(fsl_sub -j "$jid_noddi_input" --coprocessor cuda -q gpu_long -l "${OUTDIR}/logs/noddi.log" /vols/Data/preclinical/WellcomeBioimaging/dMRI_pipeline/code/dMRI_model3_NODDI_model.sh "${NODDI_ARGS[@]}")
    # echo "[INFO] Submitted NODDI job: ${jid_noddi}"
    echo "Skipping NODDI job submission for now. Needs to be re-implemented."
else
    echo ">>> [CHECKPOINT 11]: Skipping NODDI (--RUN_NODDI=FALSE)"
fi

echo "==========================================="
echo " All processing steps submitted successfully."
echo " Check ${OUTDIR}/logs* for logs."
echo "==========================================="
