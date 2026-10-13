# ============================================================
# 作业完成邮件通知 - 共享逻辑
# 被 app.R/server 与 watch_daemon() 共用。邮件相关值 (MAIL_PY/MAIL_CONF/MAIL_PYTHON/
# MAIL_ENABLED/NOTIFY_*) 由 R/config.R 的 diann_load_config() 装入包配置环境 .cfg,
# 本模块函数经 cfg_get() 读取。MAIL_CONF 不存在时 MAIL_ENABLED=FALSE,
# 整个邮件功能静默停用。
# 机制: 提交时把待通知作业写入状态文件 (RDS); watcher 每 60s 查 squeue,
#       作业离开队列后解析 slurm-<id>.out 的退出码并调用 mail_notify.py 发送
#       (邮件从可访问 SMTP 服务器的节点发出; 计算节点常无出网, 不依赖 Slurm --mail-user)。
# 并发约定: 状态文件的读-改-写必须持 mkdir 互斥锁 (worker 与 watcher 两个进程),
#           锁目录 120s 未更新视为遗留锁强行接管; saveRDS 走临时文件 + rename 原子替换。
# ============================================================


# 发送失败重试: 最多 3 次, 间隔 = RETRY_WAIT * 已尝试次数 (5/10/15 分钟递增)
DIANN_NOTIFY_MAX_ATTEMPTS <- 3L
DIANN_NOTIFY_RETRY_WAIT <- 300

notify_lock_acquire <- function(timeout = 10) {
  t0 <- as.numeric(Sys.time())
  repeat {
    if (dir.create(cfg_get("NOTIFY_LOCK_DIR"), showWarnings = FALSE)) {
      try(writeLines(as.character(as.numeric(Sys.time())), file.path(cfg_get("NOTIFY_LOCK_DIR"), "ts")), silent = TRUE)
      return(TRUE)
    }
    ts <- NA_real_
    tsf <- file.path(cfg_get("NOTIFY_LOCK_DIR"), "ts")
    if (file.exists(tsf)) ts <- suppressWarnings(as.numeric(readLines(tsf, warn = FALSE)[1]))
    if (is.na(ts)) {
      mt <- file.info(cfg_get("NOTIFY_LOCK_DIR"))$mtime
      if (!is.na(mt)) ts <- as.numeric(mt)
    }
    if (!is.na(ts) && as.numeric(Sys.time()) - ts > 120) {
      unlink(cfg_get("NOTIFY_LOCK_DIR"), recursive = TRUE, force = TRUE)
      next
    }
    if (as.numeric(Sys.time()) - t0 > timeout) return(FALSE)
    Sys.sleep(0.2)
  }
}
notify_lock_release <- function() invisible(try(unlink(cfg_get("NOTIFY_LOCK_DIR"), recursive = TRUE, force = TRUE), silent = TRUE))

diann_notify_load <- function() {
  if (!file.exists(cfg_get("NOTIFY_STATE"))) return(list(recs = list()))
  tryCatch(readRDS(cfg_get("NOTIFY_STATE")), error = function(e) list(recs = list()))
}

diann_notify_save <- function(state) {
  tmp <- sprintf("%s.tmp.%d", cfg_get("NOTIFY_STATE"), Sys.getpid())
  ok <- tryCatch({ saveRDS(state, tmp); file.rename(tmp, cfg_get("NOTIFY_STATE")) },
                 error = function(e) FALSE, warning = function(w) FALSE)
  if (!identical(ok, TRUE)) try(unlink(tmp), silent = TRUE)
  invisible(ok)
}

diann_notify_add <- function(rec) {
  if (!isTRUE(cfg_get("MAIL_ENABLED"))) return(invisible(FALSE))
  if (!notify_lock_acquire()) return(invisible(FALSE))
  on.exit(notify_lock_release(), add = TRUE)
  state <- diann_notify_load()
  rec$done <- FALSE; rec$attempts <- 0L; rec$last_result <- ""; rec$last_try <- 0
  rec$submitted <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  state$recs <- head(c(list(rec), state$recs), 100)  # 只保留最近 100 条
  diann_notify_save(state)
  invisible(TRUE)
}

