# v1.12 执行后端: 解析 / 日志契约 / 脚本分派 / 本地提交-状态-取消-超时
# 全部离线: 假 apptainer + 假 DIA-NN 负载, 不依赖真实 Slurm / 容器 / RAW 数据。

# ---------- 后端解析 ----------

cmds_all <- c(sbatch = "/usr/bin/sbatch", squeue = "/usr/bin/squeue", sacct = "/usr/bin/sacct",
              scancel = "/usr/bin/scancel", scontrol = "/usr/bin/scontrol", sinfo = "/usr/bin/sinfo")
cmds_none <- stats::setNames(rep("", length(cmds_all)), names(cmds_all))

test_that("detect_exec_backend: auto + sbatch -> slurm; 无 Slurm -> local", {
  d <- detect_exec_backend(request = "auto", cmds = cmds_all, slurm_traces = FALSE)
  expect_equal(d$backend, "slurm")
  expect_true(d$auto)
  expect_length(d$error, 0)
  d2 <- detect_exec_backend(request = "auto", cmds = cmds_none, slurm_traces = FALSE)
  expect_equal(d2$backend, "local")
  expect_length(d2$error, 0)
})

test_that("detect_exec_backend: auto + Slurm 痕迹但 sbatch 缺失 -> 默认拒绝 (HPC 登录节点保护)", {
  cmds <- cmds_none; cmds[["squeue"]] <- "/usr/bin/squeue"
  d <- detect_exec_backend(request = "auto", cmds = cmds, slurm_traces = TRUE)
  expect_equal(d$backend, "local")
  expect_true(length(d$error) >= 1)
  expect_match(d$error[1], "拒绝", fixed = TRUE)
  d2 <- detect_exec_backend(request = "auto", cmds = cmds, slurm_traces = TRUE,
                            require_exclusive = FALSE)
  expect_length(d2$error, 0)
  expect_true(length(d2$warn) >= 1)
})

test_that("detect_exec_backend: 显式 local 放行但 warn (legacy 中央部署拒绝已随 v1.13 删除)", {
  cmds <- cmds_none; cmds[["squeue"]] <- "/usr/bin/squeue"
  d <- detect_exec_backend(request = "local", cmds = cmds, slurm_traces = TRUE)
  expect_equal(d$backend, "local")
  expect_length(d$error, 0)
  expect_true(length(d$warn) >= 1)
  # v1.13: 不再有 legacy_central/allow_shared 参数
  expect_false("legacy_central" %in% names(formals(detect_exec_backend)))
})

test_that("detect_exec_backend: 显式 slurm 但无 sbatch -> 保留 slurm 并 warn", {
  d <- detect_exec_backend(request = "slurm", cmds = cmds_none, slurm_traces = FALSE)
  expect_equal(d$backend, "slurm")
  expect_true(length(d$warn) >= 1)
  expect_length(d$error, 0)
})

test_that("detect_exec_backend: 非法请求值报错", {
  expect_error(detect_exec_backend(request = "cloud"), "EXEC_BACKEND")
})

test_that("backend_log_paths: slurm/local 命名与 rc 规则 (唯一日志契约)", {
  expect_equal(backend_log_paths(42, "/o", "slurm")$out, "/o/slurm-42.out")
  expect_equal(backend_log_paths(42, "/o", "slurm")$err, "/o/slurm-42.err")
  expect_equal(backend_log_paths(1000042, "/o", "local")$out, "/o/local-1000042.out")
  expect_equal(backend_log_paths("1000042", "/o", "local")$err, "/o/local-1000042.err")
  expect_equal(backend_log_paths(1000042, "/o", "local", "/o/j.sh")$rc, "/o/j.rc")
  expect_equal(backend_log_paths(7, "", "slurm")$out, "")
})

# ---------- 脚本分派 / 程序体共用 ----------

