# ============================================================
# backend-local.R — 本地执行后端实现 (v1.12)
#
# 设计要点:
#   - 作业身份: 持久化整数自增序列 (初值 1000001), 与现有 as.integer(jobid)/
#     四层状态/注册表/月报契约兼容; 不使用 PID 当 JobID (PID 会复用)。
#   - 执行: 生成与 Slurm 模式同一个 job_body() 的本地脚本, 由
#     inst/scripts/local_runner.sh 以 setsid+nohup 派生, 脱离 Shiny 会话;
#     日志固定 local-<id>.out/.err, 退出码仍写 <script>.rc。
#   - 状态: 不依赖调度器; /proc starttime + cmdline 防 PID 复用; 取消/超时通过
#     <script>.cancelled / <script>.timeout 标记表达, 再合成与 Slurm 同名的
#     终态 (RUNNING/PENDING/COMPLETED/FAILED/CANCELLED/TIMEOUT), 交给现有
#     四层状态合成 (diann_job_status) —— 面板/邮件/月报语义完全一致。
#   - 状态文件: 每用户 <NOTIFY_STATE 目录>/diann_gui_local_jobs.rds (最近 300 条)
#     与 diann_gui_local_seq; 复用通知模块的 mkdir 互斥锁 + 临时文件 rename 原子写。
# ============================================================

# ---------- 状态目录与文件 ----------

local_state_dir <- function() {
  st <- cfg_get("NOTIFY_STATE") %||% file.path(path.expand("~"), "diann_gui_notify_state.rds")
  d <- dirname(st)
  if (!dir.exists(d)) {
    dir.create(d, showWarnings = FALSE, recursive = TRUE, mode = "0700")
  }
  d
}

local_jobs_file <- function() file.path(local_state_dir(), "diann_gui_local_jobs.rds")
local_seq_file <- function() file.path(local_state_dir(), "diann_gui_local_seq")

local_jobs_empty <- function() list(recs = list())

# v1.13: 损坏不再静默返回空 — 备份 .corrupt-<ts> + 落状态日志 + 设置一次性 UI/doctor
# 告警 (.cfg$LOCAL_JOBS_WARN) 后返回空表; 逐条记录校验, 坏记录丢弃并计数。
local_jobs_note_corrupt <- function(f, why) {
  stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  bak <- sprintf("%s.corrupt-%s", f, stamp)
  ok <- file.rename(f, bak)
  if (!ok) {  # 重名 .N; 再失败退化为 copy
    n <- 0L
    repeat { cand <- sprintf("%s.%d", bak, n); if (!file.exists(cand)) break; n <- n + 1L }
    ok <- try(file.copy(f, cand, overwrite = TRUE), silent = TRUE)
    bak <- if (isTRUE(ok)) cand else "(备份失败)"
  }
  logf <- file.path(local_state_dir(), "diann_gui_local_state.log")
  try(cat(sprintf("%s local_jobs_load: %s; 备份: %s\n",
                  format(Sys.time(), "%Y-%m-%d %H:%M:%S"), why, bak),
          file = logf, append = TRUE), silent = TRUE)
  warn <- sprintf(paste0("本地作业状态文件损坏 (%s), 已备份为 %s — 在跑作业已从面板移除, ",
                         "进程可能仍在运行: 可用 ps -ef | grep local_runner 查看/手动结束; ",
                         "详见 diann_gui_local_state.log"),
                  basename(f), bak)
  try(assign("LOCAL_JOBS_WARN", warn, envir = .cfg), silent = TRUE)
}

local_jobs_load <- function(recover = TRUE) {
  f <- local_jobs_file()
  if (!file.exists(f)) return(local_jobs_empty())
  x <- tryCatch(readRDS(f), error = function(e) NULL)
  if (!is.list(x) || is.null(x$recs) || !is.list(x$recs)) {
    if (isTRUE(recover)) local_jobs_note_corrupt(f, "RDS 解析失败或结构非法")
    return(local_jobs_empty())
  }
  # 逐条校验: 无 jobid 的坏记录丢弃 (计数告警, 不静默)
  ok_rec <- vapply(x$recs, function(r) is.list(r) && !is.null(r$jobid) &&
                     nzchar(as.character(r$jobid)[1]), logical(1))
  if (!all(ok_rec)) {
    n_bad <- sum(!ok_rec)
    x$recs <- x$recs[ok_rec]
    try(cat(sprintf("%s local_jobs_load: 丢弃 %d 条坏记录\n",
                    format(Sys.time(), "%Y-%m-%d %H:%M:%S"), n_bad),
            file = file.path(local_state_dir(), "diann_gui_local_state.log"), append = TRUE),
        silent = TRUE)
  }
  x
}

