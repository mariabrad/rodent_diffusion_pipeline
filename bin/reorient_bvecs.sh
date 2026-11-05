#!/bin/bash
set -euo pipefail

BVECS="$1"
MODE="$2"
TMP="${BVECS}.tmp"

mapfile -t lines < "$BVECS"

(( ${#lines[@]} == 3 )) || {
    echo "[ERROR] Expected exactly 3 bvec rows."
    exit 1
}

read -r -a x <<< "${lines[0]}"
read -r -a y <<< "${lines[1]}"
read -r -a z <<< "${lines[2]}"

case "$MODE" in

    bruker_to_image)
        # Raw PVM_DwDir -> original reconstructed image
        # [x,y,z] -> [x,-y,z]
        rows=(x -y z)
        ;;

    forward)
        # Original image -> analysis space
        # Image: fslswapdim x z -y
        # [x,y,z] -> [x,z,-y]
        rows=(x z -y)
        ;;

    inverse)
        # Analysis space -> original/Eddy space
        # Inverse of x z -y
        # [x,y,z] -> [x,-z,y]
        rows=(x -z y)
        ;;

    *)
        echo "[ERROR] Mode must be: bruker_to_image, forward, or inverse"
        exit 1
        ;;
esac

{
    for spec in "${rows[@]}"; do

        name="${spec#-}"
        declare -n row="$name"

        for v in "${row[@]}"; do
            if [[ "$spec" == -* ]]; then
                awk -v x="$v" 'BEGIN {printf "%.10g ", -x}'
            else
                printf "%s " "$v"
            fi
        done

        echo
    done
} > "$TMP"

mv "$TMP" "$BVECS"