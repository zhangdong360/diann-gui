# ============================================================
# backend.R — 执行后端门面 (v1.12: Slurm 可选 / 本地单机)
#
# 背景: v1.11 及以前 GUI 把作业提交硬绑在 sbatch 上; 无 Slurm 的主机上
# system2("sbatch", ...) 会抛未捕获错误, 整个 Shiny 会话断连。v1.12 把
# "执行后端"抽象成 slurm / local 两种实现:
#   - slurm: 行为与 v1.11 完全一致 (sbatch/squeue/sacct/scancel);
#   - local: 在 GUI 所在主机用 setsid+nohup 派生本地进程, 共用同一个
#            job_body() (同一 .sif / 同一 DIA-NN 命令 / 同一 .rc 与 epoch 标记),
#            状态/日志/取消/邮件/月报复用同一套四层状态合成。
#
# 后端解析结果由 diann_load_config() 最佳努力缓存到 .cfg, run_app() 启动时
# 调 backend_startup_check() 做 fail-fast (auto 模式不允许在 HPC 登录节点静默
# 回退本地执行; legacy 中央部署不允许本地执行)。
#
# 本文件只放与后端无关的门面 + 通用解析; 本地实现见 R/backend-local.R。
# ============================================================

# ---------- 后端解析 ----------

# 请求的后端: 环境变量 > config.R > "auto"
exec_backend_request <- function() {
  env <- trimws(Sys.getenv("DIANN_GUI_EXEC_BACKEND", unset = ""))
  if (nzchar(env)) return(tolower(env))
  val <- cfg_get("EXEC_BACKEND") %||% "auto"
  tolower(trimws(as.character(val)[1] %||% "auto"))
}

# 纯函数, 全部输入可注入 (测试不依赖真实集群):
#   request           : "auto" / "slurm" / "local"
#   cmds              : 命名字符向量 name -> 绝对路径 (""=不存在); NULL 时用 Sys.which
#   slurm_traces      : 是否检测到 Slurm 痕迹; NULL 时用 cmds + /etc/slurm* 推断
#   legacy_central    : 是否 legacy 中央 shiny-server 部署; NULL 时按站点标记/配置推断
#   require_exclusive : auto+无 sbatch+有痕迹时是否拒绝本地执行 (默认 TRUE)
#   allow_shared      : legacy 部署下是否允许本地执行 (默认 FALSE)
# 返回 list(request, backend, auto, slurm_available, traces, legacy_central, warn, error)
detect_exec_backend <- function(request = NULL, cmds = NULL, slurm_traces = NULL,
                                legacy_central = NULL, require_exclusive = TRUE,
                                allow_shared = FALSE) {
  req <- tolower(trimws(as.character(request %||% exec_backend_request())[1]))
  if (!req %in% c("auto", "slurm", "local")) {
    stop(sprintf("EXEC_BACKEND 必须是 auto|slurm|local, 当前: %s", req), call. = FALSE)
  }
  if (is.null(cmds)) {
    names6 <- c("sbatch", "squeue", "sacct", "scancel", "scontrol", "sinfo")
    cmds <- stats::setNames(vapply(names6, function(x) unname(Sys.which(x)), ""), names6)
  }
  raw_cmds <- unlist(cmds, use.names = TRUE)
  cmds <- stats::setNames(as.character(raw_cmds), names(raw_cmds))
  cmd_ok <- function(nm) {
    v <- cmds[[nm]]
    !is.null(v) && length(v) == 1 && !is.na(v) && nzchar(v)
  }
  if (is.null(slurm_traces)) {
    slurm_traces <- any(vapply(c("squeue", "sacct", "scontrol", "sinfo"), cmd_ok, logical(1))) ||
      any(dir.exists(c("/etc/slurm", "/etc/slurm-llnl"))) ||
      nzchar(Sys.getenv("SLURM_CONF", unset = ""))
  }
  if (is.null(legacy_central)) {
    legacy_central <- nzchar(cfg_get("SHARED_GROUP") %||% "") ||
      (file.exists(file.path(getwd(), "app.R")) && file.exists(file.path(getwd(), "config.R")))
  }
  sbatch_ok <- cmd_ok("sbatch")
  out <- list(request = req, backend = NA_character_, auto = identical(req, "auto"),
              slurm_available = sbatch_ok, traces = isTRUE(slurm_traces),
              legacy_central = isTRUE(legacy_central),
              warn = character(0), error = character(0))
  warns <- character(0)
  errs <- character(0)

  if (identical(req, "slurm")) {
    out$backend <- "slurm"
    if (!sbatch_ok) {
      warns <- c(warns, paste0(
        "EXEC_BACKEND=slurm 但 PATH 上找不到 sbatch: 提交会失败。",
        "请先加载 Slurm 模块/修正 PATH, 或改配置 EXEC_BACKEND=\"local\"。"))
    }
  } else if (identical(req, "local")) {
    out$backend <- "local"
    if (out$traces) {
      warns <- c(warns, paste0(
        "已显式指定 EXEC_BACKEND=local, 但本机检测到 Slurm 痕迹 (集群登录节点?)。",
        "GUI 将直接在本机运行 DIA-NN, 可能违反集群使用政策, 请确认。"))
    }
  } else { # auto
    if (sbatch_ok) {
      out$backend <- "slurm"
    } else {
      out$backend <- "local"
      if (out$traces && isTRUE(require_exclusive)) {
        errs <- c(errs, paste0(
          "检测到 Slurm 痕迹 (squeue/sacct/scontrol/sinfo 或 /etc/slurm), 但 PATH 上没有 sbatch。\n",
          "为避免在 HPC 登录节点上直接运行计算任务, auto 模式拒绝静默回退到本地执行。\n",
          "请二选一:\n",
          "  1) 先加载 Slurm 模块 / 修正 PATH 后重新启动 run_app() (推荐);\n",
          "  2) 确认本机是单机服务器后, 在 config.R 设置 EXEC_BACKEND <- \"local\" ",
          "(或启动前 export DIANN_GUI_EXEC_BACKEND=local)。"))
      } else if (out$traces) {
        warns <- c(warns, paste0(
          "检测到 Slurm 痕迹但 sbatch 不在 PATH: 已按 LOCAL_REQUIRE_EXCLUSIVE_HOST=FALSE ",
          "回退到本地执行, 请确认这不是 HPC 登录节点。"))
      }
    }
  }

  if (identical(out$backend, "local") && isTRUE(legacy_central)) {
    if (isTRUE(allow_shared)) {
      warns <- c(warns, paste0(
        "legacy 中央 shiny-server 部署 + 本地执行: 所有作业都会以 GUI 运行账号执行, ",
        "无法按用户隔离/记账 (LOCAL_ALLOW_SHARED=TRUE 已显式放行)。"))
    } else {
      errs <- c(errs, paste0(
        "legacy 中央 shiny-server 部署 (站点目录有 app.R+config.R, 或配置了 SHARED_GROUP) ",
        "不支持本地执行: 所有作业会以共享运行账号执行, 破坏每用户隔离。\n",
        "请改用 Slurm 后端, 或改为每用户自托管; 确需启用请设置 LOCAL_ALLOW_SHARED <- TRUE。"))
    }
  }

  out$warn <- warns
  out$error <- errs
  out
}

