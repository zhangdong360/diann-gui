# usage_report(): 注册表 v2 的 script_path/out_file 优先于"猜目录里最新的 tsv"
# 2026-10 审查: 旧实现 script_of() 忽略 jobid, 同目录多作业时会把 B 作业的 .rc
# 当成 A 的, 月度状态张冠李戴; 主报告也只能靠 mtime 猜。

usage_dir <- function(name) {
  d <- file.path(tempdir(), sprintf("%s_%d_%d", name, Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  d
}
usage_job <- function(d, rc = "0", report = NULL, start_off = -5) {
  sd <- file.path(d, "diann_gui_scripts"); dir.create(sd, showWarnings = FALSE)
  sh <- file.path(sd, "diann_job.sh"); writeLines("#!/bin/bash", sh)
  writeLines(rc, sub("\\.sh$", ".rc", sh))
  now <- as.integer(Sys.time())
  writeLines(sprintf("DIANN_GUI_START_EPOCH %d", now + start_off),
             file.path(d, "slurm-999001.out"))
  if (!is.null(report)) {
    writeLines(c("header", "row"), report)
    Sys.setFileTime(report, Sys.time())
  }
  sh
}
write_registry <- function(rows) {
  f <- diann.gui:::jobs_registry_file()
  saveRDS(rows, f)
  f
}

test_that("注册表 v2: 以记录的 out_file/script_path 为准 (不猜同目录最新 tsv)", {
  d <- usage_dir("usage_v2")
  # 记录的主报告不存在, 目录里却有一个更新的 tsv: 旧启发式会误判为成功
  other <- file.path(d, "other.tsv"); writeLines(c("h", "x"), other)
  Sys.setFileTime(other, Sys.time())
  sh <- usage_job(d, rc = "0", report = NULL)
  reg <- data.frame(jobid = "999001", 任务名 = "T", 输出目录 = d,
                    日志 = file.path(d, "slurm-999001.out"),
                    提交时间 = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                    script_path = sh, out_file = file.path(d, "missing_report.tsv"),
                    sif = NA, apptainer = NA, 版本 = "2.7.0", stringsAsFactors = FALSE)
  registry <- write_registry(reg)
  outdir <- usage_dir("usage_out")
  f <- diann.gui::usage_report(month = format(Sys.Date(), "%Y-%m"), out_dir = outdir,
                               registry = registry, state = tempfile("nostate"))
  expect_true(file.exists(f))
  txt <- paste(readLines(f, warn = FALSE), collapse = "\n")
  expect_match(txt, "\\| 999001 \\|")
  row <- grep("\\| 999001 \\|", readLines(f, warn = FALSE), value = TRUE)[1]
  expect_match(row, "未知")          # v2: 记录的主报告缺失 -> 未知 (而非猜成 成功)
  expect_false(grepl("成功", row))
})

test_that("注册表 v1 (无 v2 列) 仍可读并回退启发式", {
  d <- usage_dir("usage_v1")
  report <- file.path(d, "report.tsv")
  usage_job(d, rc = "0", report = report)
  reg <- data.frame(jobid = "999001", 任务名 = "T", 输出目录 = d,
                    日志 = file.path(d, "slurm-999001.out"),
                    提交时间 = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                    stringsAsFactors = FALSE)
  registry <- write_registry(reg)
  outdir <- usage_dir("usage_out_v1")
  f <- diann.gui::usage_report(month = format(Sys.Date(), "%Y-%m"), out_dir = outdir,
                               registry = registry, state = tempfile("nostate"))
  expect_true(file.exists(f))
  txt <- paste(readLines(f, warn = FALSE), collapse = "\n")
  row <- grep("\\| 999001 \\|", readLines(f, warn = FALSE), value = TRUE)[1]
  expect_match(row, "成功")
  # v1.14.1: 无版本列的旧记录在明细表里标「未识别」(不再留空白)
  expect_match(row, "未识别")
  expect_true(any(grepl("^\\| JobID \\| 任务名 \\| 版本 \\|", readLines(f, warn = FALSE))))
})

test_that("失败作业进入失败明细", {
  d <- usage_dir("usage_fail")
  usage_job(d, rc = "2", report = NULL)
  reg <- data.frame(jobid = "999002", 任务名 = "F", 输出目录 = d,
                    日志 = file.path(d, "slurm-999002.out"),
                    提交时间 = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                    script_path = file.path(d, "diann_gui_scripts", "diann_job.sh"),
                    out_file = file.path(d, "report.tsv"), sif = NA, apptainer = NA,
                    版本 = "2.7.0", stringsAsFactors = FALSE)
  registry <- write_registry(reg)
  outdir <- usage_dir("usage_out_fail")
  f <- diann.gui::usage_report(month = format(Sys.Date(), "%Y-%m"), out_dir = outdir,
                               registry = registry, state = tempfile("nostate"))
  txt <- paste(readLines(f, warn = FALSE), collapse = "\n")
  expect_match(txt, "失败 / 待核实明细")
  expect_match(txt, "\\| 999002 \\|")
})

test_that("月份格式非法时报错", {
  expect_error(diann.gui::usage_report(month = "2026-1"), "YYYY-MM")
})

# ---------- v1.12: 混合 slurm/local 记录 + 「后端」列 ----------

test_that("usage_report 混合记录: 按记录后端分派状态来源, 明细含「后端」列", {
  # 本地作业状态文件与通知状态同目录: 隔离到临时 NOTIFY_STATE, 不污染测试 HOME
  old_state <- diann.gui::cfg_get("NOTIFY_STATE")
  st_dir <- usage_dir("usage_local_state")
  diann.gui::set_core_const("NOTIFY_STATE", file.path(st_dir, "notify.rds"))
  on.exit(diann.gui::set_core_const("NOTIFY_STATE", old_state), add = TRUE)

  now <- as.integer(Sys.time())
  # --- local 作业: rc=0 + 新主报告 -> 成功 ---
  ld <- usage_dir("usage_local_out")
  sd <- file.path(ld, "diann_gui_scripts"); dir.create(sd, showWarnings = FALSE)
  lsh <- file.path(sd, "diann_local.sh"); writeLines("#!/bin/bash", lsh)
  writeLines("0", sub("\\.sh$", ".rc", lsh))
  lrep <- file.path(ld, "report.tsv"); writeLines(c("h", "r"), lrep)
  llog <- file.path(ld, "local-1000001.out")
  writeLines(c(sprintf("DIANN_GUI_START_EPOCH %d", now - 20), "exit code: 0",
               sprintf("DIANN_GUI_END_EPOCH %d", now)), llog)
  diann.gui:::local_jobs_add(list(
    jobid = 1000001L, task = "L", out_dir = ld, script_path = lsh,
    log_out = llog, log_err = sub("\\.out$", ".err", llog),
    rc_path = sub("\\.sh$", ".rc", lsh), pid = NA_integer_, pid_start = NA_real_,
    runner = "", submitted = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    submitted_epoch = now - 30, time_sec = 0L, backend = "local"))

  # --- slurm 作业: 同样经 rc + 产物合成成功 (登录节点无该作业: sacct 不可用分支) ---
  sdd <- usage_dir("usage_slurm_out")
  ssd <- file.path(sdd, "diann_gui_scripts"); dir.create(ssd, showWarnings = FALSE)
  ssh <- file.path(ssd, "diann_slurm.sh"); writeLines("#!/bin/bash", ssh)
  writeLines("0", sub("\\.sh$", ".rc", ssh))
  srep <- file.path(sdd, "report.tsv"); writeLines(c("h", "r"), srep)
  slog <- file.path(sdd, "slurm-888001.out")
  writeLines(c(sprintf("DIANN_GUI_START_EPOCH %d", now - 20), "exit code: 0",
               sprintf("DIANN_GUI_END_EPOCH %d", now)), slog)

  reg <- data.frame(
    jobid = c("888001", "1000001"), 任务名 = c("S", "L"),
    输出目录 = c(sdd, ld), 日志 = c(slog, llog),
    提交时间 = rep(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), 2),
    script_path = c(ssh, lsh), out_file = c(srep, lrep), sif = NA, apptainer = NA,
    版本 = "2.7.0", backend = c("slurm", "local"), pid = c(NA, NA),
    stringsAsFactors = FALSE)
  registry <- write_registry(reg)
  outdir <- usage_dir("usage_out_mixed")
  f <- diann.gui::usage_report(month = format(Sys.Date(), "%Y-%m"), out_dir = outdir,
                               registry = registry, state = tempfile("nostate"))
  lines <- readLines(f, warn = FALSE)
  txt <- paste(lines, collapse = "\n")
  expect_match(txt, "执行后端: Slurm \\*\\*1\\*\\* 条 / 本地 \\*\\*1\\*\\* 条")
  row_l <- grep("\\| 1000001 \\|", lines, value = TRUE)[1]
  row_s <- grep("\\| 888001 \\|", lines, value = TRUE)[1]
  expect_match(row_l, "本地")
  expect_match(row_s, "Slurm")
  expect_match(row_l, "成功")
  expect_match(row_s, "成功")
  # v1.14.1: 明细表含「版本」列并显示注册表记录的容器实测版本
  expect_match(row_l, "2.7.0")
  expect_match(row_s, "2.7.0")
  expect_true(any(grepl("^\\| JobID \\| 任务名 \\| 版本 \\|", lines)))
  expect_true(grepl("本地", txt, fixed = TRUE) && grepl("Slurm", txt, fixed = TRUE))
})

test_that("usage_report: v2 旧记录 (无 backend 列) 按 Slurm 解释并出现在「后端」列", {
  d <- usage_dir("usage_v2_nobackend")
  report <- file.path(d, "report.tsv")
  usage_job(d, rc = "0", report = report)
  reg <- data.frame(jobid = "999003", 任务名 = "S", 输出目录 = d,
                    日志 = file.path(d, "slurm-999003.out"),
                    提交时间 = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                    script_path = file.path(d, "diann_gui_scripts", "diann_job.sh"),
                    out_file = report, sif = NA, apptainer = NA, 版本 = "2.7.0",
                    stringsAsFactors = FALSE)
  registry <- write_registry(reg)
  outdir <- usage_dir("usage_out_v2_nobackend")
  f <- diann.gui::usage_report(month = format(Sys.Date(), "%Y-%m"), out_dir = outdir,
                               registry = registry, state = tempfile("nostate"))
  lines <- readLines(f, warn = FALSE)
  row <- grep("\\| 999003 \\|", lines, value = TRUE)[1]
  expect_match(row, "Slurm")
  expect_match(paste(lines, collapse = "\n"), "Slurm \\*\\*1\\*\\* 条 / 本地 \\*\\*0\\*\\* 条")
})
