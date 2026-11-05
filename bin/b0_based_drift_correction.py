#!/usr/bin/env fslpython

"""
Ronan McNeill 2026: contact ronan.mcneill@ndcn.ox.ac.uk for corrections or updates if needed.


Global b0-based temporal drift correction for diffusion MRI.

Repeated b0 volumes are used to estimate a global multiplicative signal scale over acquisition time.

SIGNAL ROI
----------
A signal ROI is generated automatically once from the first/reference b0 so that the signal scale isn't weighted by background voxels
This isn't a brain mask per se, nor does it need to be, as the same voxels are used for all b0s.

A robust maximum is estimated as the 99th percentile of the reference b0.
Voxels with signal >= --signal-threshold (default 20%) of this value are included.

The same ROI is then used to measure every subsequent b0.

DRIFT ESTIMATION
----------------
For each pair of consecutive b0s:

    1. Calculates their mean signal within the fixed signal ROI.

    2. Calculates the relative signal difference between those 2 b0s.

    3. If the difference is <= --jump-threshold (tuned default is 3%):
           Assume gradual drift and linearly interpolate the correction
           factor between the two b0s.

       If the difference is > --jump-threshold:
           Treat the change as a discontinuity, e.g. reference-power
           recalibration occurred for separately acquired shell. 
           Hold the correction factor from the first b0 constant until the new b0.

After the final b0, its correction factor is held constant for all remaining volumes.

The diffusion weighting and ordering of the DWI volumes are not used and are irrelevant to this drift correction method.
Consequently, it can be used if data is shelled, perfectly interleaved, and anything in between.
The only requirement is that there are sufficiently interleaved b0s. This requirement is pre-checked in the pipeline before running.

CORRECTION
----------
    corrected_volume(t) = measured_volume(t) / scale_factor(t)

The first b0 defines scale_factor = 1.

QC OUTPUTS
----------
If --qc-prefix is supplied, the script saves:

    <prefix>_signal_roi.nii.gz
        Automatically generated fixed signal ROI.

    <prefix>_b0_before.nii.gz
        4D image containing all b0 volumes before correction.

    <prefix>_b0_after.nii.gz
        4D image containing the same b0 volumes after correction.

    <prefix>_b0_signal.txt
        Measured b0 signal and relative scale at each b0.

    <prefix>_drift_factors.txt
        Correction factor assigned to every acquired volume.
"""

import argparse
import os.path as op

import nibabel as nib
import numpy as np


# =========================================================================
# Input handling
# =========================================================================

def load_b0_positions(filename):
    """Load and validate zero-based b0 volume indices."""

    positions = np.loadtxt(filename, dtype=int)
    positions = np.atleast_1d(positions)

    if positions.size == 0:
        raise ValueError("No b0 positions found.")

    if np.any(positions < 0):
        raise ValueError("b0 positions must be >= 0.")

    if len(np.unique(positions)) != len(positions):
        raise ValueError(
            "b0_positions.txt contains duplicate positions."
        )

    return np.sort(positions)


# =========================================================================
# Automatic signal ROI
# =========================================================================

def create_signal_roi(
    reference_b0,
    threshold_percent,
    robust_percentile=99.0,
):
    """
    Create a fixed signal ROI from the first/reference b0.

    Instead of using the absolute maximum voxel intensity, a robust maximum
    is estimated from the specified percentile of the reference b0.

    The ROI threshold is:

        threshold =
            threshold_percent / 100 * robust_maximum

    Example:

        robust maximum = 1000
        --signal-threshold = 20

        ROI threshold = 200

    Therefore all reference-b0 voxels >= 200 are included.

    The ROI is generated once and subsequently used for ALL b0 volumes.
    """

    if not 0 < threshold_percent < 100:
        raise ValueError(
            "--signal-threshold must be between 0 and 100."
        )

    if not 0 < robust_percentile <= 100:
        raise ValueError(
            "robust_percentile must be between 0 and 100."
        )

    finite_values = reference_b0[
        np.isfinite(reference_b0)
    ]

    if finite_values.size == 0:
        raise ValueError(
            "Reference b0 contains no finite values."
        )

    robust_max = np.percentile(
        finite_values,
        robust_percentile,
    )

    if robust_max <= 0:
        raise ValueError(
            "Reference b0 robust maximum must be greater than zero."
        )

    threshold_value = (
        threshold_percent / 100.0
    ) * robust_max

    roi = (
        np.isfinite(reference_b0)
        & (reference_b0 >= threshold_value)
    )

    n_voxels = np.count_nonzero(roi)

    if n_voxels == 0:
        raise ValueError(
            "Automatic signal ROI contains no voxels."
        )

    return roi, threshold_value, robust_max


