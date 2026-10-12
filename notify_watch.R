#!/usr/bin/env Rscript
# 独立邮件通知守护进程: 由 app.R (worker) 以 nohup 派生, 脱离浏览器会话与 worker 生命周期。
# 轮询状态文件中的待通知作业 (diann_gui_notify_state.rds), 作业离开 squeue 队列后调用
# mail_notify.py 发送完成邮件 (从可访问 SMTP 服务器的节点发出)。连续 IDLE_EXIT 秒无待发
# 记录则自退, 下次提交或页面打开时由 worker 的 ensure_diann_watcher() 按 pidfile 重新拉起。
# 用法: Rscript notify_watch.R [--state FILE] [--pidfile FILE] [--interval SEC]
#                              [--idle-exit-sec SEC] [--once]
#   --once  只执行一轮检查即退出 (自测 / 手动补发积压邮件)

argv <- commandArgs(trailingOnly = TRUE)
getarg <- function(flag, default) {
  i <- match(flag, argv)
  if (!is.na(i) && length(argv) >= i + 1L) return(argv[i + 1L])
  default
}
has_flag <- function(flag) !is.na(match(flag, argv))

# 自身目录: 优先从 --file= 推断 (兼容任意路径手动运行), 兜底为当前工作目录
self_dir <- local({
  a <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", a[grepl("^--file=", a)])
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else getwd()
})

# 站点配置: 与 app.R 加载同一份 config.R (可提供 MAIL_PYTHON 等)
cfg <- file.path(self_dir, "config.R")
if (file.exists(cfg)) source(cfg)

# 与 app.R 相同的脚本同目录推导; MAIL_PYTHON 缺省由 notify_common.R 从 PATH 探测
MAIL_PY <- file.path(self_dir, "mail_notify.py")
MAIL_CONF <- file.path(self_dir, "mail_config.txt")

st_arg <- getarg("--state", "")
if (nzchar(st_arg)) NOTIFY_STATE <- st_arg
source(file.path(self_dir, "notify_common.R"))

INTERVAL <- suppressWarnings(as.integer(getarg("--interval", "60")))
if (is.na(INTERVAL) || INTERVAL < 5L) INTERVAL <- 60L
IDLE_EXIT <- suppressWarnings(as.integer(getarg("--idle-exit-sec", "86400")))
if (is.na(IDLE_EXIT) || IDLE_EXIT < 0L) IDLE_EXIT <- 86400L
ONCE <- has_flag("--once")
pidfile <- getarg("--pidfile", NOTIFY_PIDFILE)

log_msg <- function(...) cat(format(Sys.time(), "[%Y-%m-%d %H:%M:%S]"), ..., "\n", sep = " ")
pid_alive <- function(p) {
  p <- suppressWarnings(as.integer(p))
  !is.na(p) && p > 0 && system(sprintf("kill -0 %d 2>/dev/null", p)) == 0L
}

if (!ONCE) {
  if (file.exists(pidfile)) {
    p <- suppressWarnings(readLines(pidfile, warn = FALSE)[1])
    if (pid_alive(p) && as.integer(p) != Sys.getpid()) {
      log_msg("已有 watcher 运行 (pid", p, "), 本实例退出")
      quit(save = "no", status = 0)
    }
  }
  try(writeLines(as.character(Sys.getpid()), pidfile), silent = TRUE)
}
log_msg("watcher 启动 pid =", Sys.getpid(), "state =", NOTIFY_STATE, "interval =", INTERVAL, "s")

last_active <- as.numeric(Sys.time())
repeat {
  sent <- tryCatch(diann_notify_tick(), error = function(e) { log_msg("tick 出错:", conditionMessage(e)); FALSE })
  if (isTRUE(sent)) last_active <- as.numeric(Sys.time())
  if (ONCE) break
  pend <- tryCatch(any(!vapply(diann_notify_load()$recs, function(x) isTRUE(x$done), logical(1))),
                   error = function(e) FALSE)
  if (pend) last_active <- as.numeric(Sys.time())
  if (as.numeric(Sys.time()) - last_active > IDLE_EXIT) {
    log_msg("空闲超过", IDLE_EXIT, "s 且无待发记录, watcher 退出")
    break
  }
  Sys.sleep(INTERVAL)
}
if (!ONCE && file.exists(pidfile)) {
  p <- suppressWarnings(as.integer(readLines(pidfile, warn = FALSE)[1]))
  if (identical(p, Sys.getpid())) try(unlink(pidfile), silent = TRUE)
}
log_msg("watcher 结束")