# 只读健康检查 (doctor 用): 不修改任何文件, 返回 list(ok, detail, warn)
local_jobs_status <- function() {
  f <- local_jobs_file()
  if (!file.exists(f)) return(list(ok = TRUE, detail = "尚未创建 (无本地作业历史)", warn = ""))
  w <- cfg_get("LOCAL_JOBS_WARN") %||% ""
  x <- tryCatch(readRDS(f), error = function(e) NULL)
  if (!is.list(x) || is.null(x$recs) || !is.list(x$recs)) {
    return(list(ok = FALSE, detail = sprintf("文件存在但不可解析: %s", f), warn = w))
  }
  list(ok = TRUE, detail = sprintf("%d 条记录, %s", length(x$recs), f), warn = w)
}

# 调用方负责锁; 这里只做最近 300 条截断 + 原子写
local_jobs_save <- function(x) {
  if (length(x$recs) > 300L) x$recs <- utils::tail(x$recs, 300L)
  f <- local_jobs_file()
  tmp <- sprintf("%s.tmp.%d", f, Sys.getpid())
  ok <- tryCatch({ saveRDS(x, tmp); file.rename(tmp, f) },
                 error = function(e) FALSE, warning = function(w) FALSE)
  if (!isTRUE(ok)) try(unlink(tmp), silent = TRUE)
  invisible(isTRUE(ok))
}

# 通知模块的 mkdir 锁 (跨 worker/watcher/并发提交)。拿不到锁时退化为"不持锁写",
# 单用户场景下仍安全 (原子 rename), 只是并发 seq 分配理论上可能撞号 -> 有锁时不会。
local_with_lock <- function(fn) {
  acquired <- tryCatch(notify_lock_acquire(timeout = 5), error = function(e) FALSE)
  if (isTRUE(acquired)) on.exit(notify_lock_release(), add = TRUE)
  fn()
}

local_seq_next <- function() {
  f <- local_seq_file()
  val <- local_with_lock(function() {
    cur <- 1000000L
    if (file.exists(f)) {
      v <- suppressWarnings(as.integer(trimws(readLines(f, warn = FALSE)[1])))
      if (!is.na(v)) cur <- v
    }
    # v1.13 自愈: 序列文件损坏(NA)或落后于已有作业 max(jobid) 时, 以 max(existing)+1
    # 续号, 防止撞号 (撞号会覆盖/误取消旧作业)。异常序列文件备份 .corrupt-<ts>。
    existing <- suppressWarnings(as.integer(vapply(
      local_jobs_load()$recs, function(r) as.character(r$jobid)[1], character(1))))
    existing <- existing[!is.na(existing)]
    mx <- if (length(existing)) max(existing) else 0L
    if (is.na(cur) || cur <= mx) {
      if (file.exists(f)) {
        stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
        try(file.rename(f, sprintf("%s.corrupt-%s", f, stamp)), silent = TRUE)
      }
      cur <- mx
    }
    nxt <- cur + 1L
    tmp <- sprintf("%s.tmp.%d", f, Sys.getpid())
    ok <- tryCatch({ writeLines(as.character(nxt), tmp); file.rename(tmp, f) },
                   error = function(e) FALSE)
    if (!isTRUE(ok)) { try(unlink(tmp), silent = TRUE); return(NA_integer_) }
    nxt
  })
  if (length(val) != 1 || is.na(val)) NA_integer_ else as.integer(val)
}

local_jobs_add <- function(rec) {
  local_with_lock(function() {
    x <- local_jobs_load()
    x$recs <- c(list(rec), x$recs)
    local_jobs_save(x)
  })
}