# 当前后端信息 (缓存; refresh=TRUE 重新探测)。永不抛错。
backend_info <- function(refresh = FALSE) {
  info <- if (!isTRUE(refresh)) cfg_get("EXEC_BACKEND_INFO") else NULL
  if (!is.null(info) && !is.null(info$backend)) return(info)
  info <- tryCatch(
    detect_exec_backend(
      request = exec_backend_request(),
      require_exclusive = isTRUE(cfg_get("LOCAL_REQUIRE_EXCLUSIVE_HOST") %||% TRUE),
      allow_shared = isTRUE(cfg_get("LOCAL_ALLOW_SHARED") %||% FALSE)),
    error = function(e) list(request = "auto", backend = "local", auto = TRUE,
                             slurm_available = FALSE, traces = FALSE, legacy_central = FALSE,
                             warn = conditionMessage(e), error = character(0)))
  try(set_core_const("EXEC_BACKEND_INFO", info), silent = TRUE)
  try(set_core_const("EXEC_BACKEND_RESOLVED", info$backend), silent = TRUE)
  info
}

# 当前生效后端: "slurm" / "local"
exec_backend <- function() {
  b <- backend_info()$backend
  if (!identical(b, "slurm")) "local" else "slurm"
}

# UI/文档用的人类可读标签
backend_label <- function(backend = NULL) {
  backend <- backend %||% exec_backend()
  if (identical(backend, "local")) "本地单机" else "Slurm 集群"
}

# 启动检查: error -> stop (run_app 中调用); warn -> message。返回 invisible(info)。
backend_startup_check <- function() {
  info <- backend_info(refresh = TRUE)
  if (length(info$error)) {
    stop(paste(info$error, collapse = "\n\n"), call. = FALSE)
  }
  if (length(info$warn)) for (w in info$warn) message("⚠ ", w)
  invisible(info)
}