# 耗时: 优先用作业日志里的 epoch 时间戳 (v1.4 起模板自带), 兜底用记账库 Elapsed (2026-09-21 起记账开启)
diann_notify_elapsed <- function(logf, jobid) {
  ep <- NA_integer_
  if (file.exists(logf)) {
    txt <- tryCatch(readLines(logf, warn = FALSE), error = function(e) character(0))
    se <- grep("^DIANN_GUI_START_EPOCH ", txt, value = TRUE)
    ee <- grep("^DIANN_GUI_END_EPOCH ", txt, value = TRUE)
    if (length(se) && length(ee)) {
      s <- suppressWarnings(as.numeric(sub("^DIANN_GUI_START_EPOCH ", "", se[1])))
      e <- suppressWarnings(as.numeric(sub("^DIANN_GUI_END_EPOCH ", "", ee[1])))
      if (!is.na(s) && !is.na(e) && e >= s) ep <- as.integer(round(e - s))
    }
  }
  if (!is.na(ep)) return(ep)
  out <- suppressWarnings(system(sprintf("sacct -j %d -X -n -o Elapsed 2>/dev/null", as.integer(jobid)), intern = TRUE))
  s <- trimws(out[1])
  if (length(s) && nzchar(s) && !grepl("unknown", s, ignore.case = TRUE)) {
    d <- 0L
    if (grepl("-", s)) { d <- suppressWarnings(as.integer(sub("-.*", "", s))); s <- sub("^[0-9]+-", "", s) }
    p <- suppressWarnings(as.integer(strsplit(s, ":", fixed = TRUE)[[1]]))
    if (length(p) == 3 && !any(is.na(p))) return(as.integer(d * 86400 + p[1] * 3600 + p[2] * 60 + p[3]))
    if (length(p) == 2 && !any(is.na(p))) return(as.integer(d * 86400 + p[1] * 60 + p[2]))
  }
  NA_integer_
}

# ---------- 作业状态四层判定 (v1.8) ----------
# 层1 调度态 (squeue/sacct) → 层2 程序退出码 (rcfile → 日志解析回退) → 层3 产物验证 → 层4 合成。
# app.R (任务队列页实时显示) 与 watcher (完成邮件) 共用; sacct_fn/squeue_fn 可注入, 便于离线测试。
# 合成规则 (label / reason):
#   作业在队列                    → 运行中 / 排队中
#   COMPLETED + 产物为新          → 成功
#   COMPLETED + 无新产物          → 待核实 (调度完成但未见本次产物)
#   FAILED   + 产物为新 + rc∈{0,132,134,139}
#                                 → 待核实 (疑容器卸载 SIGILL/SIGABRT/SIGSEGV: rc 是 apptainer
#                                   层退出码, 程序真实成败不可知, 但主报告确为本次新写)
#   FAILED / OOM / NODE_FAIL ...  → 失败 (附退出码)
#   TIMEOUT                       → 超时    CANCELLED → 已取消
#   sacct 无记录                  → 退化为 rc+产物合成, reason 注明 sacct 不可用
#   全部来源缺失                  → 未知 (附原因)
# matrices 等派生产物不参与判定 (GUI 不构造其文件名), 仅主报告 out_file 计入产物层。
DIANN_TEARDOWN_RCS <- c(132L, 134L, 139L)  # 128+SIGILL/SIGABRT/SIGSEGV

# 20.11 的 sacct 终态可能带 "CANCELLED by 1001" 尾巴, 统一剥掉
slurm_state_normalize <- function(s) {
  toupper(sub("\\s+by[[:space:]].*$", "", trimws(as.character(s)), ignore.case = TRUE))
}