local_jobs_update <- function(rec) {
  local_with_lock(function() {
    x <- local_jobs_load()
    id <- as.character(rec$jobid)
    idx <- which(vapply(x$recs, function(r) identical(as.character(r$jobid), id), logical(1)))
    if (length(idx)) x$recs[[idx[1]]] <- rec else x$recs <- c(list(rec), x$recs)
    local_jobs_save(x)
  })
}

local_jobs_remove <- function(job_id) {
  local_with_lock(function() {
    x <- local_jobs_load()
    id <- as.character(job_id)
    x$recs <- Filter(function(r) !identical(as.character(r$jobid), id), x$recs)
    local_jobs_save(x)
  })
}

local_jobs_find <- function(job_id) {
  x <- local_jobs_load()
  id <- as.character(job_id)
  for (r in x$recs) if (identical(as.character(r$jobid), id)) return(r)
  NULL
}

# ---------- /proc 进程工具 ----------

local_proc_stat_fields <- function(pid) {
  pid <- suppressWarnings(as.integer(pid))
  if (is.na(pid) || pid <= 0) return(character(0))
  st <- tryCatch(suppressWarnings(readLines(sprintf("/proc/%d/stat", pid), warn = FALSE)),
                 error = function(e) character(0))
  if (!length(st) || !nzchar(st[1])) return(character(0))
  # comm 字段可能含空格/括号: 以最后一个 ") " 之后重新切分
  rest <- sub("^.*\\) ", "", st[1])
  strsplit(trimws(rest), " ", fixed = TRUE)[[1]]
}

# /proc/<pid>/stat 第 22 字段 starttime (时钟滴答): 防 PID 复用
local_proc_starttime <- function(pid) {
  f <- local_proc_stat_fields(pid)
  if (length(f) < 20) return(NA_real_)
  suppressWarnings(as.numeric(f[20]))
}

# /proc/<pid>/stat 第 5 字段 pgrp (setsid 派生后 pgrp == pid, 可整组取消)
local_proc_pgid <- function(pid) {
  f <- local_proc_stat_fields(pid)
  if (length(f) < 3) return(NA_integer_)
  suppressWarnings(as.integer(f[3]))
}

local_proc_uid <- function(pid) {
  pid <- suppressWarnings(as.integer(pid))
  if (is.na(pid) || pid <= 0) return(NA_integer_)
  txt <- tryCatch(suppressWarnings(readLines(sprintf("/proc/%d/status", pid), warn = FALSE)),
                  error = function(e) character(0))
  line <- grep("^Uid:", txt, value = TRUE)
  if (!length(line)) return(NA_integer_)
  parts <- strsplit(trimws(sub("^Uid:", "", line[1])), "[[:space:]]+")[[1]]
  suppressWarnings(as.integer(parts[1]))
}

# 当前进程 UID (R 没有 Sys.getuid; 用 id -u, 失败返回 NA = 跳过同 UID 校验)
local_current_uid <- function() {
  u <- suppressWarnings(as.integer(system("id -u", intern = TRUE)))
  if (length(u) == 1 && !is.na(u)) u else NA_integer_
}

local_proc_cmdline <- function(pid) {
  pid <- suppressWarnings(as.integer(pid))
  if (is.na(pid) || pid <= 0) return("")
  tryCatch({
    raw <- suppressWarnings(readBin(sprintf("/proc/%d/cmdline", pid), "raw", 32768))
    if (!length(raw)) return("")
    raw[raw == as.raw(0)] <- as.raw(0x20)
    trimws(rawToChar(raw))
  }, error = function(e) "")
}

# 递归子进程树 (无 setsid 时的取消兜底)
local_pid_tree <- function() {
  dirs <- list.files("/proc", pattern = "^[0-9]+$")
  pids <- suppressWarnings(as.integer(dirs))
  out <- list()
  for (p in pids) {
    if (is.na(p)) next
    f <- local_proc_stat_fields(p)
    if (length(f) < 2) next
    pp <- suppressWarnings(as.integer(f[2]))  # stat: state(1) ppid(2) pgrp(3)...
    if (!is.na(pp)) out[[as.character(pp)]] <- c(out[[as.character(pp)]], p)
  }
  out
}

