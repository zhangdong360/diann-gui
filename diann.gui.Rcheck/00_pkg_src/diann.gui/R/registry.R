# ============================================================
# registry.R — GUI 持久提交注册表
# 跨会话按 JobID 定位日志; 与通知状态同目录, 复用其互斥锁。
# ============================================================
jobs_registry_file <- function() {
  file.path(dirname(cfg_get("NOTIFY_STATE")), "diann_gui_jobs_registry.rds")
}

jobs_registry_load <- function() {
  empty <- data.frame(jobid = character(0), 任务名 = character(0), 输出目录 = character(0),
                      日志 = character(0), 提交时间 = character(0), stringsAsFactors = FALSE)
  if (!file.exists(jobs_registry_file())) return(empty)
  tryCatch(readRDS(jobs_registry_file()), error = function(e) empty)
}
jobs_registry_add <- function(jobid, task, out_dir) {
  have_lock <- exists("notify_lock_acquire")
  if (have_lock && !notify_lock_acquire()) return(invisible(FALSE))
  on.exit(if (have_lock) notify_lock_release(), add = TRUE)
  df <- jobs_registry_load()
  df <- df[df$jobid != as.character(jobid), , drop = FALSE]  # 同 ID 重新提交则覆盖
  df <- rbind(df, data.frame(
    jobid = as.character(jobid), 任务名 = as.character(task), 输出目录 = as.character(out_dir),
    日志 = file.path(out_dir, sprintf("slurm-%s.out", jobid)),
    提交时间 = format(Sys.time(), "%Y-%m-%d %H:%M:%S"), stringsAsFactors = FALSE))
  df <- utils::head(df, 300)  # 只保留最近 300 条
  tmp <- sprintf("%s.tmp.%d", jobs_registry_file(), Sys.getpid())
  ok <- tryCatch({ saveRDS(df, tmp); file.rename(tmp, jobs_registry_file()) },
                 error = function(e) FALSE, warning = function(w) FALSE)
  if (!identical(ok, TRUE)) try(unlink(tmp), silent = TRUE)
  invisible(ok)
}

# 拉起 watcher (已有存活实例则跳过); worker 启动与每次提交成功后调用, 兼作失联对账