# ---------- 脚本 / 日志契约 ----------

# 预览与提交共用: 按后端生成作业脚本
backend_script <- function(p, backend = NULL) {
  make_job_script(p, backend %||% exec_backend())
}

# 唯一日志契约。返回 list(out, err, rc); 目录为空时 out/err 为空串。
#   旧记录兼容: slurm 仍为 slurm-<id>.out/.err; local 为 local-<id>.out/.err。
backend_log_paths <- function(job_id, out_dir, backend = NULL, script_path = "") {
  backend <- backend %||% exec_backend()
  out_dir <- as.character(out_dir %||% "")[1]
  if (is.na(out_dir)) out_dir <- ""
  jid <- as.character(job_id %||% "")[1]
  if (is.na(jid)) jid <- ""
  id <- suppressWarnings(as.integer(jid))
  prefix <- if (identical(backend, "local")) "local-" else "slurm-"
  base <- if (!is.na(id)) sprintf("%s%d", prefix, id) else paste0(prefix, gsub("[^A-Za-z0-9_.-]", "_", jid))
  rc <- if (length(script_path) == 1 && nzchar(script_path)) sub("\\.sh$", ".rc", script_path) else ""
  list(out = if (nzchar(out_dir)) file.path(out_dir, paste0(base, ".out")) else "",
       err = if (nzchar(out_dir)) file.path(out_dir, paste0(base, ".err")) else "",
       rc = rc)
}

# ---------- 提交 ----------

# 统一提交入口: 永不抛错 (返回 ok=FALSE + message), 防止 Shiny observer 断连。
#   slurm: sbatch -> "Submitted batch job N"
#   local: R/backend-local.R 的 local_submit() -> 持久化整数 job_id
backend_submit <- function(p, script_path, backend = NULL) {
  backend <- backend %||% exec_backend()
  out_dir <- as.character(p$out_dir %||% "")[1]
  fail <- function(msg) list(ok = FALSE, backend = backend, job_id = NA_character_,
                             message = msg, log_out = "", log_err = "", pid = NA_integer_)
  tryCatch({
    if (identical(backend, "slurm")) {
      res <- suppressWarnings(system2("sbatch", shQuote(script_path), stdout = TRUE, stderr = TRUE))
      status <- attr(res, "status")
      if (is.null(status)) status <- 0L
      txt <- paste(as.character(res), collapse = " ")
      m <- regmatches(txt, regexpr("Submitted batch job [0-9]+", txt))
      if (!length(m) || status != 0L) {
        return(fail(if (nzchar(trimws(txt))) txt else "sbatch 未返回 JobID (命令可能不存在或提交被拒绝)"))
      }
      jid <- sub(".*Submitted batch job ([0-9]+).*", "\\1", txt)
      lp <- backend_log_paths(jid, out_dir, "slurm")
      list(ok = TRUE, backend = "slurm", job_id = jid, message = txt,
           log_out = lp$out, log_err = lp$err, pid = NA_integer_)
    } else {
      local_submit(p, script_path)
    }
  }, error = function(e) {
    fail(sprintf("提交失败: %s", conditionMessage(e)))
  })
}

# ---------- 状态 / 历史 / 取消 / 耗时 ----------

# 统一快照: 与 slurm_snapshot() 同构 (lines/sacct_lines/squeue_map/sacct_map/at/backend)
backend_snapshot <- function(backend = NULL, refresh = FALSE) {
  backend <- backend %||% exec_backend()
  if (identical(backend, "slurm")) {
    snap <- slurm_snapshot(refresh = refresh)
    snap$backend <- "slurm"
    snap
  } else {
    local_snapshot(refresh = refresh)
  }
}

# 统一状态注入函数 (供 diann_job_status 使用, 不改变四层合成语义)
backend_status_fns <- function(backend = NULL) {
  backend <- backend %||% exec_backend()
  if (identical(backend, "slurm")) {
    slurm_snapshot_fns(slurm_snapshot())
  } else {
    local_status_fns()
  }
}

