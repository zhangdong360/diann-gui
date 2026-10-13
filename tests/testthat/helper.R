# 测试公共设施: 加载 diann.gui 包 (散文件时代的 source/local=TRUE 契约随包化退役),
# 状态文件指向临时目录, 不碰真实 HOME。
proj_root <- function() {
  d <- getwd()
  for (i in 1:6) {
    if (file.exists(file.path(d, "DESCRIPTION"))) return(normalizePath(d))
    d <- dirname(d)
  }
  stop("DESCRIPTION not found upward from ", getwd())
}
PROJECT_ROOT <- proj_root()

library(diann.gui)

# 测试中临时改写包配置 (diann_load_config 的注入接口)
set_core_const <- function(key, value) diann.gui::set_core_const(key, value)

# 临时 HOME: 通知状态/注册表落临时目录 (diann_load_config 依赖 HOME)
Sys.setenv(HOME = file.path(tempdir(), sprintf("diann_test_home_%d", Sys.getpid())))
dir.create(Sys.getenv("HOME"), showWarnings = FALSE, recursive = TRUE)
diann_load_config()

# 包内部函数别名 (测试体零改动)
build_diann_chunks <- diann.gui:::build_diann_chunks
parse_diann_command <- diann.gui:::parse_diann_command
make_slurm_script <- diann.gui:::make_slurm_script
path_in_scope <- diann.gui:::path_in_scope
collapse_dots <- diann.gui:::collapse_dots
imported_var_mods_max <- diann.gui:::imported_var_mods_max
vm_default <- diann.gui:::vm_default
scan_sif_images <- diann.gui:::scan_sif_images
diann_notify_elapsed <- diann.gui:::diann_notify_elapsed
diann_job_status <- diann.gui:::diann_job_status
slurm_state_normalize <- diann.gui:::slurm_state_normalize
diann_notify_load <- diann.gui:::diann_notify_load
diann_notify_save <- diann.gui:::diann_notify_save
diann_notify_add <- diann.gui:::diann_notify_add
diann_notify_tick <- diann.gui:::diann_notify_tick
BOOL_FLAG_MAP <- diann.gui:::BOOL_FLAG_MAP
NUM_FLAG_MAP <- diann.gui:::NUM_FLAG_MAP
TEXT_FLAG_MAP <- diann.gui:::TEXT_FLAG_MAP
PATH_VALUE_FLAGS <- diann.gui:::PATH_VALUE_FLAGS
NOTIFY_STATE <- cfg_get("NOTIFY_STATE")
notify_lock_acquire <- diann.gui:::notify_lock_acquire
notify_lock_release <- diann.gui:::notify_lock_release
diann_notify_tick <- diann.gui:::diann_notify_tick
BOOL_FLAG_MAP <- diann.gui:::BOOL_FLAG_MAP
NUM_FLAG_MAP <- diann.gui:::NUM_FLAG_MAP
TEXT_FLAG_MAP <- diann.gui:::TEXT_FLAG_MAP
PATH_VALUE_FLAGS <- diann.gui:::PATH_VALUE_FLAGS
NOTIFY_STATE <- cfg_get("NOTIFY_STATE")

# 构造一份与 GUI server 收集结果同构的参数表
base_params <- function(overrides = list()) {
  p <- list(
    job_name = "T", partition = "compute", threads = 16, mem_gb = 64, time_h = 12,
    sif = "/x/diann-2.7.0.sif", ver = "2.7.0",
    slurm_out = "/o/slurm-%j.out", slurm_err = "/o/slurm-%j.err",
    script_path = "/o/diann_gui_scripts/diann_test.sh",
    raw_mode = "files", raws = "/d/a.raw", raw_dir = "", lib = "", ref = "",
    fastas = c(), temp = "", out_dir = "/o", out_file = "/o/report.tsv",
    verbose = 1L, qvalue = 0.01, convert_only = FALSE, cont_exclude = FALSE,
    cont_tag = "cRAP-", var_mods_max = 1,
    var_mod_rows = list(c("UniMod:35", "15.994915", "M")), fixed_mod_rows = list(),
    extra = "", use_cut = FALSE, cut = "", gen_spec_lib = FALSE, out_lib = "",
    fasta_search = FALSE, mbr = TRUE, rt_prof = TRUE, peptidoforms = TRUE,
    proteoforms = FALSE, matrices = TRUE, indiv_reports = FALSE, unimod4 = TRUE,
    met_excision = FALSE, reannotate = FALSE,
    mass_acc = NA, mass_acc_ms1 = NA, window = NA, min_peak = NA, rt_window = NA,
    im_window = NA, quant_qvalue = NA, protein_quant_qvalue = NA, matrix_qvalue = NA,
    missed_cleavages = NA, min_pep_len = NA, max_pep_len = NA, min_pr_mz = NA,
    max_pr_mz = NA, min_pr_charge = NA, max_pr_charge = NA, min_fr_mz = NA,
    max_fr_mz = NA, predictor = FALSE, light_models = FALSE, out_lib_qvalue = NA,
    export_quant = FALSE, report_decoys = FALSE, individual_windows = FALSE,
    individual_mass_acc = FALSE, global_norm = FALSE, no_rt_norm = FALSE,
    no_prot_norm = FALSE, high_acc = FALSE, no_skyline = FALSE, no_stats = FALSE,
    xic = NA, min_corr = NA, project_desc = ""
  )
  for (nm in names(overrides)) p[[nm]] = overrides[[nm]]
  p
}

# 造一个带日志与产物的临时输出目录; 返回 c(out_dir, out_file)
make_out_dir <- function(report = TRUE, mtime_epoch = 1050, start_epoch = 1000,
                         rc_line = "exit code: 0", empty_report = FALSE) {
  d <- file.path(tempdir(), sprintf("djstat_%d_%d", Sys.getpid(),
                                    as.integer(runif(1, 1, 1e9))))
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  writeLines(c(sprintf("DIANN_GUI_START_EPOCH %d", start_epoch),
               rc_line, sprintf("DIANN_GUI_END_EPOCH %d", mtime_epoch)),
             file.path(d, "slurm-99.out"))
  rf <- file.path(d, "report.tsv")
  if (report) {
    writeLines(c("Protein.Names", "P123"), rf)
    if (empty_report) writeLines(character(0), rf)
    Sys.setFileTime(rf, mtime_epoch)
  }
  c(d, rf)
}
