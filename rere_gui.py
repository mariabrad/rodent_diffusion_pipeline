#!/usr/bin/env python3

import os
import shlex
import subprocess
import tkinter as tk
from tkinter import filedialog, messagebox, ttk


# ============================================================================
# CONFIGURATION
# ============================================================================

# The GUI and parent pipeline are stored in the same directory.
GUI_DIR = os.path.dirname(os.path.abspath(__file__))

DEFAULT_PIPELINE = os.path.join(
    GUI_DIR,
    "rodent_diffusion_pipeline.sh"
)


# ============================================================================
# GUI
# ============================================================================

class REREGui(tk.Tk):

    def __init__(self):
        super().__init__()

        self.title("RERE diffusion MRI pipeline")

        # Smaller window; main contents are scrollable.
        self.geometry("750x700")
        self.minsize(650, 500)

        self.create_variables()
        self.create_menu()
        self.create_widgets()

        self.update_model_controls()
        self.update_command_preview()


    # ========================================================================
    # Variables
    # ========================================================================

    def create_variables(self):

        # Pipeline
        self.pipeline = tk.StringVar(value=DEFAULT_PIPELINE)

        # Input / output
        self.rawdir = tk.StringVar()
        self.outdir = tk.StringVar()
        self.blipdown = tk.StringVar()

        # Acquisition
        self.shell_names = tk.StringVar()
        self.shell_folders = tk.StringVar()
        self.complex_folders = tk.StringVar()

        self.species = tk.StringVar(value="mouse")
        self.condition = tk.StringVar(value="exvivo")

        # Preprocessing
        self.drift_method = tk.StringVar(value="b0")
        self.combine_reps = tk.BooleanVar(value=False)

        # Advanced
        self.topupcnf = tk.StringVar()
        self.indextxt = tk.StringVar()
        self.show_advanced = tk.BooleanVar(value=False)

        # DTI / DKI
        self.dtidki_bvals = tk.StringVar(value="ALL")

        # BedpostX
        self.run_bedpostx = tk.BooleanVar(value=False)
        self.bedpostx_bvals = tk.StringVar(value="ALL")

        # NODDI
        self.run_noddi = tk.BooleanVar(value=False)
        self.noddi_bvals = tk.StringVar(value="ALL")
        self.noddi_dot = tk.BooleanVar(value=False)

        # Automatically refresh command preview whenever something changes.
        variables = [
            self.pipeline,
            self.rawdir,
            self.outdir,
            self.blipdown,
            self.shell_names,
            self.shell_folders,
            self.complex_folders,
            self.species,
            self.condition,
            self.drift_method,
            self.combine_reps,
            self.topupcnf,
            self.indextxt,
            self.dtidki_bvals,
            self.run_bedpostx,
            self.bedpostx_bvals,
            self.run_noddi,
            self.noddi_bvals,
            self.noddi_dot,
        ]

        for variable in variables:
            variable.trace_add(
                "write",
                lambda *_: self.update_command_preview()
            )

    def choose_blipdown(self):

        rawdir = self.rawdir.get().strip()

        # Start inside RAWDIR if it has already been selected
        if rawdir and os.path.isdir(rawdir):
            initial_dir = rawdir
        else:
            initial_dir = None

        path = filedialog.askopenfilename(
            title="Select blip-down image",
            initialdir=initial_dir,
            filetypes=[
                ("NIfTI files", "*.nii *.nii.gz"),
                ("All files", "*")
            ]
        )

        if path:
            self.blipdown.set(path)

    # ========================================================================
    # Help menu
    # ========================================================================

    def create_menu(self):

        menubar = tk.Menu(self)

        help_menu = tk.Menu(menubar, tearoff=0)

        help_menu.add_command(
            label="Pipeline overview",
            command=lambda: self.show_help(
                "Pipeline overview",
                """
RERE diffusion MRI preprocessing pipeline

The pipeline performs:

1. 2dseq to NIFTI reconstruction
2. NORDIC complex denoising
3. Drift correction
4. Gibbs ringing correction
5. TOPUP susceptibility correction
6. Eddy correction
7. Optional repetition averaging
8. DTI/DKI fitting
9. Optional BedpostX fitting
10. Optional NODDI fitting

Most users should only need to specify their input data,
acquisition information, preprocessing choices, and desired
model fitting.
"""
            )
        )

        help_menu.add_separator()

        help_menu.add_command(
            label="Input data",
            command=lambda: self.show_help(
                "Input data",
                """
Raw data directory

Directory containing the Bruker acquisition folders.


Output directory

Directory where preprocessing and model-fitting results
will be written.


Blip-down image

Reverse phase-encoded image (not the directory)
 used with TOPUP for susceptibility distortion correction.


Shell names

Comma-separated descriptive names for the diffusion shells.

Example:

    b1000,b2000,b3000


Shell folder numbers

Bruker acquisition folder numbers corresponding to
each shell.

Example:

    12,13,14


Complex recon folders

Reconstruction folder numbers containing the complex
reconstruction (2dseq) for each diffusion shell.

Example:

    2,2,2
"""
            )
        )

        help_menu.add_command(
            label="Species and condition",
            command=lambda: self.show_help(
                "Species and condition",
                """
Species

Select mouse or rat.


Condition

Select whether the acquisition was performed in vivo
or ex vivo.

These settings are used by pipeline components that
require species- or acquisition-specific parameters.
"""
            )
        )

        help_menu.add_separator()

        help_menu.add_command(
            label="Drift correction",
            command=lambda: self.show_help(
                "Drift correction",
                """
Signal drift correction compensates for gradual 
changes in MRI signal intensity over the course
of the diffusion acquisition.

b0-based correction (default)

Uses the signal measured in interleaved b0 volumes
to estimate how the global signal changes over time.
The estimated drift is then used to correct the 
complete diffusion series.

This approach is most appropriate when b0 volumes are 
distributed regularly throughout the acquisition, so 
that signal drift can be estimated across the full scan.

The pipeline automatically checks the spacing of the 
b0 volumes. If they are not sufficiently interleaved, 
it falls back to shell-wise correction.


Shell-wise correction

Performs voxel-wise linear detrending separately 
within each b-value shell.

This method does not rely on regularly interleaved 
b0 volumes and is therefore useful when the acquisition 
contains too few b0 volumes, or when the b0 volumes are 
not sufficiently distributed throughout the scan.

It can also be selected manually using the "shell" option.
"""
            )
        )

        help_menu.add_command(
            label="Combine repetitions",
            command=lambda: self.show_help(
                "Combine repetitions",
                """
FALSE (default)

All acquisition repetitions are retained for model fitting.


TRUE

Corresponding measurements from repeated acquisitions
are averaged after Eddy correction to boost SNR.

The corresponding Eddy-rotated b-vectors are also combined
to produce the gradient table for the averaged dataset.
"""
            )
        )

        help_menu.add_separator()

        help_menu.add_command(
            label="DTI / DKI",
            command=lambda: self.show_help(
                "DTI / DKI",
                """
DTI/DKI b-values control which b-value shells are used
for DTI/DKI fitting.

ALL

    Use all available shells.

Alternatively, provide comma-separated b-values.

Example:

    0,1000,2000

Requested shells are matched to acquired b-values using
the tolerance defined by the pipeline.
"""
            )
        )

        help_menu.add_command(
            label="BedpostX",
            command=lambda: self.show_help(
                "BedpostX",
                """
Run BedpostX

Unchecked (default)

    BedpostX is not run.

Checked

    BedpostX is submitted after preprocessing.


BedpostX b-values

ALL

    Use all available shells.

Alternatively specify particular shells.

Example:

    0,1000,2000
"""
            )
        )

        help_menu.add_command(
            label="NODDI",
            command=lambda: self.show_help(
                "NODDI",
                """
Run NODDI

Unchecked (default)

    NODDI is not run.

Checked

    NODDI fitting is submitted after preprocessing.


NODDI b-values

ALL

    Use all available shells.

Alternatively specify particular shells.

Example:

    0,1000,2000


Dot compartment

Enables the optional dot compartment in the NODDI model.

This is a modelling choice and is not automatically
determined from the in-vivo/ex-vivo setting.
However, general applications may choose to add a 
dot compartment in ex-vivo but not in-vivo.
"""
            )
        )

        help_menu.add_separator()

        help_menu.add_command(
            label="Advanced options",
            command=lambda: self.show_help(
                "Advanced options",
                """
Custom TOPUP configuration

Optional.

Allows an experienced user to override the TOPUP
configuration automatically selected by the pipeline.

Most users should leave this empty as the pipeline 
draws from optimised configuration files for 
each use case (exvivo/invivo; mouse/rat).


Custom Eddy index file

Optional.

Allows an experienced user to provide a custom
Eddy index.txt file.

The index file specifies which acquisition-parameter
row applies to each diffusion volume.

The pipeline assumes all volumes use the first PE line
 (1 = blip-up). For alternating or custom PE groups
 (e.g., AP/PA), please provide a custom index.txt
"""
            )
        )

        help_menu.add_separator()

        help_menu.add_command(
            label="Show command-line help",
            command=self.show_cli_help
        )

        menubar.add_cascade(
            label="Help",
            menu=help_menu
        )

        self.config(menu=menubar)


    # ========================================================================
    # Main layout
    # ========================================================================

    def create_widgets(self):

        # --------------------------------------------------------------------
        # Scrollable main window
        # --------------------------------------------------------------------

        outer_frame = ttk.Frame(self)
        outer_frame.pack(fill="both", expand=True)

        canvas = tk.Canvas(
            outer_frame,
            highlightthickness=0
        )
        canvas.pack(
            side="left",
            fill="both",
            expand=True
        )

        scrollbar = ttk.Scrollbar(
            outer_frame,
            orient="vertical",
            command=canvas.yview
        )
        scrollbar.pack(
            side="right",
            fill="y"
        )

        canvas.configure(
            yscrollcommand=scrollbar.set
        )

        container = ttk.Frame(
            canvas,
            padding=8
        )

        canvas_window = canvas.create_window(
            (0, 0),
            window=container,
            anchor="nw"
        )

        # Update scrolling region when contents change.
        container.bind(
            "<Configure>",
            lambda event: canvas.configure(
                scrollregion=canvas.bbox("all")
            )
        )

        # Make contents fill width of canvas.
        canvas.bind(
            "<Configure>",
            lambda event: canvas.itemconfigure(
                canvas_window,
                width=event.width
            )
        )

        # Mouse-wheel scrolling.
        def on_mousewheel(event):

            if event.delta:
                canvas.yview_scroll(
                    int(-1 * (event.delta / 120)),
                    "units"
                )

        canvas.bind_all(
            "<MouseWheel>",
            on_mousewheel
        )

        # Linux mouse-wheel support.
        canvas.bind_all(
            "<Button-4>",
            lambda event: canvas.yview_scroll(-1, "units")
        )

        canvas.bind_all(
            "<Button-5>",
            lambda event: canvas.yview_scroll(1, "units")
        )

        # --------------------------------------------------------------------
        # Pipeline
        # --------------------------------------------------------------------

        pipeline_frame = ttk.LabelFrame(
            container,
            text="Pipeline",
            padding=6
        )
        pipeline_frame.pack(
            fill="x",
            pady=(0, 5)
        )

        self.add_file_row(
            pipeline_frame,
            0,
            "Pipeline script",
            self.pipeline,
            filetypes=[
                ("Shell scripts", "*.sh"),
                ("All files", "*")
            ]
        )

        # --------------------------------------------------------------------
        # Input / output
        # --------------------------------------------------------------------

        io_frame = ttk.LabelFrame(
            container,
            text="Input / Output",
            padding=6
        )
        io_frame.pack(
            fill="x",
            pady=(0, 5)
        )

        self.add_directory_row(
            io_frame,
            0,
            "Raw data directory",
            self.rawdir
        )

        self.add_directory_row(
            io_frame,
            1,
            "Output directory",
            self.outdir
        )

        ttk.Label(
            io_frame,
            text="Blip-down image"
        ).grid(
            row=2,
            column=0,
            sticky="w",
            pady=3
        )

        ttk.Entry(
            io_frame,
            textvariable=self.blipdown
        ).grid(
            row=2,
            column=1,
            sticky="ew",
            padx=(8, 5),
            pady=3
        )

        ttk.Button(
            io_frame,
            text="Browse",
            command=self.choose_blipdown
        ).grid(
            row=2,
            column=2,
            pady=3
        )

        # --------------------------------------------------------------------
        # Acquisition
        # --------------------------------------------------------------------

        acquisition_frame = ttk.LabelFrame(
            container,
            text="Acquisition",
            padding=6
        )
        acquisition_frame.pack(
            fill="x",
            pady=(0, 5)
        )

        self.add_entry_row(
            acquisition_frame,
            0,
            "Shell names",
            self.shell_names
        )

        self.add_entry_row(
            acquisition_frame,
            1,
            "Shell folder numbers",
            self.shell_folders
        )

        self.add_entry_row(
            acquisition_frame,
            2,
            "Complex recon folders",
            self.complex_folders
        )

        ttk.Label(
            acquisition_frame,
            text="Species"
        ).grid(
            row=3,
            column=0,
            sticky="w",
            pady=3
        )

        species_frame = ttk.Frame(acquisition_frame)
        species_frame.grid(
            row=3,
            column=1,
            sticky="w"
        )

        ttk.Radiobutton(
            species_frame,
            text="Mouse",
            variable=self.species,
            value="mouse"
        ).pack(
            side="left",
            padx=(0, 15)
        )

        ttk.Radiobutton(
            species_frame,
            text="Rat",
            variable=self.species,
            value="rat"
        ).pack(side="left")

        ttk.Label(
            acquisition_frame,
            text="Condition"
        ).grid(
            row=4,
            column=0,
            sticky="w",
            pady=3
        )

        condition_frame = ttk.Frame(acquisition_frame)
        condition_frame.grid(
            row=4,
            column=1,
            sticky="w"
        )

        ttk.Radiobutton(
            condition_frame,
            text="In vivo",
            variable=self.condition,
            value="invivo"
        ).pack(
            side="left",
            padx=(0, 15)
        )

        ttk.Radiobutton(
            condition_frame,
            text="Ex vivo",
            variable=self.condition,
            value="exvivo"
        ).pack(side="left")

        acquisition_frame.columnconfigure(
            1,
            weight=1
        )

        # --------------------------------------------------------------------
        # Preprocessing
        # --------------------------------------------------------------------

        preprocessing_frame = ttk.LabelFrame(
            container,
            text="Preprocessing",
            padding=6
        )
        preprocessing_frame.pack(
            fill="x",
            pady=(0, 5)
        )

        ttk.Label(
            preprocessing_frame,
            text="Drift correction"
        ).grid(
            row=0,
            column=0,
            sticky="w",
            pady=3
        )

        drift_box = ttk.Combobox(
            preprocessing_frame,
            textvariable=self.drift_method,
            values=["b0", "shell"],
            state="readonly",
            width=15
        )
        drift_box.grid(
            row=0,
            column=1,
            sticky="w",
            pady=3
        )

        ttk.Checkbutton(
            preprocessing_frame,
            text="Combine repetitions",
            variable=self.combine_reps
        ).grid(
            row=1,
            column=0,
            columnspan=2,
            sticky="w",
            pady=3
        )

        preprocessing_frame.columnconfigure(
            1,
            weight=1
        )

        # --------------------------------------------------------------------
        # Advanced options
        # --------------------------------------------------------------------

        advanced_header = ttk.Frame(container)
        advanced_header.pack(
            fill="x",
            pady=(0, 5)
        )

        self.advanced_button = ttk.Button(
            advanced_header,
            text="▶ Advanced options",
            command=self.toggle_advanced
        )
        self.advanced_button.pack(
            side="left"
        )

        self.advanced_frame = ttk.LabelFrame(
            container,
            text="Advanced options",
            padding=6
        )

        self.add_file_row(
            self.advanced_frame,
            0,
            "Custom TOPUP config",
            self.topupcnf,
            filetypes=[
                ("TOPUP config", "*.cnf"),
                ("All files", "*")
            ]
        )

        self.add_file_row(
            self.advanced_frame,
            1,
            "Custom Eddy index",
            self.indextxt,
            filetypes=[
                ("Text files", "*.txt"),
                ("All files", "*")
            ]
        )

        ttk.Label(
            self.advanced_frame,
            text="Most users should leave these options empty."
        ).grid(
            row=2,
            column=0,
            columnspan=3,
            sticky="w",
            pady=(5, 0)
        )

        # --------------------------------------------------------------------
        # Model fitting
        # --------------------------------------------------------------------

        self.fitting_frame = ttk.LabelFrame(
            container,
            text="Model fitting",
            padding=6
        )
        self.fitting_frame.pack(
            fill="x",
            pady=(0, 5)
        )

        ttk.Label(
            self.fitting_frame,
            text="DTI / DKI b-values"
        ).grid(
            row=0,
            column=0,
            sticky="w",
            pady=3
        )

        ttk.Entry(
            self.fitting_frame,
            textvariable=self.dtidki_bvals
        ).grid(
            row=0,
            column=1,
            sticky="ew",
            pady=3
        )

        ttk.Checkbutton(
            self.fitting_frame,
            text="Run BedpostX",
            variable=self.run_bedpostx,
            command=self.update_model_controls
        ).grid(
            row=1,
            column=0,
            sticky="w",
            pady=(7, 3)
        )

        ttk.Label(
            self.fitting_frame,
            text="BedpostX b-values"
        ).grid(
            row=2,
            column=0,
            sticky="w",
            pady=3
        )

        self.bedpostx_entry = ttk.Entry(
            self.fitting_frame,
            textvariable=self.bedpostx_bvals
        )
        self.bedpostx_entry.grid(
            row=2,
            column=1,
            sticky="ew",
            pady=3
        )

        ttk.Checkbutton(
            self.fitting_frame,
            text="Run NODDI",
            variable=self.run_noddi,
            command=self.update_model_controls
        ).grid(
            row=3,
            column=0,
            sticky="w",
            pady=(7, 3)
        )

        ttk.Label(
            self.fitting_frame,
            text="NODDI b-values"
        ).grid(
            row=4,
            column=0,
            sticky="w",
            pady=3
        )

        self.noddi_bvals_entry = ttk.Entry(
            self.fitting_frame,
            textvariable=self.noddi_bvals
        )
        self.noddi_bvals_entry.grid(
            row=4,
            column=1,
            sticky="ew",
            pady=3
        )

        self.noddi_dot_checkbox = ttk.Checkbutton(
            self.fitting_frame,
            text="Include NODDI dot compartment",
            variable=self.noddi_dot
        )
        self.noddi_dot_checkbox.grid(
            row=5,
            column=0,
            columnspan=2,
            sticky="w",
            pady=3
        )

        self.fitting_frame.columnconfigure(
            1,
            weight=1
        )

        # --------------------------------------------------------------------
        # Command preview
        # --------------------------------------------------------------------

        command_frame = ttk.LabelFrame(
            container,
            text="Command preview",
            padding=6
        )
        command_frame.pack(
            fill="both",
            expand=True,
            pady=(0, 5)
        )

        self.command_text = tk.Text(
            command_frame,
            height=5,
            wrap="word"
        )
        self.command_text.pack(
            fill="both",
            expand=True
        )

        # --------------------------------------------------------------------
        # Buttons
        # --------------------------------------------------------------------

        button_frame = ttk.Frame(container)
        button_frame.pack(
            fill="x",
            pady=(0, 5)
        )

        ttk.Button(
            button_frame,
            text="Copy command",
            command=self.copy_command
        ).pack(
            side="left"
        )

        ttk.Button(
            button_frame,
            text="Validate",
            command=self.validate_inputs
        ).pack(
            side="left",
            padx=8
        )

        ttk.Button(
            button_frame,
            text="Run pipeline",
            command=self.run_pipeline
        ).pack(
            side="right"
        )


    # ========================================================================
    # Layout helpers
    # ========================================================================

    def add_entry_row(self, frame, row, label, variable):

        ttk.Label(
            frame,
            text=label
        ).grid(
            row=row,
            column=0,
            sticky="w",
            pady=3
        )

        entry = ttk.Entry(
            frame,
            textvariable=variable
        )

        entry.grid(
            row=row,
            column=1,
            sticky="ew",
            padx=(8, 5),
            pady=3
        )

        frame.columnconfigure(
            1,
            weight=1
        )


    def add_directory_row(self, frame, row, label, variable):

        ttk.Label(
            frame,
            text=label
        ).grid(
            row=row,
            column=0,
            sticky="w",
            pady=3
        )

        entry = ttk.Entry(
            frame,
            textvariable=variable
        )

        entry.grid(
            row=row,
            column=1,
            sticky="ew",
            padx=(8, 5),
            pady=3
        )

        ttk.Button(
            frame,
            text="Browse",
            command=lambda: self.choose_directory(variable)
        ).grid(
            row=row,
            column=2,
            pady=3
        )

        frame.columnconfigure(
            1,
            weight=1
        )


    def add_file_row(
        self,
        frame,
        row,
        label,
        variable,
        filetypes=None
    ):

        ttk.Label(
            frame,
            text=label
        ).grid(
            row=row,
            column=0,
            sticky="w",
            pady=3
        )

        entry = ttk.Entry(
            frame,
            textvariable=variable
        )

        entry.grid(
            row=row,
            column=1,
            sticky="ew",
            padx=(8, 5),
            pady=3
        )

        ttk.Button(
            frame,
            text="Browse",
            command=lambda: self.choose_file(
                variable,
                filetypes
            )
        ).grid(
            row=row,
            column=2,
            pady=3
        )

        frame.columnconfigure(
            1,
            weight=1
        )


    # ========================================================================
    # File selection
    # ========================================================================

    def choose_directory(self, variable):

        path = filedialog.askdirectory()

        if path:
            variable.set(path)


    def choose_file(self, variable, filetypes=None):

        path = filedialog.askopenfilename(
            filetypes=filetypes or [
                ("All files", "*")
            ]
        )

        if path:
            variable.set(path)


    # ========================================================================
    # Advanced options
    # ========================================================================

    def toggle_advanced(self):

        if self.show_advanced.get():

            self.show_advanced.set(False)

            self.advanced_frame.pack_forget()

            self.advanced_button.configure(
                text="▶ Advanced options"
            )

        else:

            self.show_advanced.set(True)

            self.advanced_frame.pack(
                fill="x",
                pady=(0, 5),
                before=self.fitting_frame
            )

            self.advanced_button.configure(
                text="▼ Advanced options"
            )


    # ========================================================================
    # Model controls
    # ========================================================================

    def update_model_controls(self):

        if hasattr(self, "bedpostx_entry"):

            if self.run_bedpostx.get():
                self.bedpostx_entry.configure(
                    state="normal"
                )
            else:
                self.bedpostx_entry.configure(
                    state="disabled"
                )

        if hasattr(self, "noddi_bvals_entry"):

            if self.run_noddi.get():

                self.noddi_bvals_entry.configure(
                    state="normal"
                )

                self.noddi_dot_checkbox.configure(
                    state="normal"
                )

            else:

                self.noddi_bvals_entry.configure(
                    state="disabled"
                )

                self.noddi_dot_checkbox.configure(
                    state="disabled"
                )

                self.noddi_dot.set(False)

        self.update_command_preview()


    # ========================================================================
    # Construct command
    # ========================================================================

    def build_command(self):

        command = [
            self.pipeline.get(),

            f"--RAWDIR={self.rawdir.get()}",
            f"--BLIPDOWNFILE={self.blipdown.get()}",
            f"--SHELL_NAMES={self.shell_names.get()}",
            f"--SHELL_FOLDER_NUMBERS={self.shell_folders.get()}",
            f"--COMPLEX_RECON_FOLDER_NUMBERS={self.complex_folders.get()}",
            f"--SPECIES={self.species.get()}",
            f"--CONDITION={self.condition.get()}",
            f"--OUTDIR={self.outdir.get()}",

            f"--DRIFT_METHOD={self.drift_method.get()}",

            "--COMBINE_REPS="
            + (
                "TRUE"
                if self.combine_reps.get()
                else "FALSE"
            ),

            f"--DTIDKI_BVALS={self.dtidki_bvals.get()}",

            "--RUN_BEDPOSTX="
            + (
                "TRUE"
                if self.run_bedpostx.get()
                else "FALSE"
            ),

            "--RUN_NODDI="
            + (
                "TRUE"
                if self.run_noddi.get()
                else "FALSE"
            ),

            "--NODDI_DOT="
            + (
                "TRUE"
                if self.noddi_dot.get()
                else "FALSE"
            ),
        ]

        if self.run_bedpostx.get():

            command.append(
                f"--BEDPOSTX_BVALS={self.bedpostx_bvals.get()}"
            )

        if self.run_noddi.get():

            command.append(
                f"--NODDI_BVALS={self.noddi_bvals.get()}"
            )

        if self.topupcnf.get().strip():

            command.append(
                f"--TOPUPCNF={self.topupcnf.get()}"
            )

        if self.indextxt.get().strip():

            command.append(
                f"--INDEXTXT={self.indextxt.get()}"
            )

        return command


    # ========================================================================
    # Command preview
    # ========================================================================

    def command_as_text(self):

        command = self.build_command()

        return " \\\n    ".join(
            shlex.quote(argument)
            for argument in command
        )


    def update_command_preview(self):

        if not hasattr(self, "command_text"):
            return

        self.command_text.configure(
            state="normal"
        )

        self.command_text.delete(
            "1.0",
            tk.END
        )

        self.command_text.insert(
            "1.0",
            self.command_as_text()
        )

        self.command_text.configure(
            state="disabled"
        )


    def copy_command(self):

        command = self.command_as_text()

        try:
            self.clipboard_clear()
            self.clipboard_append(command)

            # Force Tk to publish the complete clipboard contents
            self.update()

            messagebox.showinfo(
                "Command copied",
                "Full pipeline command copied to clipboard."
            )

        except tk.TclError as error:
            messagebox.showerror(
                "Copy failed",
                f"Could not copy command to clipboard:\n{error}"
            )


    # ========================================================================
    # Validation
    # ========================================================================

    def validate_inputs(self, show_success=True):

        errors = []
        warnings = []

        # =====================================================================
        # Helpers
        # =====================================================================

        def csv_items(value):
            """Normalise comma-separated GUI input."""
            value = value.strip()
            value = value.strip("[]{}")
            value = value.replace("'", "").replace('"', "")

            return [
                item.strip()
                for item in value.split(",")
                if item.strip()
            ]

        def valid_bvals(value):
            """ALL or comma-separated non-negative numbers."""
            import re

            value = value.strip()

            if value.upper() == "ALL":
                return True

            return bool(
                re.fullmatch(
                    r"[0-9]+(?:\.[0-9]+)?"
                    r"(?:,[0-9]+(?:\.[0-9]+)?)*",
                    value
                )
            )

        # =====================================================================
        # Pipeline
        # =====================================================================

        pipeline = self.pipeline.get().strip()

        if not pipeline:
            errors.append("Pipeline script is required.")

        elif not os.path.isfile(pipeline):
            errors.append(
                f"Pipeline script does not exist:\n{pipeline}"
            )

        elif not os.access(pipeline, os.X_OK):
            errors.append(
                f"Pipeline script is not executable:\n{pipeline}"
            )

        # =====================================================================
        # Main paths
        # =====================================================================

        rawdir = self.rawdir.get().strip()
        outdir = self.outdir.get().strip()
        blipdown = self.blipdown.get().strip()

        if not rawdir:
            errors.append("Raw data directory is required.")

        elif not os.path.isdir(rawdir):
            errors.append(
                f"Raw data directory does not exist:\n{rawdir}"
            )

        if not outdir:
            errors.append("Output directory is required.")

        else:
            parent = os.path.dirname(
                os.path.abspath(outdir)
            ) or "."

            if os.path.exists(outdir):

                if not os.path.isdir(outdir):
                    errors.append(
                        f"Output path exists but is not a directory:\n{outdir}"
                    )

                elif not os.access(outdir, os.W_OK):
                    errors.append(
                        f"Output directory is not writable:\n{outdir}"
                    )

                elif os.listdir(outdir):
                    warnings.append(
                        "Output directory already exists and is not empty:\n"
                        f"{outdir}"
                    )

            elif not os.path.isdir(parent):
                errors.append(
                    "Parent directory for the output does not exist:\n"
                    f"{parent}"
                )

            elif not os.access(parent, os.W_OK):
                errors.append(
                    "Cannot create output directory because its parent "
                    f"is not writable:\n{parent}"
                )

        if not blipdown:
            errors.append("Blip-down image is required.")

        elif not os.path.isfile(blipdown):
            errors.append(
                f"Blip-down image does not exist:\n{blipdown}"
            )

        elif not (
            blipdown.endswith(".nii")
            or blipdown.endswith(".nii.gz")
        ):
            warnings.append(
                "Blip-down image does not have a .nii or .nii.gz extension:\n"
                f"{blipdown}"
            )

        # =====================================================================
        # Acquisition lists
        # =====================================================================

        shell_names = csv_items(
            self.shell_names.get()
        )

        shell_folders = csv_items(
            self.shell_folders.get()
        )

        complex_folders = csv_items(
            self.complex_folders.get()
        )

        if not shell_names:
            errors.append("At least one shell name is required.")

        if not shell_folders:
            errors.append(
                "At least one shell folder number is required."
            )

        if not complex_folders:
            errors.append(
                "At least one complex reconstruction folder is required."
            )

        if (
            shell_names
            and shell_folders
            and complex_folders
            and not (
                len(shell_names)
                == len(shell_folders)
                == len(complex_folders)
            )
        ):
            errors.append(
                "Shell list lengths do not match:\n"
                f"  Shell names:           {len(shell_names)}\n"
                f"  Shell folders:         {len(shell_folders)}\n"
                f"  Complex recon folders: {len(complex_folders)}"
            )

        # Shell names should not contain whitespace
        for name in shell_names:

            if any(char.isspace() for char in name):
                errors.append(
                    f"Shell name contains whitespace: '{name}'"
                )

        # Folder numbers must be integers
        for folder in shell_folders:

            if not folder.isdigit():
                errors.append(
                    f"Invalid shell folder number: '{folder}'"
                )

        for folder in complex_folders:

            if not folder.isdigit():
                errors.append(
                    f"Invalid complex reconstruction folder: '{folder}'"
                )

        # Duplicate shell folders are probably accidental
        if len(shell_folders) != len(set(shell_folders)):
            errors.append(
                "Duplicate shell folder numbers were provided."
            )

        # =====================================================================
        # Check Bruker shell folders/files
        # =====================================================================

        if rawdir and os.path.isdir(rawdir):

            for i, folder in enumerate(shell_folders):

                shell_dir = os.path.join(
                    rawdir,
                    folder
                )

                if not os.path.isdir(shell_dir):

                    errors.append(
                        f"Shell directory does not exist:\n{shell_dir}"
                    )

                    continue

                method_file = os.path.join(
                    shell_dir,
                    "method"
                )

                if not os.path.isfile(method_file):

                    errors.append(
                        f"Missing Bruker method file:\n{method_file}"
                    )

                    continue

                # -------------------------------------------------------------
                # Check that a blip-down acquisition was not supplied as shell
                # -------------------------------------------------------------

                try:

                    with open(
                        method_file,
                        "r",
                        errors="ignore"
                    ) as handle:

                        method_text = handle.read()

                    if "##$BlipDownYN=Yes" in method_text:

                        errors.append(
                            "A diffusion shell is marked as BlipDownYN=Yes:\n"
                            f"{method_file}\n"
                            "Blip-down must be supplied separately."
                        )

                    if "##$PVM_NRepetitions=" not in method_text:

                        warnings.append(
                            "Could not find PVM_NRepetitions in:\n"
                            f"{method_file}"
                        )

                except OSError as error:

                    errors.append(
                        f"Could not read method file:\n"
                        f"{method_file}\n{error}"
                    )

                # -------------------------------------------------------------
                # Check requested complex reconstruction
                # -------------------------------------------------------------

                if i < len(complex_folders):

                    recon = complex_folders[i]

                    recon_dir = os.path.join(
                        shell_dir,
                        "pdata",
                        recon
                    )

                    if not os.path.isdir(recon_dir):

                        errors.append(
                            "Complex reconstruction directory does not exist:\n"
                            f"{recon_dir}"
                        )

                    else:

                        seq = os.path.join(
                            recon_dir,
                            "2dseq"
                        )

                        if not os.path.isfile(seq):

                            errors.append(
                                "2dseq file not found in complex "
                                f"reconstruction:\n{seq}"
                            )

        # =====================================================================
        # Species / condition
        # =====================================================================

        if self.species.get().lower() not in {
            "mouse",
            "rat"
        }:
            errors.append(
                "Species must be 'mouse' or 'rat'."
            )

        if self.condition.get().lower() not in {
            "invivo",
            "exvivo"
        }:
            errors.append(
                "Condition must be 'invivo' or 'exvivo'."
            )

        # =====================================================================
        # Preprocessing options
        # =====================================================================

        if self.drift_method.get().lower() not in {
            "b0",
            "shell"
        }:
            errors.append(
                "Drift correction must be 'b0' or 'shell'."
            )

        # =====================================================================
        # B-value selections
        # =====================================================================

        bval_options = [
            (
                "DTI/DKI",
                self.dtidki_bvals.get()
            )
        ]

        if self.run_bedpostx.get():

            bval_options.append(
                (
                    "BedpostX",
                    self.bedpostx_bvals.get()
                )
            )

        if self.run_noddi.get():

            bval_options.append(
                (
                    "NODDI",
                    self.noddi_bvals.get()
                )
            )

        for name, value in bval_options:

            if not valid_bvals(value):

                errors.append(
                    f"Invalid {name} b-values: '{value}'\n"
                    "Use ALL or comma-separated values, "
                    "e.g. 0,1000,2000."
                )

        # =====================================================================
        # NODDI dependencies
        # =====================================================================

        if (
            self.noddi_dot.get()
            and not self.run_noddi.get()
        ):
            errors.append(
                "NODDI dot compartment is enabled but "
                "Run NODDI is not enabled."
            )

        # =====================================================================
        # Advanced files
        # =====================================================================

        topupcnf = self.topupcnf.get().strip()

        if topupcnf:

            if not os.path.isfile(topupcnf):

                errors.append(
                    f"TOPUP config does not exist:\n{topupcnf}"
                )

            elif not topupcnf.endswith(".cnf"):

                warnings.append(
                    "Custom TOPUP configuration does not have "
                    f"a .cnf extension:\n{topupcnf}"
                )

        indextxt = self.indextxt.get().strip()

        if indextxt:

            if not os.path.isfile(indextxt):

                errors.append(
                    f"Custom Eddy index file does not exist:\n{indextxt}"
                )

            else:

                try:

                    with open(indextxt, "r") as handle:
                        values = handle.read().split()

                    if not values:

                        errors.append(
                            "Custom Eddy index file is empty."
                        )

                    elif not all(
                        value.isdigit()
                        and int(value) >= 1
                        for value in values
                    ):
                        errors.append(
                            "Custom Eddy index file must contain "
                            "positive integer indices."
                        )

                except OSError as error:

                    errors.append(
                        f"Could not read Eddy index file:\n{error}"
                    )

        # =====================================================================
        # Report
        # =====================================================================

        if errors:

            text = (
                f"Validation found {len(errors)} error(s)."
            )

            if warnings:
                text += (
                    f"\n\nIt also found "
                    f"{len(warnings)} warning(s)."
                )

            text += (
                "\n\nOpen the validation report "
                "for details."
            )

            report = "ERRORS\n======\n\n"
            report += "\n\n".join(
                f"✗ {error}"
                for error in errors
            )

            if warnings:

                report += "\n\n\nWARNINGS\n========\n\n"
                report += "\n\n".join(
                    f"⚠ {warning}"
                    for warning in warnings
                )

            self.show_text_window(
                "Validation report",
                report
            )

            messagebox.showerror(
                "Validation failed",
                text
            )

            return False

        if warnings:

            report = (
                "VALIDATION PASSED WITH WARNINGS\n"
                "===============================\n\n"
            )

            report += "\n\n".join(
                f"⚠ {warning}"
                for warning in warnings
            )

            self.show_text_window(
                "Validation report",
                report
            )

            if show_success:

                messagebox.showwarning(
                    "Validation passed with warnings",
                    f"All required checks passed.\n\n"
                    f"{len(warnings)} warning(s) were found."
                )

            return True

        if show_success:

            messagebox.showinfo(
                "Validation successful",
                "All input checks passed successfully."
            )

        return True


    # ========================================================================
    # Run pipeline
    # ========================================================================

    def run_pipeline(self):

        if not self.validate_inputs(
            show_success=False
        ):
            return

        command = self.build_command()

        answer = messagebox.askyesno(
            "Run pipeline?",
            "Submit the pipeline using the displayed command?"
        )

        if not answer:
            return

        try:

            process = subprocess.Popen(
                command,
                start_new_session=True
            )

            messagebox.showinfo(
                "Pipeline started",
                "Pipeline started successfully.\n\n"
                f"Process ID: {process.pid}\n\n"
                "Check the pipeline output directory and logs "
                "for processing status."
            )

        except Exception as error:

            messagebox.showerror(
                "Could not start pipeline",
                str(error)
            )


    # ========================================================================
    # Help
    # ========================================================================

    def show_help(self, title, text):

        self.show_text_window(
            title,
            text.strip()
        )


    def show_cli_help(self):

        pipeline = self.pipeline.get().strip()

        if not pipeline:

            messagebox.showerror(
                "Pipeline not found",
                "Select a pipeline script first."
            )
            return

        if not os.path.isfile(pipeline):

            messagebox.showerror(
                "Pipeline not found",
                f"Pipeline script does not exist:\n{pipeline}"
            )
            return

        try:

            result = subprocess.run(
                [pipeline, "--help"],
                capture_output=True,
                text=True,
                check=False
            )

            text = result.stdout

            if result.stderr:
                text += "\n" + result.stderr

            self.show_text_window(
                "RERE command-line help",
                text
            )

        except Exception as error:

            messagebox.showerror(
                "Could not load help",
                str(error)
            )


    def show_text_window(
        self,
        title,
        text
    ):

        window = tk.Toplevel(self)

        window.title(title)
        window.geometry("650x500")

        frame = ttk.Frame(
            window,
            padding=8
        )
        frame.pack(
            fill="both",
            expand=True
        )

        scrollbar = ttk.Scrollbar(frame)
        scrollbar.pack(
            side="right",
            fill="y"
        )

        text_widget = tk.Text(
            frame,
            wrap="word",
            yscrollcommand=scrollbar.set
        )

        text_widget.pack(
            side="left",
            fill="both",
            expand=True
        )

        scrollbar.configure(
            command=text_widget.yview
        )

        text_widget.insert(
            "1.0",
            text
        )

        text_widget.configure(
            state="disabled"
        )


# ============================================================================
# Main
# ============================================================================

if __name__ == "__main__":

    app = REREGui()
    app.mainloop()