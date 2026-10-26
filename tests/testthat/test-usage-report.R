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
