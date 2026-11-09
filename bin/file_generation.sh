#!/bin/bash
# file_generation.sh
# Usage: file_generation.sh <outputdir> <method_file> <merged_4d_nii> [indexfile]
# This script generates the acp.txt and index.txt files needed
set -euo pipefail

outputdir="$1"
method_file="$2"
merged4d="$3"
INDEX_FILE="${4:-}"

# Check that the method file exists
if [[ ! -f "$method_file" ]]; then
  echo "Error: Could not find method file: $method_file"
  exit 1
fi

epi_echo_spacing=$(grep -m1 "##\$PVM_EpiEchoSpacing=" "$method_file" | awk -F= '{print $2}' | tr -d ' ')
epi_echo_spacing=${epi_echo_spacing:-1}
epi_echo_spacing=$(echo "$epi_echo_spacing" | tr -cd '0-9.-')
epi_echo_spacing_s=$(echo "scale=6; $epi_echo_spacing / 1000" | bc)

# note that the num_phase_encodings method extraction may not work for 3D acquisitions. Need to test
num_phase_encodings=$(awk '
  /##\$PVM_EncSteps1=/ {
    if (match($0, /\([[:space:]]*([0-9]+)[[:space:]]*\)/, m)) {
      print m[1]
      exit
    }
  }
' "$method_file")

echo "[DEBUG] num_phase_encodings=${num_phase_encodings}"
echo "[DEBUG] epi_echo_spacing_s=${epi_echo_spacing_s}"

total_readout=$(echo "scale=5; ($num_phase_encodings - 1) * $epi_echo_spacing_s" | bc)

# TOPUP doesn't run with extremely small readout times
if (( $(echo "$total_readout < 0.01" | bc -l) )); then
  echo "[WARN] Calculated total_readout (${total_readout}) is less than 0.01 s."
  echo "[WARN] Setting total_readout to 0.01 s for TOPUP stability."
  total_readout="0.01"
fi

cat > "${outputdir}/acp.txt" <<EOF
1 0 0 ${total_readout}
-1 0 0 ${total_readout}
EOF

echo "[INFO] Wrote ${outputdir}/acp.txt"
cat "${outputdir}/acp.txt"

# Determine number of volumes and create/accept index.txt
if [[ ! -f "$merged4d" ]]; then
  echo "[ERROR] Could not find merged 4D image: $merged4d"
  exit 1
fi

if ! nvols=$(fslval "$merged4d" dim4 2>/dev/null | tr -cd '0-9'); then
  echo "[ERROR] fslval failed while reading dim4 from: $merged4d"
  exit 1
fi

if [[ -z "$nvols" || "$nvols" -lt 1 ]]; then
  echo "[ERROR] Could not read the number of volumes from ${merged4d}."
  exit 1
fi

# Count acqp lines (how many PE groups we allow)
acp_lines=$(grep -v '^[[:space:]]*$' "${outputdir}/acp.txt" | wc -l | tr -d '[:space:]')
if [[ "$acp_lines" -lt 1 ]]; then
  echo "[ERROR] ${outputdir}/acp.txt appears empty or invalid."
  exit 1
fi

if [[ -n "${INDEX_FILE}" ]]; then
  echo "[INFO] Using user-supplied index file: ${INDEX_FILE}"
  if [[ ! -f "${INDEX_FILE}" ]]; then
    echo "[ERROR] --indexfile path does not exist: ${INDEX_FILE}"
    exit 1
  fi

  # Normalise whitespace to single spaces on one line
  idx_norm=$(tr '\n\t' '  ' < "${INDEX_FILE}" | tr -s ' ')
  idx_count=$(echo "${idx_norm}" | awk '{print NF}')

  if [[ "${idx_count}" -ne "${nvols}" ]]; then
    echo "[ERROR] index.txt length (${idx_count}) does not match number of volumes (${nvols})."
    exit 1
  fi

  # Ensure all entries are integers within 1..acp_lines
  invalid=$(echo "${idx_norm}" | awk -v max="${acp_lines}" '
    {for(i=1;i<=NF;i++){ if($i !~ /^[0-9]+$/ || $i<1 || $i>max){ bad=1 } }}
    END{ if(bad) print "yes"; }')
  if [[ "${invalid}" == "yes" ]]; then
    echo "[ERROR] index.txt contains invalid values (must be integers in 1..${acp_lines})."
    exit 1
  fi

  echo "${idx_norm}" > "${outputdir}/index.txt"
  echo "[INFO] Wrote ${outputdir}/index.txt from user file (${idx_count} entries)."
else
  echo "[INFO] Writing index.txt assuming all volumes use the first PE line (1 = blip-up)"
  for ((i=1; i<=nvols; i++)); do
    printf '1 '
  done > "${outputdir}/index.txt"
  echo "[INFO] Wrote ${outputdir}/index.txt with ${nvols} entries (assumed all=1)."
  echo "[INFO] For alternating or custom PE groups (e.g., AP/PA), use the optional --INDEXTXT=/path/to/index.txt argument."
fi