diann_job_status <- function(jobid, out_dir, out_file, script_path = "",
                             submitted = "", sacct_fn = NULL, squeue_fn = NULL, now = NA_real_) {
  jobid_i <- suppressWarnings(as.integer(jobid))
  if (is.na(now)) now <- as.numeric(Sys.time())
  if (is.null(squeue_fn)) {
    squeue_fn <- function(id) suppressWarnings(
      system(sprintf("squeue -h -j %s -o '%%T' 2>/dev/null", as.integer(id)), intern = TRUE))
  }
  if (is.null(sacct_fn)) {
    sacct_fn <- function(id) suppressWarnings(
      system(sprintf("sacct -j %d -X -n --parsable2 -o jobid,state,exitcode,elapsed,end 2>/dev/null",
                     as.integer(id)), intern = TRUE))
  }

  # ---- 层 1: 调度态 ----
  q <- tryCatch(squeue_fn(jobid_i), error = function(e) character(0))
  q <- q[nzchar(trimws(as.character(q)))]
  sacct_raw <- tryCatch(sacct_fn(jobid_i), error = function(e) character(0))
  sacct_raw <- sacct_raw[nzchar(trimws(as.character(sacct_raw)))]
  state <- NA_character_
  if (length(sacct_raw)) {
    f <- strsplit(trimws(sacct_raw[1]), "|", fixed = TRUE)[[1]]
    if (length(f) >= 2 && nzchar(trimws(f[2]))) state <- slurm_state_normalize(f[2])
  }

  # ---- 层 2: 程序退出码 (rcfile 优先, 回退日志解析) ----
  rc <- NA_integer_
  rcf <- if (length(script_path) == 1 && nzchar(script_path)) sub("\\.sh$", ".rc", script_path) else ""
  if (nzchar(rcf) && file.exists(rcf)) {
    v <- suppressWarnings(as.integer(trimws(readLines(rcf, warn = FALSE)[1])))
    if (!is.na(v)) rc <- v
  }
  logf <- if (length(out_dir) == 1 && nzchar(out_dir) && !is.na(jobid_i)) {
    file.path(out_dir, sprintf("slurm-%d.out", jobid_i))
  } else ""
  if (is.na(rc) && nzchar(logf) && file.exists(logf)) {
    txt <- paste(utils::tail(readLines(logf, warn = FALSE), 6), collapse = "\n")
    m <- regmatches(txt, regexpr("exit code: -?[0-9]+", txt))
    if (length(m)) rc <- as.integer(sub("exit code: ", "", m))
  }

  # ---- 层 3: 产物验证 (仅主报告: 存在 + 非空 + 晚于本次开始) ----
  start_epoch <- NA_real_
  if (nzchar(logf) && file.exists(logf)) {
    se <- grep("^DIANN_GUI_START_EPOCH ", readLines(logf, warn = FALSE), value = TRUE)
    if (length(se)) start_epoch <- suppressWarnings(as.numeric(sub("^DIANN_GUI_START_EPOCH ", "", se[1])))
  }
  if (is.na(start_epoch) && nzchar(submitted)) {
    st <- suppressWarnings(as.POSIXct(submitted, format = "%Y-%m-%d %H:%M:%S"))
    if (!is.na(st)) start_epoch <- as.numeric(st)  # 提交前就存在的产物一律视为遗留
  }
  art_new <- NA  # NA = 产物层不可核验 (未提供主报告路径, 如 usage_report 按目录聚合时)
  if (length(out_file) == 1 && nzchar(out_file)) {
    # 提供了路径: 文件不存在/为空 = FALSE (无本次有效产物), 存在且非空 = 新旧判定
    art_new <- FALSE
    if (file.exists(out_file)) {
      fi <- file.info(out_file)
      if (!is.na(fi$size) && fi$size > 0) {
        art_new <- if (!is.na(start_epoch)) fi$mtime > (start_epoch - 5) else TRUE
      }
    }
  }
  art_ok <- isTRUE(art_new)
  art_bad <- isFALSE(art_new)

  # ---- 层 4: 合成 ----
  teardown <- !is.na(rc) && rc %in% DIANN_TEARDOWN_RCS
  if (length(q)) {
    qs <- toupper(trimws(q[1]))
    label <- switch(qs, RUNNING = "运行中", PENDING = "排队中", qs)
    reason <- "作业仍在队列中"
  } else if (is.na(state)) {
    if (art_ok && !is.na(rc) && rc == 0) {
      label <- "成功"; reason <- "程序退出 0 且产物为新 (sacct 不可用, 未核对调度终态)"
    } else if (art_ok && teardown) {
      label <- "待核实"
      reason <- sprintf("产物已生成但程序层退出 %s (疑容器卸载异常; sacct 不可用)", rc)
    } else if (!is.na(rc) && rc != 0) {
      label <- "失败"; reason <- sprintf("程序退出码 %d (sacct 不可用)", rc)
    } else if (art_ok) {
      label <- "待核实"; reason <- "发现新产物但退出码未知 (sacct 不可用)"
    } else {
      label <- "未知"; reason <- "sacct 无记录, 日志/产物均不足以判定"
    }
  } else if (state == "COMPLETED") {
    if (art_ok) { label <- "成功"; reason <- "调度完成且产物为新" }
    else if (art_bad) { label <- "待核实"; reason <- "调度完成但未见本次产物 (检查输出路径或目录清理)" }
    else { label <- "成功"; reason <- "调度完成 (产物未核验)" }
  } else if (state %in% c("FAILED", "OUT_OF_MEMORY", "NODE_FAIL", "BOOT_FAIL", "PREEMPTED", "DEADLINE")) {
    if (art_ok && (teardown || (!is.na(rc) && rc == 0))) {
      label <- "待核实"
      reason <- sprintf("调度报告 %s 但主报告为本次新写 (程序层退出 %s, 疑容器卸载异常), 请核对产物完整性", state, rc)
    } else {
      label <- "失败"
      reason <- sprintf("调度状态 %s, 程序退出码 %s", state,
                        if (!is.na(rc)) as.character(rc) else "未知(见日志)")
    }
  } else if (state == "TIMEOUT") {
    label <- "超时"
    reason <- if (art_ok) "作业超时被终止, 但存在新产物, 请核对" else "作业超时被终止, 未见新产物"
  } else if (state == "CANCELLED") {
    label <- "已取消"; reason <- "作业被取消"
  } else if (state %in% c("RUNNING", "PENDING")) {
    label <- "未知"; reason <- "sacct 记录与队列不一致 (记账滞后), 稍后刷新"
  } else {
    if (art_ok && !is.na(rc) && rc == 0) {
      label <- "成功"; reason <- sprintf("调度状态 %s, 程序退出 0 且产物为新", state)
    } else {
      label <- "待核实"
      reason <- sprintf("调度状态 %s, 程序退出码 %s", state,
                        if (!is.na(rc)) as.character(rc) else "未知")
    }
  }
  list(jobid = jobid_i, state = if (is.na(state)) "" else state, rc = rc,
       artifact_new = art_new, label = label, reason = reason)
}

