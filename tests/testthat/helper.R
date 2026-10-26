# 测试公共设施: 加载 diann.gui 包 (散文件时代的 source/local=TRUE 契约随包化退役),
# 状态文件指向临时目录, 不碰真实 HOME。
proj_root <- function() {
  d <- getwd()
  for (i in 1:6) {
    if (file.exists(file.path(d, "DESCRIPTION")) && dir.exists(file.path(d, "R"))) {
      return(normalizePath(d))
    }
    d <- dirname(d)
  }
  # R CMD check 在 <pkg>.Rcheck/tests 下运行: 源码树不可得, 返回 "" 让依赖源码
  # 文本的交叉核对用例显式 skip (安装态测试不应依赖源码路径)。
  ""
}
PROJECT_ROOT <- proj_root()
# 夹具目录: 源码树用 <root>/tests/fixtures; R CMD check 时 tests/ 整体复制,
# 夹具可能在 tests/ 或 tests/testthat/ 的上一级 (兼容两种 testthat 工作目录)。
FIXTURES_DIR <- local({
  cands <- c(getwd(), file.path(getwd(), ".."), file.path(getwd(), "..", ".."))
  for (d in cands) {
    fx <- file.path(d, "fixtures")
    if (dir.exists(fx)) return(normalizePath(fx))
  }
  if (nzchar(PROJECT_ROOT)) file.path(PROJECT_ROOT, "tests", "fixtures") else ""
})

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
local_next_slot_info <- diann.gui:::local_next_slot_info
local_jobs_save <- diann.gui:::local_jobs_save
local_jobs_status <- diann.gui:::local_jobs_status
local_jobs_file <- diann.gui:::local_jobs_file
local_seq_file <- diann.gui:::local_seq_file
local_jobs_load <- diann.gui:::local_jobs_load
scan_sif_images <- diann.gui:::scan_sif_images
sif_check_local <- diann.gui:::sif_check_local
parse_diann_version <- diann.gui:::parse_diann_version
sif_identify <- diann.gui:::sif_identify
sif_probe_file <- diann.gui:::sif_probe_file
sif_probe_load <- diann.gui:::sif_probe_load
sif_probe_save <- diann.gui:::sif_probe_save
sif_probe_lookup <- diann.gui:::sif_probe_lookup
sif_probe_record <- diann.gui:::sif_probe_record
sif_ver_sort_string <- diann.gui:::sif_ver_sort_string
sif_version_key <- diann.gui:::sif_version_key
sif_display_order <- diann.gui:::sif_display_order
sif_merge_probe <- diann.gui:::sif_merge_probe
sif_choice_labels <- diann.gui:::sif_choice_labels
sif_default_index <- diann.gui:::sif_default_index
sif_version_of <- diann.gui:::sif_version_of
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
notify_defer_unknown <- diann.gui:::notify_defer_unknown
archive_stale_artifacts <- diann.gui:::archive_stale_artifacts
safe_job_name <- diann.gui:::safe_job_name
apptainer_parse_version <- diann.gui:::apptainer_parse_version
apptainer_check <- diann.gui:::apptainer_check
apptainer_discover <- diann.gui:::apptainer_discover
apptainer_candidates <- diann.gui:::apptainer_candidates
apptainer_choices <- diann.gui:::apptainer_choices
apptainer_default <- diann.gui:::apptainer_default
apptainer_cands_sif <- diann.gui:::apptainer_cands_sif
sif_capable <- diann.gui:::sif_capable
sif_min_version_text <- diann.gui:::sif_min_version_text
init_config_autofill <- diann.gui:::init_config_autofill
watcher_spawn_command <- diann.gui:::watcher_spawn_command
container_visible <- diann.gui:::container_visible
cleanup_old_artifacts <- diann.gui:::cleanup_old_artifacts
slurm_snapshot <- diann.gui:::slurm_snapshot
slurm_snapshot_fns <- diann.gui:::slurm_snapshot_fns
slurm_queue_states <- diann.gui:::slurm_queue_states

