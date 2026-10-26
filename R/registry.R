# ============================================================
# registry.R — GUI 持久提交注册表 (schema v2)
# 跨会话按 JobID 定位日志; 与通知状态同目录, 复用其互斥锁。
#
# schema v2 (v1.11): 追加 script_path/out_file/sif/apptainer/版本 列。
# 旧文件读取时按列名补齐 NA, 不需要迁移; 旧版代码读 v2 文件也只取自己认识的列。
# ============================================================
jobs_registry_file <- function() {
  file.path(dirname(cfg_get("NOTIFY_STATE")), "diann_gui_jobs_registry.rds")
}

jobs_registry_empty <- function() {
  data.frame(jobid = character(0), 任务名 = character(0), 输出目录 = character(0),
             日志 = character(0), 提交时间 = character(0),
             script_path = character(0), out_file = character(0), sif = character(0),
             apptainer = character(0), 版本 = character(0), stringsAsFactors = FALSE)
}

jobs_registry_load <- function() {
  empty <- jobs_registry_empty()
  if (!file.exists(jobs_registry_file())) return(empty)
  df <- tryCatch(readRDS(jobs_registry_file()), error = function(e) NULL)
  if (!is.data.frame(df) || !nrow(df)) return(empty)
  # 向后兼容 v1: 缺列补 NA, 已有列统一成字符型
  for (nm in names(empty)) {
    if (!nm %in% names(df)) df[[nm]] <- NA_character_ else df[[nm]] <- as.character(df[[nm]])
  }
  rownames(df) <- NULL
  df[, names(empty), drop = FALSE]
}

jobs_registry_add <- function(jobid, task, out_dir, script_path = NA_character_,
                              out_file = NA_character_, sif = NA_character_,
                              apptainer = NA_character_, ver = NA_character_) {
  chr1 <- function(x) {
    if (is.null(x) || !length(x) || is.na(x[1])) NA_character_ else as.character(x[1])
  }
  have_lock <- exists("notify_lock_acquire")
  if (have_lock && !notify_lock_acquire()) return(invisible(FALSE))
  on.exit(if (have_lock) notify_lock_release(), add = TRUE)
  df <- jobs_registry_load()
  df <- df[df$jobid != as.character(jobid), , drop = FALSE]  # 同 ID 重新提交则覆盖
  df <- rbind(df, data.frame(
    jobid = as.character(jobid), 任务名 = as.character(task), 输出目录 = as.character(out_dir),
    日志 = file.path(out_dir, sprintf("slurm-%s.out", jobid)),
    提交时间 = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    script_path = chr1(script_path), out_file = chr1(out_file), sif = chr1(sif),
    apptainer = chr1(apptainer), 版本 = chr1(ver), stringsAsFactors = FALSE))
  # rbind 把新记录追加在尾部: 必须保留尾部 300 条, head() 会先把刚写入的记录丢掉
  df <- utils::tail(df, 300)
  tmp <- sprintf("%s.tmp.%d", jobs_registry_file(), Sys.getpid())
  ok <- tryCatch({ saveRDS(df, tmp); file.rename(tmp, jobs_registry_file()) },
                 error = function(e) FALSE, warning = function(w) FALSE)
  if (!identical(ok, TRUE)) try(unlink(tmp), silent = TRUE)
  invisible(ok)
}
