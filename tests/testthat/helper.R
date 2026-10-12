# 测试公共设施: source 纯函数核心与通知共享逻辑 (状态文件指向临时目录, 不碰真实 HOME)
proj_root <- function() {
  d <- getwd()
  for (i in 1:5) {
    if (file.exists(file.path(d, "diann_core.R"))) return(normalizePath(d))
    d <- dirname(d)
  }
  stop("diann_core.R not found upward from ", getwd())
}
PROJECT_ROOT <- proj_root()
# local = TRUE: 让函数定义与本文件的常量同处一个环境
# (test_dir 的 helper/test 环境链与 globalenv 不互通, source 默认 globalenv 求值会割裂闭包)
source(file.path(PROJECT_ROOT, "diann_core.R"), local = TRUE)
CORE_ENV <- environment()
# 测试中临时改写 core 函数闭包环境里的站点常量 (用完请还原)
set_core_const <- function(name, value) assign(name, value, envir = CORE_ENV)

# notify_common.R 的状态文件与锁都落到临时 HOME
Sys.setenv(HOME = file.path(tempdir(), sprintf("diann_test_home_%d", Sys.getpid())))
dir.create(Sys.getenv("HOME"), showWarnings = FALSE, recursive = TRUE)
NOTIFY_STATE <- file.path(Sys.getenv("HOME"), "diann_gui_notify_state.rds")
source(file.path(PROJECT_ROOT, "notify_common.R"), local = TRUE)

# 站点常量 (core 函数运行期引用)
CON_FASTA <- ""
BASE_VOLUMES <- c(Data = tempdir())
APPTAINER_PATHS <- "/opt/apptainer/bin"
APPTAINER_MODULE_FALLBACK <- ""
BIND_PATHS <- "/share"

# 构造一份与 GUI params_ready 输出同构的参数表
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
    fasta_search = FALSE, reanalyse = TRUE, rt_prof = TRUE, peptidoforms = TRUE,
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
  # 浅层替换 (modifyList 会递归合并并丢弃无名列表元素, 修不动 var_mod_rows 这类 list-of-vectors)
  for (nm in names(overrides)) p[[nm]] <- overrides[[nm]]
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