test_that("make_local_script: 共用 job_body、无 #SBATCH、忽略 SLURM_EXTRA_ARGS", {
  old <- diann.gui::cfg_get("SLURM_EXTRA_ARGS")
  on.exit(diann.gui::set_core_const("SLURM_EXTRA_ARGS", old), add = TRUE)
  diann.gui::set_core_const("SLURM_EXTRA_ARGS", c("--account=lab"))
  p <- base_params(list(time_h = 1.9))
  loc <- make_local_script(p)
  expect_false(grepl("#SBATCH", loc, fixed = TRUE))
  expect_false(grepl("--account=lab", loc, fixed = TRUE))
  expect_match(loc, "DIANN_GUI_START_EPOCH", fixed = TRUE)
  expect_match(loc, "exit $rc", fixed = TRUE)
  expect_match(loc, "114 分钟", fixed = TRUE)
  expect_identical(make_job_script(p, "local"), loc)
  expect_identical(make_job_script(p, "slurm"), make_slurm_script(p))
})

test_that("本地脚本与 Slurm 脚本共用同一段程序体 (仅头部与末尾注释措辞不同)", {
  p <- base_params()
  body_lines <- function(s) {
    l <- strsplit(s, "\n", fixed = TRUE)[[1]]
    i <- grep("^APPTAINER_BIN=", l)[1]
    body <- l[i:length(l)]
    # 四层状态注释里的"调度态"措辞按后端标注 (Slurm 终态 / 本地进程态), 属唯一差异
    body[!grepl("^# 如实退出", body)]
  }
  expect_identical(body_lines(make_local_script(p)), body_lines(make_slurm_script(p)))
})

# ---------- 提交失败不抛错 (v1.11 无 Slurm 点提交断连事故的回归) ----------

test_that("backend_submit: sbatch 缺失时返回 ok=FALSE 且不抛错", {
  old_path <- Sys.getenv("PATH")
  td <- tempfile("empty_path"); dir.create(td, showWarnings = FALSE)
  Sys.setenv(PATH = td)
  on.exit(Sys.setenv(PATH = old_path), add = TRUE)
  p <- base_params(list(out_dir = tempdir(), script_path = file.path(tempdir(), "job.sh")))
  res <- tryCatch(backend_submit(p, p$script_path, backend = "slurm"), error = function(e) e)
  expect_false(inherits(res, "error"))
  expect_false(isTRUE(res$ok))
  expect_true(nzchar(res$message))
})

# ---------- 本地提交 / 状态 / 取消 / 超时 (假 apptainer) ----------

test_that("local: 提交成功 -> 成功标签, 日志/rc/epoch 落盘", {
  td <- tempfile("local_ok"); dir.create(td, showWarnings = FALSE)
  apt <- fake_apptainer()
  Sys.unsetenv(c("FAKE_DIANN_SLEEP", "FAKE_DIANN_RC", "FAKE_DIANN_CTL"))
  p <- make_local_params(td, apt)
  writeLines(make_local_script(p), p$script_path)
  res <- backend_submit(p, p$script_path, backend = "local")
  expect_true(isTRUE(res$ok))
  expect_equal(res$backend, "local")
  expect_match(res$job_id, "^[0-9]+$")
  expect_equal(poll_local_status(p, res$job_id), "成功")
  lp <- backend_log_paths(res$job_id, td, "local", p$script_path)
  expect_true(file.exists(lp$out))
  expect_true(file.exists(lp$rc))
  expect_equal(trimws(readLines(lp$rc, warn = FALSE)[1]), "0")
  log_lines <- readLines(lp$out, warn = FALSE)
  expect_true(any(grepl("^DIANN_GUI_START_EPOCH", log_lines)))
  expect_true(any(grepl("^DIANN_GUI_END_EPOCH", log_lines)))
})

test_that("local: 非零退出码 -> 失败", {
  td <- tempfile("local_fail"); dir.create(td, showWarnings = FALSE)
  apt <- fake_apptainer()
  Sys.setenv(FAKE_DIANN_RC = "3")
  on.exit(Sys.unsetenv("FAKE_DIANN_RC"), add = TRUE)
  p <- make_local_params(td, apt)
  writeLines(make_local_script(p), p$script_path)
  res <- backend_submit(p, p$script_path, backend = "local")
  expect_true(isTRUE(res$ok))
  expect_equal(poll_local_status(p, res$job_id), "失败")
  lp <- backend_log_paths(res$job_id, td, "local", p$script_path)
  expect_equal(trimws(readLines(lp$rc, warn = FALSE)[1]), "3")
})

