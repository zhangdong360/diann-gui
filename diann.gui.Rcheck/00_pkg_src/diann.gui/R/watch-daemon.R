# ============================================================
# watch-daemon.R — 邮件通知守护进程 (diann.gui 包内模块)
# 由 run_app()/提交成功后以 `nohup Rscript -e "diann.gui::watch_daemon(...)"`
# 派生, 脱离浏览器会话与 worker 生命周期。轮询状态文件中的待通知作业, 作业
# 离开 squeue 队列后调用 mail_notify.py 发送完成邮件 (从可访问 SMTP 服务器的
# 节点发出)。连续 idle_exit_sec 秒无待发记录则自退, 下次提交或页面打开时由
# ensure_diann_watcher() 按 pidfile 重新拉起。once = TRUE 只执行一轮检查即退
# (自测 / 手动补发积压邮件)。
# ============================================================

#' 邮件通知守护进程
#'
#' 轮询状态文件中的待通知作业, 作业离队后调用 mail_notify.py 发送完成邮件。
#' 通常不需要手动调用——应用会在启动与提交成功后自动以 nohup 派生本函数。
#'
#' @param state 通知状态文件路径 (默认取包配置的 NOTIFY_STATE)
#' @param pidfile pid 文件路径 (默认取包配置的 NOTIFY_PIDFILE)
#' @param interval 轮询间隔秒 (下限 5)
#' @param idle_exit_sec 空闲自退秒数
#' @param once TRUE = 只执行一轮检查即返回 (自测 / 手动补发)
#' @export
watch_daemon <- function(state = NULL, pidfile = NULL, interval = 60,
                         idle_exit_sec = 86400, once = FALSE) {
  diann_load_config()
  if (!is.null(state)) {
    .cfg$NOTIFY_STATE <- state
    .cfg$NOTIFY_LOCK_DIR <- paste0(state, ".lock")
  }
  if (is.null(pidfile)) pidfile <- cfg_get("NOTIFY_PIDFILE")
  interval <- suppressWarnings(as.integer(interval))
  if (is.na(interval) || interval < 5L) interval <- 60L
  idle_exit_sec <- suppressWarnings(as.numeric(idle_exit_sec))
  if (is.na(idle_exit_sec) || idle_exit_sec < 0) idle_exit_sec <- 86400

  log_msg <- function(...) cat(format(Sys.time(), "[%Y-%m-%d %H:%M:%S]"), ..., "\n", sep = " ")
  pid_alive <- function(p) {
    p <- suppressWarnings(as.integer(p))
    !is.na(p) && p > 0 && system(sprintf("kill -0 %d 2>/dev/null", p)) == 0L
  }

  notify_state <- cfg_get("NOTIFY_STATE")
  if (!once) {
    if (file.exists(pidfile)) {
      p <- suppressWarnings(readLines(pidfile, warn = FALSE)[1])
      if (pid_alive(p) && as.integer(p) != Sys.getpid()) {
        log_msg("已有 watcher 运行 (pid", p, "), 本实例退出")
        return(invisible(FALSE))
      }
    }
    try(writeLines(as.character(Sys.getpid()), pidfile), silent = TRUE)
  }
  log_msg("watcher 启动 pid =", Sys.getpid(), "state =", notify_state, "interval =", interval, "s")

  last_active <- as.numeric(Sys.time())
  repeat {
    sent <- tryCatch(diann_notify_tick(), error = function(e) { log_msg("tick 出错:", conditionMessage(e)); FALSE })
    if (isTRUE(sent)) last_active <- as.numeric(Sys.time())
    if (once) break
    pend <- tryCatch(any(!vapply(diann_notify_load()$recs, function(x) isTRUE(x$done), logical(1))),
                     error = function(e) FALSE)
    if (pend) last_active <- as.numeric(Sys.time())
    if (as.numeric(Sys.time()) - last_active > idle_exit_sec) {
      log_msg("空闲超过", idle_exit_sec, "s 且无待发记录, watcher 退出")
      break
    }
    Sys.sleep(interval)
  }
  if (!once && file.exists(pidfile)) {
    p <- suppressWarnings(as.integer(readLines(pidfile, warn = FALSE)[1]))
    if (identical(p, Sys.getpid())) try(unlink(pidfile), silent = TRUE)
  }
  log_msg("watcher 结束")
  invisible(TRUE)
}
