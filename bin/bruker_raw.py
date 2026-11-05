"""Convert Bruker scans to RAS NIfTI, always correcting to prone.

The animal is always physically prone during acquisition, but the study
metadata (ACQ_patient_pos) records whatever the researcher typed when
creating the study, which is sometimes wrong (e.g. 'Head_Supine'). brkraw
trusts that field and mis-orients the subject_ras space when it disagrees
with reality. We therefore force Head_Prone on every scan, then reorient
to canonical RAS. Correctly-labelled prone scans pass through unchanged.
"""

import re
import numpy as np
from pathlib import Path
import nibabel as nib
from nibabel.orientations import aff2axcodes, io_orientation
import brkraw
import brkraw.apps.loader.core as core

core.np = np  # patch required by this brkraw version


def get_pose(scan):
    """Return the pose recorded in the metadata ('Head_Prone'/'Head_Supine'
    /etc.), or None if not found. This is the *labelled* pose, which may not
    match physical reality — it's used only for diagnostics."""
    hit = scan.search_params("ACQ_patient_pos", file="acqp")
    if hit:
        return hit["acqp"]["ACQ_patient_pos"]

    hit = scan.search_params("PVM_StudyInstrumentPosition", file="method")
    if hit:
        return hit["method"]["PVM_StudyInstrumentPosition"]

    return None


def _slugify(value):
    """Make a metadata string safe for a filename: strip surrounding angle
    brackets, drop the trailing '(E13)' tag, and replace anything that isn't
    a letter/digit/underscore/dot/hyphen with an underscore."""
    value = value.strip().strip("<>").strip()
    value = re.sub(r"\s*\(E\d+\)\s*$", "", value)   # drop trailing (E13)
    value = re.sub(r"[^\w.\-]+", "_", value)        # slugify the rest
    return value.strip("_")


def get_sequence(scan):
    """Return the scan name from metadata, slugified for filenames
    (e.g. '3_T2map_MSME_25TE_nx5ms'), or None if not found."""
    hit = scan.search_params("ACQ_scan_name", file="acqp")
    if hit:
        return _slugify(hit["acqp"]["ACQ_scan_name"])
    return None


def convert_scan_to_ras(scan):
    """Force prone, convert to subject_ras, reorient to canonical RAS.
    Returns a nibabel image."""
    nii = scan.convert(space="subject_ras", override_subject_pose="Head_Prone")
    return nii.as_reoriented(io_orientation(nii.affine))


def convert_bruker_to_ras(study_dir, output_root, scan_ids=None, verbose=True):
    """Read a Bruker study, force every scan to prone, reorient to RAS, save.

    Parameters
    ----------
    study_dir : str or Path
        Bruker study directory.
    output_root : str or Path
        Output directory (created if missing).
    scan_ids : list[int] or None
        Scans to convert. None = all available.
    verbose : bool
        Print per-scan diagnostics, flagging any scan whose labelled pose
        was not prone (i.e. where a correction was actually applied).

    Returns
    -------
    dict : {scan_id: saved_path}
    """
    study_dir = Path(study_dir)
    output_root = Path(output_root)
    output_root.mkdir(parents=True, exist_ok=True)

    loader = brkraw.BrukerLoader(str(study_dir))
    study_name = study_dir.name

    if scan_ids is None:
        scan_ids = list(loader.avail)

    saved = {}
    for sid in scan_ids:
        try:
            scan = loader.get_scan(sid)
            labelled = get_pose(scan)
            sequence = get_sequence(scan) or "unknown"
            reor = convert_scan_to_ras(scan)

            out = output_root / f"{study_name}_scan{sid}_{sequence}_RAS.nii.gz"
            nib.save(reor, out)
            saved[sid] = out

            if verbose:
                flag = "" if labelled == "Head_Prone" else "  <- CORRECTED"
                print(f"scan {sid:>2}: {sequence:<28} "
                      f"labelled={labelled!s:<12} "
                      f"axcodes={aff2axcodes(reor.affine)}{flag}")
        except Exception as e:
            if verbose:
                print(f"scan {sid:>2}: FAILED — {type(e).__name__}: {e}")

    return saved


if __name__ == "__main__":
    import sys
    convert_bruker_to_ras(sys.argv[1], sys.argv[2])