test_that("local: 时限 -> 超时 (timeout 强制, 标记 .timeout, rc=124)", {
  td <- tempfile("local_timeout"); dir.create(td, showWarnings = FALSE)
  apt <- fake_apptainer()
  Sys.setenv(FAKE_DIANN_SLEEP = "20")
  on.exit(Sys.unsetenv("FAKE_DIANN_SLEEP"), add = TRUE)
  p <- make_local_params(td, apt, time_h = 1 / 3600)  # 1 秒
  writeLines(make_local_script(p), p$script_path)
  res <- backend_submit(p, p$script_path, backend = "local")
  expect_true(isTRUE(res$ok))
  expect_equal(poll_local_status(p, res$job_id), "超时")
  expect_true(file.exists(paste0(p$script_path, ".timeout")))
  lp <- backend_log_paths(res$job_id, td, "local", p$script_path)
  expect_equal(trimws(readLines(lp$rc, warn = FALSE)[1]), "124")
})

test_that("local: 取消 -> 已取消 (标记 + 进程组 kill, 无残留进程)", {
  td <- tempfile("local_cancel"); dir.create(td, showWarnings = FALSE)
  apt <- fake_apptainer()
  ctl <- file.path(td, "sleep.txt"); writeLines("60", ctl)
  Sys.setenv(FAKE_DIANN_CTL = ctl)
  on.exit(Sys.unsetenv("FAKE_DIANN_CTL"), add = TRUE)
  p <- make_local_params(td, apt)
  writeLines(make_local_script(p), p$script_path)
  res <- backend_submit(p, p$script_path, backend = "local")
  expect_true(isTRUE(res$ok))
  Sys.sleep(1.5)  # 等运行器进入 RUNNING
  cres <- backend_cancel(res$job_id, backend = "local")
  expect_true(isTRUE(cres$ok))
  expect_equal(poll_local_status(p, res$job_id), "已取消")
  expect_true(file.exists(paste0(p$script_path, ".cancelled")))
  rec <- local_jobs_find(res$job_id)
  expect_false(is.null(rec))
  # CI 负载下 TERM 到进程消失有延迟, 单发断言会竞态红 — 轮询等待判死 (最长 10s)
  dead <- FALSE
  for (i in 1:40) {
    if (!isTRUE(local_job_alive(rec))) { dead <- TRUE; break }
    Sys.sleep(0.25)
  }
  expect_true(dead)
})

test_that("local: PID 复用防护 (starttime 不匹配 -> 判死)", {
  td <- tempfile("local_reuse"); dir.create(td, showWarnings = FALSE)
  apt <- fake_apptainer()
  p <- make_local_params(td, apt)
  writeLines(make_local_script(p), p$script_path)
  res <- backend_submit(p, p$script_path, backend = "local")
  expect_true(isTRUE(res$ok))
  rec <- local_jobs_find(res$job_id)
  expect_false(is.null(rec))
  ps <- rec$pid_start
  if (is.null(ps) || !is.finite(ps)) ps <- 0
  rec$pid_start <- as.numeric(ps) + 12345
  expect_false(local_job_alive(rec))
  poll_local_status(p, res$job_id)  # 等真正结束, 避免遗留进程
})

# ---------- v1.13 WP4: 本地并发 ETA / RDS/seq 损坏恢复 ----------

# 快照-恢复本地状态 (注入测试记录后还原, 不污染其它用例)
snapshot_local_state <- function() {
  jf <- local_jobs_file(); sf <- local_seq_file()
  list(jf = if (file.exists(jf)) readRDS(jf) else NULL,
       sf = if (file.exists(sf)) paste(readLines(sf, warn = FALSE), collapse = "\n") else NULL,
       jf_path = jf, sf_path = sf)
}
restore_local_state <- function(snap) {
  if (is.null(snap$jf)) unlink(snap$jf_path) else saveRDS(snap$jf, snap$jf_path)
  if (is.null(snap$sf)) unlink(snap$sf_path) else writeLines(snap$sf, snap$sf_path)
  # 清理损坏备份与告警
  unlink(Sys.glob(paste0(snap$jf_path, ".corrupt-*")))
  unlink(Sys.glob(paste0(snap$sf_path, ".corrupt-*")))
  try(diann.gui::set_core_const("LOCAL_JOBS_WARN", NULL), silent = TRUE)
}

