# ============================================================
# watcher.R — 拉起邮件通知守护进程
# worker 启动与每次提交成功后调用, 兼作失联对账 (已有存活实例则跳过)。
# 自托管模式下包装在用户库: 必须把当前 .libPaths() 与配置文件显式传给子进程,
# 否则新的 Rscript 会话可能找不到 diann.gui 或读不到同一份配置。
# ============================================================
# 构造派生 watcher 的 shell 命令 (纯函数, 便于测试):
# 显式带上用户库路径与配置文件, 让新 Rscript 会话与当前会话看到同一个包/配置。
watcher_spawn_command <- function(rscript = file.path(R.home("bin"), "Rscript"),
                                  state = cfg_get("NOTIFY_STATE"),
                                  pidfile = cfg_get("NOTIFY_PIDFILE"),
                                  logf = cfg_get("NOTIFY_WATCH_LOG"),
                                  cfg_file = cfg_get("CONFIG_FILE") %||% "") {
  libs <- paste(shQuote(.libPaths()), collapse = ", ")
  expr <- sprintf(".libPaths(c(%s, .libPaths())); diann.gui::watch_daemon(state = %s, pidfile = %s)",
                  libs, shQuote(state), shQuote(pidfile))
  env_prefix <- if (nzchar(cfg_file)) sprintf("DIANN_GUI_CONFIG=%s ", shQuote(cfg_file)) else ""
  sprintf("%snohup %s --no-save --slave -e %s >> %s 2>&1 < /dev/null &",
          env_prefix, shQuote(rscript), shQuote(expr), shQuote(logf))
}

ensure_diann_watcher <- function() {
  if (!isTRUE(cfg_get("MAIL_ENABLED"))) return(invisible(FALSE))
  pidfile <- cfg_get("NOTIFY_PIDFILE")
  pid_alive <- function(p) {
    p <- suppressWarnings(as.integer(p))
    !is.na(p) && p > 0 && system(sprintf("kill -0 %d 2>/dev/null", p)) == 0L
  }
  pid <- if (file.exists(pidfile)) suppressWarnings(as.integer(readLines(pidfile, warn = FALSE)[1])) else NA_integer_
  if (pid_alive(pid)) return(invisible(TRUE))

  # 派生方式实测 (2026-10-03): worker 内 setsid 会失败 (rc=1), 而
  # `nohup ... &` + wait = TRUE 可用 —— sh 立即退出, watcher 被过继给 init (PPID=1),
  # 脱离 worker 进程生命周期
  logf <- cfg_get("NOTIFY_WATCH_LOG")
  system(watcher_spawn_command(), wait = TRUE)

  # 最多等 3 s 确认 watcher 存活; 失败只记录, 不阻断提交
  ok <- FALSE
  for (i in seq_len(30)) {
    if (file.exists(pidfile) && pid_alive(readLines(pidfile, warn = FALSE)[1])) {
      ok <- TRUE
      break
    }
    Sys.sleep(0.1)
  }
  if (!ok) {
    try(cat(format(Sys.time(), "[%Y-%m-%d %H:%M:%S]"),
            "watcher 未能启动, 详见", logf, "\n", file = logf, append = TRUE), silent = TRUE)
  }
  invisible(ok)
}
