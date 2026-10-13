# ============================================================
# watcher.R — 拉起邮件通知守护进程
# worker 启动与每次提交成功后调用, 兼作失联对账 (已有存活实例则跳过)。
# ============================================================
ensure_diann_watcher <- function() {
  if (!isTRUE(cfg_get("MAIL_ENABLED"))) return(invisible(FALSE))
  pidfile <- cfg_get("NOTIFY_PIDFILE")
  pid <- if (file.exists(pidfile)) {
    suppressWarnings(as.integer(readLines(pidfile, warn = FALSE)[1]))
  } else NA_integer_
  if (!is.na(pid) && pid > 0 && system(sprintf("kill -0 %d 2>/dev/null", pid)) == 0L) {
    return(invisible(TRUE))
  }
  # 派生方式实测 (2026-10-03): worker 内 setsid 会失败 (rc=1), 而
  # `nohup ... &` + wait = TRUE 可用 —— sh 立即退出, watcher 被过继给 init (PPID=1),
  # 脱离 worker 进程生命周期
  rscript <- file.path(R.home("bin"), "Rscript")
  expr <- sprintf("diann.gui::watch_daemon(state = %s, pidfile = %s)",
                  shQuote(cfg_get("NOTIFY_STATE")), shQuote(pidfile))
  cmd <- sprintf("nohup %s --no-save --slave -e %s >> %s 2>&1 < /dev/null &",
                 shQuote(rscript), shQuote(expr), shQuote(cfg_get("NOTIFY_WATCH_LOG")))
  system(cmd, wait = TRUE)
  invisible(TRUE)
}