local_kill_tree <- function(pid, sig = "TERM", tree = NULL) {
  pid <- suppressWarnings(as.integer(pid))
  if (is.na(pid) || pid <= 1) return(invisible(FALSE))
  if (is.null(tree)) tree <- local_pid_tree()
  kids <- tree[[as.character(pid)]] %||% integer(0)
  for (k in kids) local_kill_tree(k, sig, tree)
  try(system(sprintf("kill -%s %d 2>/dev/null", sig, pid)), silent = TRUE)
  invisible(TRUE)
}

# ---------- 作业记录 / 状态 ----------

local_rc_path <- function(rec) {
  if (length(rec$rc_path) == 1 && nzchar(rec$rc_path %||% "")) return(rec$rc_path)
  sp <- rec$script_path %||% ""
  if (length(sp) == 1 && nzchar(sp)) sub("\\.sh$", ".rc", sp) else ""
}

local_marker <- function(rec, kind) {
  sp <- rec$script_path %||% ""
  if (length(sp) != 1 || !nzchar(sp)) return("")
  paste0(sp, ".", kind)
}

local_marker_exists <- function(rec, kind) {
  p <- local_marker(rec, kind)
  nzchar(p) && file.exists(p)
}

local_read_rc <- function(rec) {
  rc <- local_rc_path(rec)
  if (!nzchar(rc) || !file.exists(rc)) return(NA_integer_)
  v <- suppressWarnings(as.integer(trimws(readLines(rc, warn = FALSE)[1])))
  if (is.na(v)) NA_integer_ else v
}

local_log_lines <- function(rec) {
  logf <- rec$log_out %||% ""
  if (length(logf) != 1 || !nzchar(logf) || !file.exists(logf)) return(character(0))
  tryCatch(readLines(logf, warn = FALSE), error = function(e) character(0))
}

local_end_epoch <- function(rec) {
  lines <- local_log_lines(rec)
  if (length(lines)) {
    hit <- grep("^DIANN_GUI_END_EPOCH ", lines, value = TRUE)
    if (length(hit)) {
      v <- suppressWarnings(as.numeric(sub("^DIANN_GUI_END_EPOCH ", "", hit[1])))
      if (!is.na(v)) return(v)
    }
  }
  rc <- local_rc_path(rec)
  if (nzchar(rc) && file.exists(rc)) {
    mt <- as.numeric(file.info(rc)$mtime)
    if (!is.na(mt)) return(mt)
  }
  NA_real_
}

local_start_epoch <- function(rec) {
  lines <- local_log_lines(rec)
  if (length(lines)) {
    hit <- grep("^DIANN_GUI_START_EPOCH ", lines, value = TRUE)
    if (length(hit)) {
      v <- suppressWarnings(as.numeric(sub("^DIANN_GUI_START_EPOCH ", "", hit[1])))
      if (!is.na(v)) return(v)
    }
  }
  NA_real_
}

# 作业耗时 (秒): epoch 标记 -> rc/脚本 mtime -> 运行中按 now-submitted 估算
local_elapsed_secs <- function(rec) {
  se <- local_start_epoch(rec)
  ee <- local_end_epoch(rec)
  if (!is.na(se) && !is.na(ee) && ee >= se) return(as.integer(round(ee - se)))
  if (!is.na(ee) && !is.na(rec$submitted_epoch %||% NA_real_)) {
    return(as.integer(max(0, round(ee - rec$submitted_epoch))))
  }
  if (!is.na(rec$submitted_epoch %||% NA_real_)) {
    return(as.integer(max(0, round(as.numeric(Sys.time()) - rec$submitted_epoch))))
  }
  NA_integer_
}

local_log_started <- function(rec) {
  lines <- local_log_lines(rec)
  length(lines) && any(grepl("^DIANN_GUI_START_EPOCH ", lines))
}