# 一轮发送检查。三段式: ① 持锁扫描并认领 (置 last_try, 防多实例重复发送)
# ② 无锁发送 (慢操作, 中途被杀则记录仍待发, 下轮重试) ③ 持锁按 jobid+submitted 合并结果
diann_notify_tick <- function() {
  if (!isTRUE(cfg_get("MAIL_ENABLED"))) return(invisible(FALSE))
  # ---- 阶段 1: 认领 ----
  if (!notify_lock_acquire()) return(invisible(FALSE))
  on.exit(notify_lock_release(), add = TRUE)  # 异常兜底 (重复释放无害)
  state <- diann_notify_load()
  now <- as.numeric(Sys.time())
  cand <- list()
  if (length(state$recs)) for (i in seq_along(state$recs)) {
    r <- state$recs[[i]]
    if (isTRUE(r$done)) next
    att <- if (is.null(r$attempts)) 0L else as.integer(r$attempts)
    lt <- if (is.null(r$last_try)) 0 else as.numeric(r$last_try)
    if (now - lt < DIANN_NOTIFY_RETRY_WAIT * max(att, 1L)) next  # 失败重试间隔未到
    q <- suppressWarnings(system(sprintf("squeue -h -j %s 2>/dev/null", r$jobid), intern = TRUE))
    if (length(q) > 0) next  # 仍在排队/运行
    state$recs[[i]]$last_try <- now
    cand[[length(cand) + 1L]] <- list(rec = state$recs[[i]])
  }
  if (length(cand)) diann_notify_save(state)
  notify_lock_release()
  if (!length(cand)) return(invisible(FALSE))
  # ---- 阶段 2: 发送 ----
  for (k in seq_along(cand)) {
    r <- cand[[k]]$rec
    logf <- file.path(r$out_dir, sprintf("slurm-%d.out", as.integer(r$jobid)))
    st <- tryCatch(
      diann_job_status(r$jobid, r$out_dir, r$out_file,
                       script_path = r$script_path, submitted = r$submitted),
      error = function(e) NULL)
    rc <- if (is.null(st)) NA_integer_ else st$rc
    elapsed <- diann_notify_elapsed(logf, r$jobid)
    args <- c(cfg_get("MAIL_PY"), "--to", shQuote(r$to), "--job-id", as.character(r$jobid),
              "--task", shQuote(r$task), "--out-dir", shQuote(r$out_dir),
              "--out-file", shQuote(r$out_file), "--sif", shQuote(r$sif),
              "--script", shQuote(r$script_path), "--desc-file", shQuote(r$desc_file),
              "--config", shQuote(cfg_get("MAIL_CONF")), "--strict")
    if (!is.na(rc)) args <- c(args, "--rc", as.character(rc))
    if (!is.null(st)) {
      if (nzchar(st$state)) args <- c(args, "--state", shQuote(st$state))
      if (nzchar(st$label)) {
        args <- c(args, "--status-label", shQuote(st$label), "--status-reason", shQuote(st$reason))
      }
    }
    if (!is.na(elapsed)) args <- c(args, "--elapsed", as.integer(elapsed))
    out <- tryCatch(
      suppressWarnings(system2(cfg_get("MAIL_PYTHON"), args, stdout = TRUE, stderr = TRUE, timeout = 90)),
      error = function(e) structure(paste0("ERROR: ", conditionMessage(e)), status = -1L))
    status <- attr(out, "status"); if (is.null(status)) status <- 0L
    cand[[k]]$result <- paste(out, collapse = " ")
    cand[[k]]$status <- as.integer(status)
    cand[[k]]$rc <- rc
    cand[[k]]$st <- st
  }
  # ---- 阶段 3: 合并 ----
  if (!notify_lock_acquire()) return(invisible(TRUE))
  on.exit(notify_lock_release(), add = TRUE)
  state <- diann_notify_load()
  if (length(state$recs)) for (k in seq_along(cand)) {
    r <- cand[[k]]$rec
    idx <- which(vapply(state$recs, function(x) {
      identical(as.character(x$jobid), as.character(r$jobid)) && identical(x$submitted, r$submitted)
    }, logical(1)))
    if (!length(idx)) next
    i <- idx[1]
    att <- if (is.null(state$recs[[i]]$attempts)) 0L else as.integer(state$recs[[i]]$attempts)
    state$recs[[i]]$attempts <- att + 1L
    state$recs[[i]]$last_result <- paste0(format(Sys.time(), "%m-%d %H:%M:%S "), cand[[k]]$result)
    state$recs[[i]]$done <- (cand[[k]]$status == 0L) || (att + 1L >= DIANN_NOTIFY_MAX_ATTEMPTS)
    # 四层状态判定结果落库 (旧记录无这些字段, GUI 端按 NULL 兼容)
    if (!is.null(cand[[k]]$st)) {
      state$recs[[i]]$state <- cand[[k]]$st$state
      state$recs[[i]]$rc <- cand[[k]]$st$rc
      state$recs[[i]]$status_label <- cand[[k]]$st$label
      state$recs[[i]]$status_reason <- cand[[k]]$st$reason
    }
    state$recs[[i]]$status_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  }
  diann_notify_save(state)
  invisible(TRUE)
}