# v1.12 执行后端 (slurm / local)
exec_backend <- diann.gui:::exec_backend
detect_exec_backend <- diann.gui:::detect_exec_backend
backend_info <- diann.gui:::backend_info
backend_label <- diann.gui:::backend_label
backend_script <- diann.gui:::backend_script
backend_submit <- diann.gui:::backend_submit
backend_snapshot <- diann.gui:::backend_snapshot
backend_status_fns <- diann.gui:::backend_status_fns
backend_log_paths <- diann.gui:::backend_log_paths
backend_cancel <- diann.gui:::backend_cancel
backend_elapsed <- diann.gui:::backend_elapsed
backend_history <- diann.gui:::backend_history
slurm_available <- diann.gui:::slurm_available
job_body <- diann.gui:::job_body
slurm_script_header <- diann.gui:::slurm_script_header
make_local_script <- diann.gui:::make_local_script
make_job_script <- diann.gui:::make_job_script
local_jobs_find <- diann.gui:::local_jobs_find
local_jobs_load <- diann.gui:::local_jobs_load
local_job_alive <- diann.gui:::local_job_alive
local_job_state <- diann.gui:::local_job_state
local_seq_next <- diann.gui:::local_seq_next
local_runner_path <- diann.gui:::local_runner_path
local_cancel <- diann.gui:::local_cancel

# v1.12 本地后端测试设施: 假 apptainer (--version 正常; exec 按 --out 写报告,
# 行为由环境变量 FAKE_DIANN_SLEEP / FAKE_DIANN_RC 控制; 也可用 control 文件)。
fake_apptainer <- function(dir = tempfile("fakeapt")) {
  dir.create(file.path(dir, "bin"), recursive = TRUE, showWarnings = FALSE)
  p <- file.path(dir, "bin", "apptainer")
  writeLines(c(
    "#!/bin/bash",
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'apptainer version 1.4.5'; exit 0; fi",
    "out=''; prev=''",
    "for a in \"$@\"; do if [ \"$prev\" = \"--out\" ]; then out=\"$a\"; fi; prev=\"$a\"; done",
    "ctl=\"${FAKE_DIANN_CTL:-}\"",
    "if [ -n \"$ctl\" ] && [ -f \"$ctl\" ]; then sleep \"$(cat \"$ctl\")\" 2>/dev/null || true; else sleep \"${FAKE_DIANN_SLEEP:-1}\"; fi",
    "if [ -n \"$out\" ]; then mkdir -p \"$(dirname \"$out\")\"; printf 'Protein.Names\\nP123\\n' > \"$out\"; fi",
    "exit \"${FAKE_DIANN_RC:-0}\""), p)
  Sys.chmod(p, "0755")
  p
}

# 本地模式测试参数 (与 server params_ready() 同构的最小集合)
make_local_params <- function(out_dir, apptainer_bin, time_h = 1 / 120) {
  base_params(list(
    job_name = "local_test", partition = NA_character_, sif = "/tmp/fake.sif",
    apptainer_bin = apptainer_bin, out_dir = out_dir,
    out_file = file.path(out_dir, "report.tsv"),
    slurm_out = "", slurm_err = "", time_h = time_h,
    script_path = file.path(out_dir, sprintf("job_%d.sh", as.integer(runif(1, 1, 1e9))))))
}

# 轮询本地作业直到终态 (成功/失败/超时/已取消); 返回 label
poll_local_status <- function(p, job_id, timeout_s = 30) {
  fns <- backend_status_fns("local")
  lp <- backend_log_paths(job_id, p$out_dir, "local", p$script_path)
  t0 <- Sys.time(); label <- NA_character_
  while (as.numeric(Sys.time() - t0) < timeout_s) {
    st <- diann_job_status(job_id, p$out_dir, p$out_file, script_path = p$script_path,
                           squeue_fn = fns$squeue_fn, sacct_fn = fns$sacct_fn,
                           log_path = lp$out)
    label <- st$label
    if (label %in% c("成功", "失败", "超时", "已取消")) break
    Sys.sleep(0.3)
  }
  label
}

# 构造一份与 GUI server 收集结果同构的参数表
base_params <- function(overrides = list()) {
  p <- list(
    job_name = "T", partition = "compute", threads = 16, mem_gb = 64, time_h = 12,
    sif = "/x/diann-2.7.0.sif", ver = "2.7.0",
    apptainer_bin = "/opt/apptainer/bin/apptainer",
    slurm_out = "/o/slurm-%j.out", slurm_err = "/o/slurm-%j.err",
    script_path = "/o/diann_gui_scripts/diann_test.sh",
    raw_mode = "files", raws = "/d/a.raw", raw_dir = "", lib = "", ref = "",
    fastas = c(), temp = "", out_dir = "/o", report_name = "report", out_file = "/o/report.tsv",
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