local_job_alive <- function(rec) {
  pid <- suppressWarnings(as.integer(rec$pid))
  if (is.na(pid) || pid <= 0) return(FALSE)
  start <- local_proc_starttime(pid)
  if (is.na(start)) return(FALSE)
  ps <- rec$pid_start
  if (is.null(ps) || length(ps) != 1 || !is.finite(ps)) ps <- NA_real_
  if (!is.na(ps) && !isTRUE(all.equal(start, as.numeric(ps)))) return(FALSE)  # PID 复用
  runner <- rec$runner %||% ""
  script <- rec$script_path %||% ""
  cmd <- local_proc_cmdline(pid)
  if (nzchar(cmd) && nzchar(runner %||% "")) {
    hit_runner <- grepl(basename(runner), cmd, fixed = TRUE)
    hit_script <- nzchar(script) && grepl(basename(script), cmd, fixed = TRUE)
    if (!hit_runner && !hit_script) return(FALSE)
  }
  TRUE
}

# 本地事实 -> 与 Slurm 同名的调度态字符串 (空 = 未知, 交给四层合成降级)
local_job_state <- function(rec) {
  if (local_marker_exists(rec, "cancelled")) return("CANCELLED")
  pid <- suppressWarnings(as.integer(rec$pid))
  if (is.na(pid) || pid <= 0) {
    age <- as.numeric(Sys.time()) - (rec$submitted_epoch %||% 0)
    return(if (is.finite(age) && age <= 3) "PENDING" else "")
  }
  if (local_job_alive(rec)) {
    return(if (local_log_started(rec)) "RUNNING" else "PENDING")
  }
  if (local_marker_exists(rec, "timeout")) return("TIMEOUT")
  rc <- local_read_rc(rec)
  if (!is.na(rc)) {
    if (rc == 124L) return("TIMEOUT")
    if (rc == 0L) return("COMPLETED")
    return("FAILED")
  }
  ""
}

# ---------- 格式化 ----------

local_fmt_hms <- function(secs) {
  if (is.null(secs) || length(secs) != 1 || is.na(secs) || !is.finite(secs)) return("Unknown")
  secs <- max(0L, as.integer(secs))
  h <- secs %/% 3600L; m <- (secs %% 3600L) %/% 60L; s <- secs %% 60L
  if (h > 0) sprintf("%d:%02d:%02d", h, m, s) else sprintf("%d:%02d", m, s)
}

local_fmt_end <- function(rec) {
  ee <- local_end_epoch(rec)
  if (is.na(ee)) return("Unknown")
  format(as.POSIXct(ee, origin = "1970-01-01", tz = ""), "%Y-%m-%dT%H:%M:%S")
}

# ---------- 快照 / 状态注入 / 历史 ----------

local_snapshot <- function(refresh = FALSE) {
  now <- as.numeric(Sys.time())
  recs <- local_jobs_load()$recs
  lines <- character(0); sacct_lines <- character(0)
  squeue_map <- list(); sacct_map <- list()
  for (rec in recs) {
    id <- as.character(rec$jobid)
    st <- local_job_state(rec)
    if (st %in% c("RUNNING", "PENDING")) {
      squeue_map[[id]] <- st
      lines <- c(lines, sprintf("%.10s|%s|%s|%s|%s", id, rec$task %||% "", st,
                                local_fmt_hms(local_elapsed_secs(rec)), "local"))
    } else if (nzchar(st)) {
      sacct_map[[id]] <- st
      sacct_lines <- c(sacct_lines, sprintf("%s|%s|%s|%s|%s", id, rec$task %||% "", st,
                                            local_fmt_hms(local_elapsed_secs(rec)),
                                            local_fmt_end(rec)))
    }
  }
  list(lines = lines, sacct_lines = sacct_lines, squeue_map = squeue_map,
       sacct_map = sacct_map, at = now, backend = "local")
}

local_status_fns <- function(snap = NULL) {
  recs <- local_jobs_load()$recs
  index <- list()
  for (r in recs) index[[as.character(r$jobid)]] <- r
  list(
    squeue_fn = function(id) {
      r <- index[[as.character(id)]]
      if (is.null(r)) return(character(0))
      st <- local_job_state(r)
      if (st %in% c("RUNNING", "PENDING")) st else character(0)
    },
    sacct_fn = function(id) {
      r <- index[[as.character(id)]]
      if (is.null(r)) return(character(0))
      st <- local_job_state(r)
      if (!st %in% c("COMPLETED", "FAILED", "CANCELLED", "TIMEOUT")) return(character(0))
      rc <- local_read_rc(r)
      paste(as.character(id), st, ifelse(is.na(rc), "", as.character(rc)),
            local_fmt_hms(local_elapsed_secs(r)), local_fmt_end(r), sep = "|")
    })
}

