# ============================================================
# 作业完成邮件通知 - 共享逻辑
# 被 app.R/server 与 watch_daemon() 共用。邮件相关值 (MAIL_PY/MAIL_CONF/MAIL_PYTHON/
# MAIL_ENABLED/NOTIFY_*) 由 R/config.R 的 diann_load_config() 装入包配置环境 .cfg,
# 本模块函数经 cfg_get() 读取。MAIL_CONF 不存在或缺 python3 时 MAIL_ENABLED=FALSE,
# 邮件功能停用; v1.14.1 起未启用的原因经 mail_gate_info() 在 提交校验/提交后通知/
# 启动控制台/doctor 四处显式提示, 不再静默。
# 机制: 提交时把待通知作业写入状态文件 (RDS); watcher 每 60s 查 squeue,
#       作业离开队列后解析 slurm-<id>.out 的退出码并调用 mail_notify.py 发送
#       (邮件从可访问 SMTP 服务器的节点发出; 计算节点常无出网, 不依赖 Slurm --mail-user)。
# 并发约定: 状态文件的读-改-写必须持 mkdir 互斥锁 (worker 与 watcher 两个进程),
#           锁目录 120s 未更新视为遗留锁强行接管; saveRDS 走临时文件 + rename 原子替换。
# ============================================================


# 发送失败重试: 最多 3 次, 间隔 = RETRY_WAIT * 已尝试次数 (5/10/15 分钟递增)
DIANN_NOTIFY_MAX_ATTEMPTS <- 3L
DIANN_NOTIFY_RETRY_WAIT <- 300

# "未知"状态不算最终结果: sacct 记账滞后 (刚出队) 或产物尚未落盘时先等几轮再发信,
# 否则用户会收到"状态未知"的完成邮件且记录被置 done, 不再重试 (四层状态形同虚设)。
notify_defer_unknown <- function(st, waits, max_wait = 3L) {
  !is.null(st) && identical(st$label, "未知") && as.integer(waits) < as.integer(max_wait)
}

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

# 拿不到锁时把待通知记录落到 sidecar 目录, 由下一轮 tick 补写 (不静默丢邮件)
notify_pending_dir <- function() paste0(cfg_get("NOTIFY_STATE"), ".pending")
notify_pending_put <- function(rec) {
  d <- notify_pending_dir()
  if (!dir.exists(d) && !dir.create(d, showWarnings = FALSE, recursive = TRUE)) return(invisible(FALSE))
  f <- file.path(d, sprintf("%d_%s.rds", Sys.getpid(), format(Sys.time(), "%Y%m%d%H%M%OS6")))
  ok <- tryCatch({ saveRDS(rec, f); TRUE }, error = function(e) FALSE)
  invisible(isTRUE(ok))
}
notify_pending_drain <- function() {
  d <- notify_pending_dir()
  if (!dir.exists(d)) return(list())
  files <- list.files(d, pattern = "\\.rds$", full.names = TRUE)
  out <- list()
  for (f in files) {
    r <- tryCatch(readRDS(f), error = function(e) NULL)
    if (is.list(r) && !is.null(r$jobid)) out[[length(out) + 1L]] <- r
    try(unlink(f), silent = TRUE)
  }
  out
}

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

# ---------- 邮件门控信息 (v1.14.1) ----------
# MAIL_ENABLED (config.R) = MAIL_PYTHON 非空 && MAIL_CONF 存在; 停用时整个链路
# (diann_notify_add / ensure_diann_watcher) 直接 return。历史上只有提交校验面板
# 一行小字且只检查配置文件存在, 缺 python3 (WSL2 常见) 时填写邮箱零提示零发送。
# 本函数是门控的单一事实来源, 四个消费方共用同一文案:
#   server 提交校验 / 提交成功后通知 / run_app 启动控制台 / doctor。
mail_gate_info <- function() {
  conf <- as.character(cfg_get("MAIL_CONF") %||% "")
  py <- as.character(cfg_get("MAIL_PYTHON") %||% "")
  has_conf <- nzchar(conf) && file.exists(conf)
  has_python <- nzchar(py)
  enabled <- has_python && has_conf && isTRUE(cfg_get("MAIL_ENABLED"))
  info <- list(enabled = enabled, has_conf = has_conf, has_python = has_python,
               conf_path = conf, reason = "", hint = "")
  if (enabled) return(info)
  if (!has_conf) {
    ex <- system.file("config", "mail_config.example.txt", package = "diann.gui")
    info$reason <- sprintf("未找到邮件配置 %s", conf)
    info$hint <- sprintf(paste0("在 R 里执行 file.copy('%s', '%s') 并填写 smtp_host/smtp_user/smtp_pass",
                                " (终端: cp <示例> %s && chmod 600 %s) 后重启应用"),
                         ex, conf, conf, conf)
  } else if (!has_python) {
    info$reason <- sprintf("未找到 python3 (发送脚本 mail_notify.py 依赖), 配置文件 %s 已就绪", conf)
    info$hint <- "安装 python3 (Ubuntu/WSL2: sudo apt install python3), 或在 config.R 设 MAIL_PYTHON 指向可用解释器"
  } else {
    info$reason <- "MAIL_ENABLED 为 FALSE (配置在启动后未重新加载)"
    info$hint <- "重新运行 diann.gui::diann_load_config() 并重启应用"
  }
  info
}