def roi_mean(volume, roi):
    """Calculate mean signal within the fixed signal ROI."""

    values = volume[roi]

    values = values[np.isfinite(values)]

    if values.size == 0:
        raise ValueError(
            "Signal ROI contains no finite values in this volume."
        )

    return np.mean(values)


# =========================================================================
# Difference between consecutive b0 measurements
# =========================================================================

def symmetric_relative_difference(a, b):
    """
    Calculate the symmetric fractional difference between two b0 signals.

                2 * |a - b|
        diff = -------------
                   a + b

    Example:

        a = 1000
        b = 1020

        diff = 0.0198 = 1.98%

    This treats equivalent upward and downward changes symmetrically.
    """

    denominator = a + b

    if denominator <= 0:
        raise ValueError(
            "Cannot calculate relative difference for "
            "non-positive b0 means."
        )

    return (
        2.0 * abs(a - b)
        / denominator
    )


# =========================================================================
# Estimate correction factors
# =========================================================================

def estimate_scale_factors(
    nvols,
    b0_positions,
    b0_means,
    jump_threshold,
):
    """
    Estimate one global multiplicative scale factor for every volume.

    Each measured b0 is expressed relative to the first/reference b0:

        scale_i = mean_b0_i / mean_b0_reference

    Between consecutive b0s:

        Difference <= threshold:
            Linearly interpolate between their scale factors.

        Difference > threshold:
            Treat the change as a discontinuity.
            Hold the preceding scale factor constant until the new b0.

    After the final b0:
        Hold the final b0 scale constant.
    """

    reference = b0_means[0]

    if reference <= 0:
        raise ValueError(
            "Reference b0 mean must be greater than zero."
        )

    # ---------------------------------------------------------------------
    # Scale measured at each b0 relative to the first b0
    # ---------------------------------------------------------------------

    b0_scales = (
        b0_means
        / reference
    )

    scales = np.empty(
        nvols,
        dtype=float,
    )

    interval_info = []

    # ---------------------------------------------------------------------
    # Any volumes before the first b0
    # ---------------------------------------------------------------------

    first_b0 = b0_positions[0]

    scales[:first_b0] = b0_scales[0]

    # ---------------------------------------------------------------------
    # Intervals between consecutive b0s
    # ---------------------------------------------------------------------

    for i in range(
        len(b0_positions) - 1
    ):

        start = b0_positions[i]
        stop = b0_positions[i + 1]

        mean1 = b0_means[i]
        mean2 = b0_means[i + 1]

        scale1 = b0_scales[i]
        scale2 = b0_scales[i + 1]

        difference = (
            symmetric_relative_difference(
                mean1,
                mean2,
            )
        )

        # ================================================================
        # SMALL CHANGE:
        # Assume gradual drift
        # ================================================================

        if difference <= jump_threshold:

            vols = np.arange(
                start,
                stop,
            )

            fraction = (
                (vols - start)
                / float(stop - start)
            )

            scales[vols] = (
                scale1
                + fraction
                * (scale2 - scale1)
            )

            interval_type = "linear"

        # ================================================================
        # LARGE CHANGE:
        # Assume discontinuity / reference-power recalibration
        # ================================================================

        else:

            # The future b0 must not influence volumes acquired
            # before the detected discontinuity.

            scales[start:stop] = scale1

            interval_type = "piecewise"

        interval_info.append(
            {
                "start": start,
                "stop": stop,
                "mean1": mean1,
                "mean2": mean2,
                "scale1": scale1,
                "scale2": scale2,
                "difference": difference,
                "type": interval_type,
            }
        )

    # ---------------------------------------------------------------------
    # After final b0
    # ---------------------------------------------------------------------

    last_b0 = b0_positions[-1]

    scales[last_b0:] = (
        b0_scales[-1]
    )

    return (
        scales,
        b0_scales,
        interval_info,
    )


# =========================================================================
# Main
# =========================================================================