# 监控页历史 (最近完成的本地作业; NULL = 无记录)
local_history <- function() {
  recs <- local_jobs_load()$recs
  rows <- list()
  for (rec in recs) {
    st <- local_job_state(rec)
    if (!st %in% c("COMPLETED", "FAILED", "CANCELLED", "TIMEOUT")) next
    rows[[length(rows) + 1L]] <- data.frame(
      作业ID = as.character(rec$jobid), 作业名 = as.character(rec$task %||% ""),
      状态 = st, 运行时长 = local_fmt_hms(local_elapsed_secs(rec)),
      结束时间 = local_fmt_end(rec), stringsAsFactors = FALSE)
  }
  if (!length(rows)) return(NULL)
  do.call(rbind, rows)
}

# v1.13: 并发上限的"预计可提交时间"。运行中/启动中作业 -> eta = min(submitted_epoch
# + time_sec); 无时限 (time_sec=0/NA) 的作业无法预估 -> unknown_limit=TRUE。
# 纯函数式读取, 供提交校验与 UI 提示共用; 返回
# list(n, eta, earliest_job, unknown_limit, detail)。
local_next_slot_info <- function(now = Sys.time()) {
  recs <- local_jobs_load()$recs
  run <- Filter(function(r) local_job_state(r) %in% c("RUNNING", "PENDING"), recs)
  n <- length(run)
  if (!n) return(list(n = 0L, eta = NA_real_, earliest_job = "", unknown_limit = FALSE,
                      detail = "当前没有本地作业在运行"))
  lim <- vapply(run, function(r) {
    ts <- suppressWarnings(as.numeric(r$time_sec %||% 0))
    se <- suppressWarnings(as.numeric(r$submitted_epoch %||% NA_real_))
    if (is.na(se) || !is.finite(se) || is.na(ts) || ts <= 0) NA_real_ else se + ts
  }, numeric(1))
  unknown <- sum(is.na(lim))
  if (unknown == n) {
    return(list(n = n, eta = NA_real_, earliest_job = "", unknown_limit = TRUE,
                detail = sprintf("当前 %d 个本地作业在运行, 均未设时限, 结束时间未知", n)))
  }
  k <- which.min(replace(lim, is.na(lim), Inf))
  eta <- unname(lim[k])
  mins <- max(0, round((eta - as.numeric(now)) / 60))
  job <- tryCatch(as.character(run[[k]]$jobid), error = function(e) "")
  detail <- if (mins <= 0) {
    sprintf("最早作业 (ID %s) 已到/超过时限, 预计即将结束", job)
  } else {
    sprintf("最早作业 (ID %s) 预计 %s 前结束 (约 %d 分钟)", job,
            format(as.POSIXct(eta, origin = "1970-01-01"), "%H:%M"), mins)
  }
  if (unknown > 0) detail <- paste0(detail, sprintf("; 另有 %d 个未设时限", unknown))
  list(n = n, eta = eta, earliest_job = job, unknown_limit = FALSE, detail = detail)
}

local_running_count <- function() {
  recs <- local_jobs_load()$recs
  if (!length(recs)) return(0L)
  sum(vapply(recs, function(r) local_job_state(r) %in% c("RUNNING", "PENDING"), logical(1)))
}

# 本机资源快照 (本地模式提交前校验/提示用)
local_cpu_count <- function() {
  v <- suppressWarnings(as.integer(system("nproc", intern = TRUE)))
  if (length(v) == 1 && !is.na(v) && v > 0) v else NA_integer_
}

local_mem_available_gb <- function() {
  x <- tryCatch(suppressWarnings(readLines("/proc/meminfo", warn = FALSE)),
                error = function(e) character(0))
  line <- grep("^MemAvailable:", x, value = TRUE)
  if (!length(line)) return(NA_real_)
  kb <- suppressWarnings(as.numeric(strsplit(trimws(line[1]), "[[:space:]]+")[[1]][2]))
  if (is.na(kb)) NA_real_ else kb / 1024^2
}

# ---------- 运行器 / 提交 / 取消 ----------

