# Rodent Diffusion MRI Preprocessing Pipeline

This is a preprocessing and simple analysis pipeline for preclinical rodent diffusion MRI data. Development is ongoing, but the software is intended to be fully adaptable for dMRI acquisitions of any nature.

The pipeline was developed for Bruker diffusion MRI acquisitions and expects Bruker file structures as input. It is designed to provide a reproducible workflow that is simplistic for the user, allowing access to a consistent preprocessing standard for the field.

> **Important:** The pipeline is under active development. Some acquisition-specific operations, particularly image and gradient reorientations, are currently hard-coded and should not be assumed to generalise to arbitrary acquisition geometries.

---

## Overview

The pipeline performs the following main steps:

1. **Bruker data reconstruction**
   - Reads complex reconstructed `2dseq` data. You currently must have complex reconstructions, easy to extract off of Paravision (Bruker's scanner console).
   - Combines receiver channels.
   - Merges diffusion acquisitions and repetitions into a single dataset.

2. **NORDIC denoising**
   - Performs complex-valued NORDIC denoising.

3. **Diffusion metadata generation**
   - Generates b-values and b-vectors from the Bruker `method` files.
   - Detects b0 volumes.
   - Generates files required by TOPUP and Eddy.

4. **Signal drift correction**
   - Supports b0-based and shell-wise signal drift correction.
   - b0-based correction is the default.
   - If b0 volumes are not sufficiently interleaved, the pipeline automatically falls back to shell-wise correction.

5. **Gibbs ringing correction**
   - Uses the appropriate Gibbs-ringing correction according to acquisition dimensionality.

6. **TOPUP**
   - Estimates susceptibility-induced distortions using the diffusion b0 and a separately acquired reverse phase-encoded 'blipdown' image.

7. **Eddy**
   - Corrects for eddy-current distortions, motion and outlier slices/volumes.
   - Eddy-rotated b-vectors are retained for subsequent model fitting.

8. **Optional repetition averaging**
   - Repeated measurements can either be retained individually or averaged after Eddy correction.

9. **DTI / DKI fitting**
   - DTI/DKI fitting is performed using user-selected b-value shells or the complete dataset.

10. **Optional additional models**
    - BedpostX
    - NODDI

---

# Supported and tested acquisitions

The pipeline is designed to support:

- mouse and rat diffusion MRI;
- in-vivo and ex-vivo acquisitions;
- Bruker diffusion acquisitions with complex reconstructed `2dseq` data;
- 2D and 3D acquisitions;
- single-shell and multi-shell diffusion MRI;
- shelled, partially interleaved and fully interleaved acquisition ordering;
- acquisitions containing multiple and single repetitions–may differ between shells;
- acquisitions with interspersed b0 volumes and not;
- acquisitions with different numbers of diffusion directions between shells;
- odd and even image matrix dimensions.

To date, the pipeline has only been thoroughly tested on invivo rat, and exvivo mouse acquisitions. Beta testing is ongoing and all new users should carefully QC all outputs.

## Repository structure

A typical installation looks like:

    RERE/
    ├── rodent_diffusion_pipeline.sh
    ├── rere_gui.py
    ├── Diffusion_MRI_Pipeline_QC_Guide.docx
    │
    └── bin/
        ├── NIFTI_NORDIC_steen.m
        ├── run_NORDIC_steen.m
        ├── read_2dseq.m
        ├── ronan_read_2dseq_all_acqs_function_inVivo.m
        ├── detect_b0s.sh
        ├── extract_bvecs_bvals.sh
        ├── file_generation.sh
        ├── b0_based_drift_correction.py
        ├── linear_shellwise_drift_correction.py
        ├── reorient_bvecs.sh
        ├── reorient_eddy_output.sh
        ├── combine_reps.sh
        ├── select_bvalue_shells.sh
        │
        └── configuration_files/
            └── TOPUP configuration files

The main pipeline and GUI automatically locate the accompanying `bin/` directory, so the repository can be installed in different locations without editing paths to individual pipeline scripts.

---

# Running the pipeline

The pipeline can be run using either:

- the **graphical user interface (recommended for most users)**, or
- the **command line**.

## Option 1 — GUI

    `cd path_to_downloaded_location`

Launch the GUI with:

    ./rere_gui.py

or:

    python rere_gui.py

The GUI allows you to select/validate the input data and configure preprocessing/model-fitting options without manually constructing the full command.

git clone https://git.fmrib.ox.ac.uk/preclinical-imaging/diffusion_preprocessing_pipeline.git
    cd diffusion_preprocessing_pipeline

# Running the mini test dataset

A small test dataset is included under:

    mini_test_dMRI_dataset/

This can be used to test that the pipeline runs successfully on your local system without requiring a complete experimental dataset. It should only take a few minutes to run to completion on a cluster.

To run, first, change into the downloaded pipeline directory:

```bash
cd /path/to/diffusion_preprocessing_pipeline
```

Copy and paste the following command:

```bash
./rodent_diffusion_pipeline.sh \
    --RAWDIR=./mini_test_dMRI_dataset \
    --BLIPDOWNFILE=./mini_test_dMRI_dataset/blipdown.nii \
    --SHELL_NAMES=b1k \
    --SHELL_FOLDER_NUMBERS=7 \
    --COMPLEX_RECON_FOLDER_NUMBERS=5 \
    --SPECIES=rat \
    --CONDITION=invivo \
    --OUTDIR=./test_processed \
    --DRIFT_METHOD=b0 \
    --COMBINE_REPS=FALSE \
    --DTIDKI_BVALS=ALL \
    --RUN_BEDPOSTX=FALSE \
    --RUN_NODDI=FALSE \
    --NODDI_DOT=FALSE
```

The processed test dataset will be written to:

```text
test_processed/
```

relative to the pipeline directory.

If the pipeline script is not executable after downloading the repository, run:

```bash
chmod +x rodent_diffusion_pipeline.sh
chmod +x bin/*.sh
```

and then repeat the test command.

> **Note:** This example assumes the required software environment is available. See [Software requirements](#software-requirements) before running the pipeline.

### Software requirements

The pipeline currently depends on the following software. You will need ALL of these to be installed and available on the path of the pipeline download.

- FSL
  - TOPUP
  - Eddy (`eddy_cuda`)
  - DTIFIT
  - BedpostX (optional)
- MRtrix3
- mrdegibbs / deGibbs3D
- MATLAB
- Python 3
  - NumPy
  - NiBabel
- NORDIC (included with the pipeline)

The versions used during pipeline development are:

- MRtrix3: 3.0.7
- mrdegibbs: 20210623-GCC-12.3
- MATLAB: 2024a
- FSL: fsl/6.0.7.23
- Python: 3.12.1

Other versions may work but have not necessarily been validated.

### Other systems

The pipeline is currently developed and tested on the FMRIB HPC environment.

Running the pipeline on another Linux/HPC system requires the above
dependencies to be installed and available on the PATH. Cluster job
submission currently also assumes the FMRIB `fsl_sub` environment.

A portable containerised distribution is planned for future releases.

### Recommended GUI workflow

1. Select the raw Bruker data directory.
2. Select an output directory.
3. Select the reverse phase-encoded (`blip-down`) image.
4. Enter the shell names.
5. Enter the corresponding Bruker shell folder numbers.
6. Enter the corresponding complex reconstruction folder numbers.
7. Select the species and acquisition condition.
8. Select any optional preprocessing/model-fitting settings.
9. Click **Validate**.
10. Correct any reported input errors.
11. Click **Run pipeline**.

The **Command preview** at the bottom of the GUI shows the equivalent command-line invocation.

### Copy command

The **Copy command** button copies the complete pipeline command to the clipboard.

This is particularly useful when processing several datasets with the same acquisition structure. Configure one dataset in the GUI, copy the command, and modify only the subject/session-specific paths for subsequent datasets.

---

## Option 2 — Command line

The pipeline can also be run directly:

    ./rodent_diffusion_pipeline.sh \
        --RAWDIR=/path/to/bruker/data \
        --BLIPDOWNFILE=/path/to/blipdown.nii.gz \
        --SHELL_NAMES=b500,b1000,b2000 \
        --SHELL_FOLDER_NUMBERS=5,6,7 \
        --COMPLEX_RECON_FOLDER_NUMBERS=2,2,2 \
        --SPECIES=mouse \
        --CONDITION=invivo \
        --OUTDIR=/path/to/output

For the complete list of options:

    ./rodent_diffusion_pipeline.sh --help

The GUI also contains additional help information describing the major inputs and processing options.

---

# Main inputs

### Raw data directory

The directory containing the Bruker acquisition folders.

For example:

    RAWDIR/
    ├── 5/
    ├── 6/
    ├── 7/
    └── ...

### Shell names

User-defined descriptive names for each diffusion acquisition.

For example:

    --SHELL_NAMES=b500,b1000,b2000

### Shell folder numbers

The corresponding Bruker acquisition folders:

    --SHELL_FOLDER_NUMBERS=5,6,7

**Order is important.** Shell names, shell folder numbers and complex reconstruction folder numbers must describe the same acquisitions in the same order.

### Complex reconstruction folder numbers

The `pdata` reconstruction containing the complex `2dseq` data for each acquisition.

For example:

    --COMPLEX_RECON_FOLDER_NUMBERS=2,2,2

### Blip-down image

A separately reconstructed reverse phase-encoded image used with TOPUP.

### Species

Currently:

    mouse
    rat

### Condition

Currently:

    invivo
    exvivo

These options are used when selecting acquisition-specific processing parameters.

---

# Important processing options

## Signal drift correction

Default:

    --DRIFT_METHOD=b0

### `b0`

Uses interleaved b0 measurements to estimate global signal changes throughout the acquisition.

If the b0 volumes are not sufficiently interleaved, the pipeline automatically falls back to shell-wise correction.

### `shell`

Performs voxel-wise linear detrending independently within each b-value shell.

This can be selected explicitly with:

    --DRIFT_METHOD=shell

---

## Repetition handling

Default:

    --COMBINE_REPS=FALSE

With `FALSE`, individual acquisition repetitions are retained for model fitting.

With:

    --COMBINE_REPS=TRUE

corresponding measurements are averaged after Eddy correction.

---

## DTI / DKI b-values

Default:

    --DTIDKI_BVALS=ALL

Specific shells can instead be selected:

    --DTIDKI_BVALS=0,1000,2000

The pipeline matches requested values to the acquired b-values using its defined b-value tolerance.

---

## BedpostX

BedpostX is disabled by default:

    --RUN_BEDPOSTX=FALSE

Enable with:

    --RUN_BEDPOSTX=TRUE

The b-values used for BedpostX can be controlled separately:

    --BEDPOSTX_BVALS=ALL

---

## NODDI

NODDI is disabled by default:

    --RUN_NODDI=FALSE

When enabled, its input shells can be selected independently:

    --NODDI_BVALS=ALL

An optional dot compartment can also be requested:

    --NODDI_DOT=TRUE

> NODDI support is currently under development. Check the current pipeline implementation before relying on this option for production processing.

---

# TOPUP configuration

The pipeline automatically selects a TOPUP configuration according to:

- species;
- in-vivo/ex-vivo acquisition;
- odd/even image dimensions.

Configuration files are provided under:

    bin/configuration_files/

Experienced users can override this using:

    --TOPUPCNF=/path/to/custom.cnf

Most users should leave this unset.

---

# Eddy index

An Eddy `index.txt` file is generated automatically for the standard acquisition structure.

A custom file can be supplied with:

    --INDEXTXT=/path/to/index.txt

This should only normally be required for acquisitions with a non-standard phase-encoding structure.

---

# Quality control

**All datasets should undergo QC after processing.**

Please follow:

    Diffusion_MRI_Pipeline_QC_Guide.docx

The QC guide describes:

- what outputs should be inspected;
- how to inspect them in FSLeyes;
- expected appearances;
- common failure modes;
- NORDIC QC;
- b0 and signal-drift QC;
- Gibbs-ringing QC;
- TOPUP QC;
- Eddy QC;
- b-value/b-vector QC;
- V1/gradient-orientation QC;
- DTI/DKI QC;
- model-fitting QC.

A pipeline completing without an error does **not** guarantee that the resulting diffusion data are valid.

Particular attention should be paid to gradient orientation and the anatomical plausibility of the fitted V1 directions.

---

# Tips for use

### Validate before running

When using the GUI, use **Validate** before starting the pipeline.

Validation checks the supplied paths and acquisition structure and can catch common input mistakes before computationally expensive processing begins.

The command-line pipeline also performs its own validation and will terminate when required inputs are inconsistent.

### Check shell ordering carefully

The following inputs are paired by position:

    SHELL_NAMES
    SHELL_FOLDER_NUMBERS
    COMPLEX_RECON_FOLDER_NUMBERS

For example:

    SHELL_NAMES=b500,b1000,b2000
    SHELL_FOLDER_NUMBERS=5,12,8
    COMPLEX_RECON_FOLDER_NUMBERS=2,4,2

means:

    b500  -> acquisition 5  -> pdata/2
    b1000 -> acquisition 12 -> pdata/4
    b2000 -> acquisition 8  -> pdata/2

Do not reorder the folder numbers numerically.

### Processing multiple similar datasets

If several animals/sessions use the same acquisition structure:

1. Configure and validate the first dataset in the GUI.
2. Use **Copy command**.
3. Paste the command into a terminal/script.
4. Modify the subject/session-specific input and output paths.

This reduces repeated manual entry and helps keep processing parameters consistent across a study.

### Read the logs

Pipeline logs are written under:

    OUTDIR/logs/

If processing fails, inspect the relevant log before rerunning.

### Use the help

Command-line help:

    ./rodent_diffusion_pipeline.sh --help

Additional descriptions of the major options are available from the GUI **Help** menu.

---

# Current assumptions and parameter choices

The pipeline intentionally makes several processing choices so that datasets can be processed consistently.

Current choices include:

- complex NORDIC denoising;
- b0-based signal drift correction by default;
- automatic fallback to shell-wise drift correction when b0 spacing is unsuitable;
- TOPUP requires a reverse phase-encoded 'blipdown' nifti image;
- automatically selected TOPUP configuration according to acquisition type, this can be overwritten for customisable purposes.

Some temporary hard-coded image/b-vector reorientations are currently present while support for deriving these directly from Bruker geometry is developed.

Users applying the pipeline to a substantially different acquisition protocol should therefore verify all assumptions carefully and perform thorough QC.

---

# Software requirements

The pipeline currently uses software including:

- FSL
- MRtrix3
- MATLAB
- Python

The pipeline was developed for the FMRIB HPC environment, where the required software is loaded using environment modules.

Users running the pipeline elsewhere may need to modify the software-loading commands while retaining the same software dependencies.

---

# Reporting problems / requesting help

If you encounter a problem:

1. Check the QC guide.
2. Check the relevant file under `OUTDIR/logs/`.
3. Run the pipeline/GUI validation again and confirm the input acquisition structure.
4. Record the exact command used to run the pipeline.
5. Record the error message and relevant log output.

For bugs or feature requests, please open an issue in this repository and include:

- a short description of the problem;
- the pipeline command used;
- the relevant error/log output;
- the acquisition type where relevant;
- the pipeline version/commit used.

For questions requiring direct assistance, contact:

**Ronan McNeill**  
[ronan.mcneill@ndcn.ox.ac.uk]

Please do not upload identifiable or sensitive imaging data to a public issue.

---

# Development status

The pipeline is under active development, it is somewhat expected that new users with very different acquisitions may run into bugs. We actively welcome initial users to provide feedback and are happy to collaborate wherever possible.

When updating the pipeline, users are encouraged to record the Git commit used for each study to maintain reproducibility.

To see the current version:

    git rev-parse HEAD