# 监控页历史表数据源: data.frame(作业ID, 作业名, 状态, 运行时长, 结束时间) 或 NULL
backend_history <- function(backend = NULL) {
  backend <- backend %||% exec_backend()
  if (identical(backend, "local")) return(local_history())
  snap <- tryCatch(slurm_snapshot(), error = function(e) NULL)
  if (is.null(snap) || !length(snap$sacct_lines)) return(NULL)
  rows <- strsplit(snap$sacct_lines, "|", fixed = TRUE)
  rows <- rows[vapply(rows, function(x) length(x) >= 5, logical(1))]
  if (!length(rows)) return(NULL)
  d <- data.frame(
    作业ID = vapply(rows, function(x) trimws(x[1]), ""),
    作业名 = vapply(rows, function(x) trimws(x[2]), ""),
    状态 = vapply(rows, function(x) trimws(x[3]), ""),
    运行时长 = vapply(rows, function(x) trimws(x[4]), ""),
    结束时间 = vapply(rows, function(x) trimws(x[5]), ""),
    stringsAsFactors = FALSE)
  d$运行时长[!nzchar(d$运行时长) | grepl("^Unknown$", d$运行时长, ignore.case = TRUE)] <- "-"
  d$结束时间[!nzchar(d$结束时间) | grepl("^Unknown$", d$结束时间, ignore.case = TRUE)] <- "-"
  d
}

# 作业耗时 (秒): 优先日志内 epoch 标记; slurm 回退 sacct Elapsed; local 回退 rc mtime
backend_elapsed <- function(job_id, log_path = "", backend = NULL, script_path = "") {
  backend <- backend %||% exec_backend()
  ep <- tryCatch(diann_notify_elapsed(log_path, jobid = NULL, backend = "none"),
                 error = function(e) NA_integer_)
  if (length(ep) == 1 && !is.na(ep)) return(as.integer(ep))
  if (identical(backend, "local")) {
    rc <- if (length(script_path) == 1 && nzchar(script_path)) sub("\\.sh$", ".rc", script_path) else ""
    if (nzchar(rc) && file.exists(rc) && file.exists(script_path)) {
      rt <- as.numeric(file.info(rc)$mtime)
      st <- as.numeric(file.info(script_path)$mtime)
      if (!is.na(rt) && !is.na(st)) return(as.integer(max(0, rt - st)))
    }
    return(NA_integer_)
  }
  ep2 <- tryCatch(diann_notify_elapsed(log_path, jobid = job_id, backend = "slurm"),
                  error = function(e) NA_integer_)
  if (length(ep2) == 1 && !is.na(ep2)) as.integer(ep2) else NA_integer_
}

# 取消作业: slurm -> scancel; local -> 进程组/子树 kill + .cancelled 标记。永不抛错。
backend_cancel <- function(job_id, backend = NULL) {
  backend <- backend %||% exec_backend()
  tryCatch({
    if (identical(backend, "slurm")) {
      jid <- suppressWarnings(as.integer(job_id))
      if (is.na(jid)) return(list(ok = FALSE, message = sprintf("无效的 Slurm 作业 ID: %s", job_id)))
      res <- suppressWarnings(system2("scancel", as.character(jid), stdout = TRUE, stderr = TRUE))
      if (length(res) && nzchar(trimws(paste(res, collapse = " ")))) {
        list(ok = FALSE, message = paste(res, collapse = " "))
      } else {
        list(ok = TRUE, message = sprintf("已发送 scancel %d", jid))
      }
    } else {
      local_cancel(job_id)
    }
  }, error = function(e) list(ok = FALSE, message = sprintf("取消失败: %s", conditionMessage(e))))
}

# 后端可用性 (doctor / 启动日志用)
backend_available <- function(backend = NULL) {
  backend <- backend %||% exec_backend()
  if (identical(backend, "slurm")) {
    cmds <- c("sbatch", "squeue", "sacct", "scancel")
    have <- vapply(cmds, function(x) nzchar(Sys.which(x)), logical(1))
    list(ok = all(have[c("sbatch", "squeue", "scancel")]), backend = backend,
         detail = paste(sprintf("%s=%s", cmds, ifelse(have, "ok", "missing")), collapse = ", "))
  } else {
    need <- c("bash", "nohup", "timeout")
    have <- vapply(need, function(x) nzchar(Sys.which(x)), logical(1))
    setsid_ok <- nzchar(Sys.which("setsid"))
    proc_ok <- file.exists("/proc/self/stat")
    list(ok = all(have) && proc_ok, backend = backend,
         detail = paste(c(sprintf("%s=%s", need, ifelse(have, "ok", "missing")),
                          sprintf("setsid=%s", ifelse(setsid_ok, "ok", "missing(退化为子树取消)")),
                          sprintf("/proc=%s", ifelse(proc_ok, "ok", "unavailable"))), collapse = ", "))
  }
}