local_runner_path <- function() {
  p <- system.file("scripts", "local_runner.sh", package = "diann.gui")
  if (nzchar(p) && file.exists(p)) return(p)
  for (cand in c(file.path(getwd(), "inst", "scripts", "local_runner.sh"),
                 file.path("inst", "scripts", "local_runner.sh"))) {
    if (file.exists(cand)) return(normalizePath(cand, mustWork = FALSE))
  }
  ""
}

local_spawn_log <- function(job_id) file.path(local_state_dir(), sprintf("local_%d.spawn.log", as.integer(job_id)))
local_pidfile <- function(job_id) file.path(local_state_dir(), sprintf("local_%d.pid", as.integer(job_id)))

# 清理 30 天前的 pid/spawn 日志 (状态文件本身滚动保留 300 条)
local_cleanup <- function(days = 30) {
  d <- local_state_dir()
  fs <- list.files(d, pattern = "^local_[0-9]+\\.(pid|spawn\\.log)$", full.names = TRUE)
  if (!length(fs)) return(invisible(0L))
  cutoff <- as.numeric(Sys.time()) - days * 86400
  mt <- suppressWarnings(as.numeric(file.info(fs)$mtime))
  old <- fs[!is.na(mt) & mt < cutoff]
  if (length(old)) try(unlink(old), silent = TRUE)
  invisible(length(old))
}

# 提交本地作业: 分配整数 ID -> 写记录 -> setsid+nohup 派生运行器 -> 等 pidfile。
# 返回与 backend_submit() 同构的 list; 失败时回滚记录, 永不抛错。
local_submit <- function(p, script_path) {
  backend <- "local"
  fail <- function(msg) list(ok = FALSE, backend = backend, job_id = NA_character_,
                             message = msg, log_out = "", log_err = "", pid = NA_integer_)
  out_dir <- as.character(p$out_dir %||% "")[1]
  if (is.na(out_dir) || !nzchar(out_dir)) return(fail("本地模式提交失败: 输出目录为空"))
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  if (!dir.exists(out_dir)) return(fail(sprintf("本地模式提交失败: 输出目录不存在且无法创建: %s", out_dir)))
  if (length(script_path) != 1 || !nzchar(script_path) || !file.exists(script_path)) {
    return(fail(sprintf("本地模式提交失败: 作业脚本不存在: %s", script_path)))
  }
  runner <- local_runner_path()
  if (!nzchar(runner) || !file.exists(runner)) {
    return(fail("本地模式提交失败: 找不到 local_runner.sh (包安装不完整?), 请重新安装 diann.gui"))
  }
  backend_available_check <- backend_available("local")
  if (!isTRUE(backend_available_check$ok)) {
    return(fail(sprintf("本地模式提交失败: 缺少本地执行所需工具 (%s)", backend_available_check$detail)))
  }
  job_id <- local_seq_next()
  if (is.na(job_id)) return(fail("本地模式提交失败: 无法分配本地作业 ID (状态目录不可写?)"))
  lp <- backend_log_paths(job_id, out_dir, "local", script_path)
  nice <- suppressWarnings(as.integer(cfg_get("LOCAL_NICE") %||% 10L))
  if (is.na(nice)) nice <- 10L
  grace <- suppressWarnings(as.integer(cfg_get("LOCAL_TIMEOUT_GRACE") %||% 30L))
  if (is.na(grace)) grace <- 30L
  time_sec <- 0L
  if (!is.null(p$time_h) && length(p$time_h) == 1 && !is.na(p$time_h) && is.finite(p$time_h)) {
    time_sec <- max(1L, as.integer(ceiling(3600 * p$time_h)))
  }
  rec <- list(
    jobid = as.integer(job_id), task = as.character(p$job_name %||% "")[1] %||% "",
    out_dir = out_dir, script_path = script_path,
    log_out = lp$out, log_err = lp$err, rc_path = lp$rc,
    pid = NA_integer_, pid_start = NA_real_, runner = runner,
    submitted = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    submitted_epoch = as.numeric(Sys.time()),
    time_sec = time_sec, backend = "local")
  if (!isTRUE(local_jobs_add(rec))) {
    return(fail(sprintf("本地模式提交失败: 无法写入本地作业状态文件 (%s)", local_jobs_file())))
  }
  pidfile <- local_pidfile(job_id)
  spawn_log <- local_spawn_log(job_id)
  bash <- Sys.which("bash")
  if (!nzchar(bash)) bash <- "/bin/bash"
  args <- c(shQuote(runner), shQuote(script_path), shQuote(lp$out), shQuote(lp$err),
            shQuote(lp$rc), shQuote(pidfile),
            as.character(time_sec), as.character(grace), as.character(nice))
  setsid <- Sys.which("setsid")
  prefix <- if (nzchar(setsid)) sprintf("%s ", shQuote(setsid)) else ""
  cmd <- sprintf("%snohup %s %s >> %s 2>&1 < /dev/null &",
                 prefix, shQuote(bash), paste(args, collapse = " "), shQuote(spawn_log))
  spawn_err <- NULL
  tryCatch(system(cmd, wait = TRUE), error = function(e) spawn_err <<- conditionMessage(e))
  if (!is.null(spawn_err)) {
    local_jobs_remove(job_id)
    return(fail(sprintf("本地模式提交失败: 无法派生本地运行器 (%s)", spawn_err)))
  }
  pid <- NA_integer_
  for (i in seq_len(30)) {
    if (file.exists(pidfile)) {
      v <- suppressWarnings(as.integer(trimws(readLines(pidfile, warn = FALSE)[1])))
      if (!is.na(v) && v > 0) { pid <- v; break }
    }
    Sys.sleep(0.1)
  }
  if (is.na(pid)) {
    local_jobs_remove(job_id)
    detail <- if (file.exists(spawn_log)) {
      paste(utils::tail(readLines(spawn_log, warn = FALSE), 3), collapse = " | ")
    } else ""
    return(fail(paste0("本地模式提交失败: 运行器未在 3 秒内启动 (检查状态目录权限/setsid/nohup)",
                       if (nzchar(detail)) paste0("; 启动日志: ", detail) else "")))
  }
  rec$pid <- as.integer(pid)
  rec$pid_start <- local_proc_starttime(pid)
  local_jobs_update(rec)
  try(local_cleanup(), silent = TRUE)
  list(ok = TRUE, backend = backend, job_id = as.character(job_id),
       message = sprintf("已启动本地作业 %d (pid %d)", job_id, pid),
       log_out = lp$out, log_err = lp$err, pid = as.integer(pid))
}