def main():

    parser = argparse.ArgumentParser(
        description=(
            "Global b0-based temporal drift correction "
            "using an automatically generated signal ROI."
        )
    )

    # ---------------------------------------------------------------------
    # Required inputs
    # ---------------------------------------------------------------------

    parser.add_argument(
        "-d",
        "--data",
        required=True,
        help=(
            "Input 4D diffusion MRI NIfTI."
        ),
    )

    parser.add_argument(
        "--b0-positions",
        required=True,
        help=(
            "Text file containing zero-based "
            "b0 volume indices."
        ),
    )

    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help=(
            "Output drift-corrected NIfTI."
        ),
    )

    # ---------------------------------------------------------------------
    # ROI settings
    # ---------------------------------------------------------------------

    parser.add_argument(
        "--signal-threshold",
        type=float,
        default=20.0,
        help=(
            "Include reference-b0 voxels with signal >= this "
            "percentage of the robust reference intensity "
            "(default: 20)."
        ),
    )

    parser.add_argument(
        "--roi-percentile",
        type=float,
        default=99.0,
        help=(
            "Percentile of the reference b0 used as the robust "
            "maximum when generating the signal ROI "
            "(default: 99)."
        ),
    )

    # ---------------------------------------------------------------------
    # Drift settings
    # ---------------------------------------------------------------------

    parser.add_argument(
        "--jump-threshold",
        type=float,
        default=0.03,
        help=(
            "Fractional difference between consecutive b0s above "
            "which the change is treated as a discontinuity "
            "(default: 0.03 = 3%%)."
        ),
    )

    # ---------------------------------------------------------------------
    # QC
    # ---------------------------------------------------------------------

    parser.add_argument(
        "--qc-prefix",
        default=None,
        help=(
            "Optional prefix for QC outputs."
        ),
    )

    args = parser.parse_args()

    # =====================================================================
    # Load diffusion data
    # =====================================================================

    filename = op.expandvars(
        args.data
    )

    img = nib.load(
        filename,
        mmap=False,
    )

    data = (
        img
        .get_fdata()
        .astype(np.float64)
    )

    if data.ndim != 4:
        raise ValueError(
            "Input diffusion data must be 4D."
        )

    nvols = data.shape[3]

    print(
        f"Input volumes: {nvols}"
    )

    # =====================================================================
    # Load b0 positions
    # =====================================================================

    b0_positions = (
        load_b0_positions(
            op.expandvars(
                args.b0_positions
            )
        )
    )

    if np.any(
        b0_positions >= nvols
    ):
        raise ValueError(
            "b0_positions.txt contains a volume index "
            "outside the input data."
        )

    print(
        f"Number of b0s: "
        f"{len(b0_positions)}"
    )

    print(
        f"b0 positions: "
        f"{b0_positions}"
    )

    # =====================================================================
    # Extract original b0-only 4D
    # =====================================================================

    b0_before = (
        data[..., b0_positions]
        .copy()
    )

    # =====================================================================
    # Generate fixed signal ROI from FIRST b0
    # =====================================================================

    reference_position = (
        b0_positions[0]
    )

    reference_b0 = (
        data[..., reference_position]
    )

    (
        roi,
        roi_threshold,
        robust_max,
    ) = create_signal_roi(
        reference_b0,
        args.signal_threshold,
        args.roi_percentile,
    )

    n_roi_voxels = (
        np.count_nonzero(roi)
    )

    n_total_voxels = (
        roi.size
    )

    roi_fraction = (
        100.0
        * n_roi_voxels
        / n_total_voxels
    )

    print(
        "\nAutomatic signal ROI:"
    )

    print(
        f"  Reference b0 volume: "
        f"{reference_position}"
    )

    print(
        f"  Robust percentile:   "
        f"{args.roi_percentile:.2f}%"
    )

    print(
        f"  Robust intensity:    "
        f"{robust_max:.6f}"
    )

    print(
        f"  Signal threshold:    "
        f"{args.signal_threshold:.2f}% "
        f"of robust intensity"
    )

    print(
        f"  Threshold intensity: "
        f"{roi_threshold:.6f}"
    )

    print(
        f"  Selected voxels:     "
        f"{n_roi_voxels} / "
        f"{n_total_voxels} "
        f"({roi_fraction:.2f}%)"
    )

    # =====================================================================
    # Measure every b0 using SAME ROI
    # =====================================================================

    b0_means = np.asarray(
        [
            roi_mean(
                data[..., position],
                roi,
            )
            for position
            in b0_positions
        ]
    )

    print(
        "\nGlobal b0 signals:"
    )

    for position, mean in zip(
        b0_positions,
        b0_means,
    ):

        print(
            f"  volume "
            f"{position:5d}: "
            f"{mean:.6f}"
        )

    # =====================================================================
    # Estimate temporal correction
    # =====================================================================

    (
        scales,
        b0_scales,
        intervals,
    ) = estimate_scale_factors(
        nvols=nvols,
        b0_positions=b0_positions,
        b0_means=b0_means,
        jump_threshold=args.jump_threshold,
    )

    # =====================================================================
    # Report interval decisions
    # =====================================================================

    print(
        "\nIntervals:"
    )

    print(
        " start    stop"
        "       b0_1"
        "       b0_2"
        "      scale1"
        "      scale2"
        "    difference"
        "    method"
    )

    for interval in intervals:

        print(
            f"{interval['start']:6d} "
            f"{interval['stop']:7d} "
            f"{interval['mean1']:11.3f} "
            f"{interval['mean2']:11.3f} "
            f"{interval['scale1']:11.5f} "
            f"{interval['scale2']:11.5f} "
            f"{100 * interval['difference']:10.3f}% "
            f"   {interval['type']}"
        )

    # =====================================================================
    # Safety check
    # =====================================================================

    if (
        np.any(~np.isfinite(scales))
        or np.any(scales <= 0)
    ):

        raise ValueError(
            "Estimated correction contains "
            "invalid scale factors."
        )

    # =====================================================================
    # Apply correction
    # =====================================================================

    corrected = (
        data
        / scales[
            None,
            None,
            None,
            :
        ]
    )

    # =====================================================================
    # Extract corrected b0-only 4D
    # =====================================================================

    b0_after = (
        corrected[
            ...,
            b0_positions
        ]
        .copy()
    )

    # =====================================================================
    # Verify corrected b0 means
    # =====================================================================

    b0_means_after = np.asarray(
        [
            roi_mean(
                b0_after[..., i],
                roi,
            )
            for i in range(
                b0_after.shape[3]
            )
        ]
    )

    print(
        "\nCorrected b0 signals:"
    )

    for (
        position,
        before,
        after,
    ) in zip(
        b0_positions,
        b0_means,
        b0_means_after,
    ):

        print(
            f"  volume {position:5d}: "
            f"{before:.6f} -> "
            f"{after:.6f}"
        )

    # =====================================================================
    # Save corrected full 4D image
    # =====================================================================

    corrected_img = (
        nib.Nifti1Image(
            corrected,
            img.affine,
            header=img.header.copy(),
        )
    )

    nib.save(
        corrected_img,
        args.output,
    )

    print(
        f"\nSaved corrected data: "
        f"{args.output}"
    )

    # =====================================================================
    # Save QC outputs
    # =====================================================================

    if args.qc_prefix is not None:

        prefix = op.expandvars(
            args.qc_prefix
        )

        # -----------------------------------------------------------------
        # Signal ROI
        # -----------------------------------------------------------------

        roi_header = (
            img.header.copy()
        )

        roi_header.set_data_dtype(
            np.uint8
        )

        roi_img = (
            nib.Nifti1Image(
                roi.astype(np.uint8),
                img.affine,
                header=roi_header,
            )
        )

        roi_filename = (
            f"{prefix}"
            "_signal_roi.nii.gz"
        )

        nib.save(
            roi_img,
            roi_filename,
        )

        # -----------------------------------------------------------------
        # b0-only BEFORE correction
        # -----------------------------------------------------------------

        before_header = (
            img.header.copy()
        )

        b0_before_img = (
            nib.Nifti1Image(
                b0_before,
                img.affine,
                header=before_header,
            )
        )

        b0_before_filename = (
            f"{prefix}"
            "_b0_before.nii.gz"
        )

        nib.save(
            b0_before_img,
            b0_before_filename,
        )

        # -----------------------------------------------------------------
        # b0-only AFTER correction
        # -----------------------------------------------------------------

        after_header = (
            img.header.copy()
        )

        b0_after_img = (
            nib.Nifti1Image(
                b0_after,
                img.affine,
                header=after_header,
            )
        )

        b0_after_filename = (
            f"{prefix}"
            "_b0_after.nii.gz"
        )

        nib.save(
            b0_after_img,
            b0_after_filename,
        )

        # -----------------------------------------------------------------
        # b0 signal table
        #
        # Columns:
        #   original volume
        #   mean before correction
        #   mean after correction
        #   relative b0 scale
        # -----------------------------------------------------------------

        b0_qc = np.column_stack(
            (
                b0_positions,
                b0_means,
                b0_means_after,
                b0_scales,
            )
        )

        b0_filename = (
            f"{prefix}"
            "_b0_signal.txt"
        )

        np.savetxt(
            b0_filename,
            b0_qc,
            fmt=[
                "%d",
                "%.8f",
                "%.8f",
                "%.8f",
            ],
            header=(
                "original_volume "
                "b0_mean_before "
                "b0_mean_after "
                "relative_scale"
            ),
        )

        # -----------------------------------------------------------------
        # Scale factor applied to EVERY original volume
        # -----------------------------------------------------------------

        volume_qc = (
            np.column_stack(
                (
                    np.arange(
                        nvols
                    ),
                    scales,
                )
            )
        )

        factor_filename = (
            f"{prefix}"
            "_drift_factors.txt"
        )

        np.savetxt(
            factor_filename,
            volume_qc,
            fmt=[
                "%d",
                "%.8f",
            ],
            header=(
                "volume "
                "scale_factor"
            ),
        )

        # -----------------------------------------------------------------
        # Report QC files
        # -----------------------------------------------------------------

        print(
            "\nQC outputs:"
        )

        print(
            f"  {roi_filename}"
        )

        print(
            f"  {b0_before_filename}"
        )

        print(
            f"  {b0_after_filename}"
        )

        print(
            f"  {b0_filename}"
        )

        print(
            f"  {factor_filename}"
        )


if __name__ == "__main__":
    main()