diann_notify_add <- function(rec) {
  if (!isTRUE(cfg_get("MAIL_ENABLED"))) return(invisible(FALSE))
  # v1.12: 记录后端与日志路径, watcher 据此选择状态/耗时来源 (旧记录默认 slurm)
  rbk <- rec$backend
  if (is.null(rbk) || length(rbk) != 1 || is.na(rbk) || !nzchar(as.character(rbk))) rbk <- exec_backend()
  rec$backend <- as.character(rbk)[1]
  if (is.null(rec$log_out) || length(rec$log_out) != 1 || is.na(rec$log_out)) rec$log_out <- ""
  rec$done <- FALSE; rec$attempts <- 0L; rec$last_result <- ""; rec$last_try <- 0
  rec$submitted <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  if (!notify_lock_acquire()) {
    # 锁被 watcher 长时间持有 (大量待处理记录) 时不再丢记录: 落 sidecar, 下轮补写
    notify_pending_put(rec)
    return(invisible(FALSE))
  }
  on.exit(notify_lock_release(), add = TRUE)
  state <- diann_notify_load()
  state$recs <- head(c(list(rec), state$recs), 100)  # 只保留最近 100 条
  diann_notify_save(state)
  invisible(TRUE)
}

# 耗时: 优先用作业日志里的 epoch 时间戳 (v1.4 起模板自带), 兜底用记账库 Elapsed
# v1.12: backend 参数化——local / 无 accounting 场景不再调用 sacct (命令缺失时
# R 的 capture-output system() 会抛错, 而不是返回空)。
diann_notify_elapsed <- function(logf, jobid = NULL, backend = "slurm") {
  ep <- NA_integer_
  if (length(logf) == 1 && !is.na(logf) && nzchar(logf) && file.exists(logf)) {
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
  if (!identical(backend, "slurm")) return(NA_integer_)  # local: 不查 sacct
  id <- suppressWarnings(as.integer(jobid))
  if (is.na(id)) return(NA_integer_)
  out <- tryCatch(
    suppressWarnings(system(sprintf("sacct -j %d -X -n -o Elapsed 2>/dev/null", id), intern = TRUE)),
    error = function(e) character(0))
  if (!length(out)) return(NA_integer_)
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
                             submitted = "", sacct_fn = NULL, squeue_fn = NULL, now = NA_real_,
                             log_path = NULL) {
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
  # 日志路径: v1.12 起由调用方经 backend_log_paths() 传入 (slurm-<id>.out /
  # local-<id>.out); 未传时保持 v1.11 的 slurm 默认 (旧记录/离线测试兼容)。
  logf <- if (length(log_path) == 1 && !is.na(log_path) && nzchar(log_path)) {
    log_path
  } else if (length(out_dir) == 1 && nzchar(out_dir) && !is.na(jobid_i)) {
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
diann_notify_tick <- function(snapshot = NULL) {
  if (!isTRUE(cfg_get("MAIL_ENABLED"))) return(invisible(FALSE))
  # 锁外先取一次队列快照 (slurm: 一次 squeue -u; local: 只读本地状态文件),
  # 避免持锁期间为每条记录起子进程
  snap <- if (!is.null(snapshot)) snapshot else tryCatch(backend_snapshot(), error = function(e) NULL)
  qmap <- if (is.null(snap)) list() else snap$squeue_map
  # ---- 阶段 1: 认领 ----
  if (!notify_lock_acquire()) return(invisible(FALSE))
  on.exit(notify_lock_release(), add = TRUE)  # 异常兜底 (重复释放无害)
  state <- diann_notify_load()
  pend <- notify_pending_drain()
  if (length(pend)) state$recs <- head(c(pend, state$recs), 100)
  now <- as.numeric(Sys.time())
  cand <- list()
  if (length(state$recs)) for (i in seq_along(state$recs)) {
    r <- state$recs[[i]]
    if (isTRUE(r$done)) next
    att <- if (is.null(r$attempts)) 0L else as.integer(r$attempts)
    lt <- if (is.null(r$last_try)) 0 else as.numeric(r$last_try)
    if (now - lt < DIANN_NOTIFY_RETRY_WAIT * max(att, 1L)) next  # 失败重试间隔未到
    if (!is.null(qmap[[as.character(r$jobid)]])) next  # 仍在排队/运行
    state$recs[[i]]$last_try <- now
    cand[[length(cand) + 1L]] <- list(rec = state$recs[[i]])
  }
  if (length(cand) || length(pend)) diann_notify_save(state)
  notify_lock_release()
  if (!length(cand)) return(invisible(FALSE))
  # ---- 阶段 2: 发送 ----
  # 后端相关输入按记录分组懒加载: 同一状态文件里可能同时有旧 slurm 记录与
  # v1.12 的 local 记录 (换机器后共用 HOME 等), 两者分别使用各自的后端函数。
  fns_cache <- list()
  get_fns <- function(bk) {
    bk <- as.character(bk)[1]
    if (is.null(fns_cache[[bk]])) {
      fns_cache[[bk]] <<- tryCatch(backend_status_fns(bk),
                                   error = function(e) list(squeue_fn = NULL, sacct_fn = NULL))
    }
    fns_cache[[bk]]
  }
  for (k in seq_along(cand)) {
    r <- cand[[k]]$rec
    rbk <- as.character(r$backend %||% "slurm")[1]
    if (is.na(rbk) || !nzchar(rbk)) rbk <- "slurm"
    fns <- get_fns(rbk)
    lp <- tryCatch(backend_log_paths(r$jobid, r$out_dir, rbk, r$script_path),
                   error = function(e) list(out = ""))
    logf <- if (length(r$log_out) == 1 && !is.na(r$log_out) && nzchar(r$log_out)) r$log_out else lp$out
    st <- tryCatch(
      diann_job_status(r$jobid, r$out_dir, r$out_file,
                       script_path = r$script_path, submitted = r$submitted,
                       squeue_fn = fns$squeue_fn, sacct_fn = fns$sacct_fn, log_path = logf),
      error = function(e) NULL)
    rc <- if (is.null(st)) NA_integer_ else st$rc
    # 状态"未知"通常是 sacct 记账滞后 (刚出队) 或产物尚未落盘: 此时发信会把
    # "未知"当成最终结果并置 done。改为最多等 3 轮 (每轮 5 分钟) 再退化为未知。
    waits <- if (is.null(r$unknown_waits)) 0L else as.integer(r$unknown_waits)
    if (notify_defer_unknown(st, waits)) {
      cand[[k]]$deferred <- TRUE
      cand[[k]]$st <- st
      cand[[k]]$rc <- rc
      cand[[k]]$result <- "状态未知, 等待 sacct/产物就绪后再发送"
      cand[[k]]$status <- 0L
      next
    }
    elapsed <- backend_elapsed(r$jobid, logf, backend = rbk, script_path = r$script_path)
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
    if (isTRUE(cand[[k]]$deferred)) {
      uw <- if (is.null(state$recs[[i]]$unknown_waits)) 0L else as.integer(state$recs[[i]]$unknown_waits)
      state$recs[[i]]$unknown_waits <- uw + 1L
      state$recs[[i]]$last_result <- paste0(format(Sys.time(), "%m-%d %H:%M:%S "), cand[[k]]$result)
      state$recs[[i]]$status_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
      if (!is.null(cand[[k]]$st)) {
        state$recs[[i]]$state <- cand[[k]]$st$state
        state$recs[[i]]$rc <- cand[[k]]$st$rc
        state$recs[[i]]$status_label <- cand[[k]]$st$label
        state$recs[[i]]$status_reason <- cand[[k]]$st$reason
      }
      next
    }
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