test_that("local_next_slot_info: 有时限给 ETA, 无时限明示未知, 多作业取最早", {
  snap <- snapshot_local_state(); on.exit(restore_local_state(snap), add = TRUE)
  now <- as.numeric(Sys.time())
  rec <- function(id, ts, se = now) {
    list(jobid = as.character(id), script_path = "", log_out = "", pid = NA_integer_,
         submitted_epoch = se, time_sec = ts, backend = "local")
  }
  local_jobs_save(list(recs = list(rec(900001L, 60), rec(900002L, 120))))
  s1 <- local_next_slot_info()
  expect_equal(s1$n, 2L)
  expect_false(s1$unknown_limit)
  expect_equal(s1$earliest_job, "900001")            # 取最早
  expect_lt(abs(s1$eta - (now + 60)), 5)

  local_jobs_save(list(recs = list(rec(900003L, 0))))   # 无时限
  s2 <- local_next_slot_info()
  expect_equal(s2$n, 1L)
  expect_true(s2$unknown_limit)
  expect_true(is.na(s2$eta))
  expect_match(s2$detail, "未设时限")

  local_jobs_save(list(recs = list()))                   # 空表
  s3 <- local_next_slot_info()
  expect_equal(s3$n, 0L)
})

test_that("RDS 损坏: 备份 + 告警一次性 + 返回空, 不崩", {
  snap <- snapshot_local_state(); on.exit(restore_local_state(snap), add = TRUE)
  jf <- local_jobs_file()
  writeLines("this is not an RDS file", jf)
  x <- local_jobs_load()
  expect_identical(x$recs, list())                       # 返回空表
  expect_true(length(Sys.glob(paste0(jf, ".corrupt-*"))) == 1)  # 已备份
  expect_true(nzchar(cfg_get("LOCAL_JOBS_WARN") %||% ""))       # 一次性告警已设置
  expect_match(cfg_get("LOCAL_JOBS_WARN"), "ps -ef | grep local_runner")
  expect_false(file.exists(jf))                          # 原文件已改名
  x2 <- local_jobs_load()                                # 再次加载不重复告警/备份
  expect_identical(x2$recs, list())

  st <- local_jobs_status()                              # doctor 只读检查
  expect_true(st$ok)                                     # 文件已不存在 -> ok
  # 重新放一个坏文件: status 应报不可解析 (且不改文件)
  writeLines("garbage again", jf)
  st2 <- local_jobs_status()
  expect_false(st2$ok)
  expect_true(file.exists(jf))                           # 只读: 未动文件
})

test_that("坏记录逐条校验: 无 jobid 的记录被丢弃", {
  snap <- snapshot_local_state(); on.exit(restore_local_state(snap), add = TRUE)
  jf <- local_jobs_file()
  saveRDS(list(recs = list(list(jobid = "900010", script_path = ""),
                           list(script_path = "no-id"), "not-a-list")), jf)
  x <- local_jobs_load()
  expect_length(x$recs, 1L)
  expect_equal(as.character(x$recs[[1]]$jobid), "900010")
})

test_that("seq 损坏/落后: 自愈为 max(existing)+1, 不撞号", {
  snap <- snapshot_local_state(); on.exit(restore_local_state(snap), add = TRUE)
  # 现有序列号 (可能是初始 1000000 或更高)
  cur <- if (file.exists(snap$sf_path)) {
    v <- suppressWarnings(as.integer(readLines(snap$sf_path, warn = FALSE)[1])); if (is.na(v)) 1000000L else v
  } else 1000000L
  # 注入一条 jobid 高于序列的记录 (模拟序列文件落后/损坏)
  local_jobs_save(list(recs = list(list(jobid = as.character(cur + 50L), script_path = "",
                                        log_out = "", pid = NA_integer_,
                                        submitted_epoch = 0, time_sec = 0, backend = "local"))))
  writeLines("garbage", snap$sf_path)                    # 序列文件损坏
  nid <- local_seq_next()
  expect_equal(nid, cur + 51L)                           # max(existing)+1, 不撞号
  expect_true(length(Sys.glob(paste0(snap$sf_path, ".corrupt-*"))) >= 1)
})