# 取消本地作业: 同 UID 校验 -> .cancelled 标记 (状态立即显示已取消) -> 整组 TERM -> KILL
local_cancel <- function(job_id) {
  rec <- local_jobs_find(job_id)
  if (is.null(rec)) return(list(ok = FALSE, message = sprintf("未找到本地作业 %s 的记录", job_id)))
  if (!local_job_alive(rec)) return(list(ok = TRUE, message = sprintf("本地作业 %s 已结束", job_id)))
  uid <- local_proc_uid(rec$pid)
  cur_uid <- local_current_uid()
  if (!is.na(uid) && !is.na(cur_uid) && uid != cur_uid) {
    return(list(ok = FALSE, message = "无权取消其他用户的本地进程"))
  }
  mk <- local_marker(rec, "cancelled")
  if (nzchar(mk)) try(file.create(mk), silent = TRUE)
  pid <- suppressWarnings(as.integer(rec$pid))
  pgid <- local_proc_pgid(pid)
  if (!is.na(pgid) && pgid == pid) {
    try(system(sprintf("kill -TERM -- -%d 2>/dev/null", pid)), silent = TRUE)
  } else {
    local_kill_tree(pid, "TERM")
  }
  for (i in seq_len(10)) {
    if (!local_job_alive(rec)) return(list(ok = TRUE, message = sprintf("已取消本地作业 %s", job_id)))
    Sys.sleep(0.5)
  }
  if (!is.na(pgid) && pgid == pid) {
    try(system(sprintf("kill -KILL -- -%d 2>/dev/null", pid)), silent = TRUE)
  } else {
    local_kill_tree(pid, "KILL")
  }
  list(ok = TRUE, message = sprintf("本地作业 %s 已强制取消", job_id))
}
