# ============================================================
# diann_gui site configuration
#
# Copy this file to `config.R` (next to app.R) and edit it for your
# cluster. config.R is gitignored — keep site-specific values there.
# Every variable defined in config.R overrides the built-in default in
# app.R; anything left undefined falls back to the default.
#
# The defaults below are commented out: uncomment and edit what you need.
# ============================================================

# ---- R environment ----------------------------------------------------

# Extra R library tree that contains the dependency packages
# (shiny, shinydashboard, shinyFiles). Leave unset to use R's default
# .libPaths().
# EXTRA_LIB <- "/path/to/R/site-library"

# ---- DIA-NN container images ------------------------------------------

# Directories scanned recursively for DIA-NN container images matching
# diann*.sif. The version dropdown in the GUI is built from the scan.
# SIF_DIRS <- c("/srv/DIA-NN")

# Image preselected in the dropdown. Empty string = first scanned image.
# DEFAULT_SIF <- "/srv/DIA-NN/tools/diann-2.7.0.sif"

# ---- Data locations ----------------------------------------------------

# Root of the data tree browsable from the GUI (FASTA, RAW files and
# output directories are expected under this tree). Defaults to the run
# user's home directory.
# DATA_HOME <- "/share/home/demo"

# Built-in contaminant FASTA (cRAP) added to the command when contaminant
# quantification is enabled. Empty string = no preselected FASTA.
# CON_FASTA <- "/path/to/cRAP.fasta"

# ---- Slurm --------------------------------------------------------------

# Slurm partitions offered in the submit form; the first one is the default.
# SLURM_PARTITIONS <- c("compute")

# ---- Apptainer / Singularity --------------------------------------------

# Directories searched for the `apptainer` binary inside generated sbatch
# scripts (each is prepended to PATH if <dir>/apptainer exists).
# APPTAINER_PATHS <- c("/usr/local/bin")

# Environment module to load as a fallback when apptainer is not found on
# PATH. Empty string disables the module fallback.
# APPTAINER_MODULE_FALLBACK <- "apptainer/1.4.5"

# Extra host paths bind-mounted into the container (apptainer --bind).
# Apptainer only binds $HOME and the working directory by default — add
# paths here if your data lives elsewhere (e.g. a shared /share).
# BIND_PATHS <- c("/share")

# ---- Shared output directories (multi-user setups) ----------------------

# Unix group applied to GUI-created output directories: every directory
# the GUI creates is chmod 2770 (setgid + group-writable) and chgrp'd to
# this group, walking up the tree to DATA_HOME. Use this when lab members
# access outputs under a different account than the app's run user, and
# make sure the run user and those users share the group. Empty string
# disables the repair entirely (fine for single-user deployments).
# SHARED_GROUP <- "diann"

# ---- Email notifications (optional) --------------------------------------

# Python 3 interpreter used to send completion emails. Leave unset to
# auto-detect python3 on PATH. Emails are only sent when a mail_config.txt
# file (see mail_config.example.txt) exists next to app.R; without it the
# feature stays disabled.
# MAIL_PYTHON <- "/usr/bin/python3"
