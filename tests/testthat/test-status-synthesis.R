# diann_job_status: 四层状态合成 (注入 sacct_fn/squeue_fn, 不碰真实集群)
sq_empty <- function(id) character(0)
sq_run <- function(id) "RUNNING"
sq_pend <- function(id) "PENDING"
sa <- function(line) function(id) line
sa_none <- function(id) character(0)
OF <- "report.tsv"

test_that("队列中: 运行中 / 排队中", {
  d <- make_out_dir()
  expect_equal(diann_job_status(99, d[1], file.path(d[1], OF), sacct_fn = sa("99|COMPLETED|0:0|1:00|x"), squeue_fn = sq_run)$label, "运行中")
  expect_equal(diann_job_status(99, d[1], file.path(d[1], OF), sacct_fn = sa("99|PENDING|0:0||"), squeue_fn = sq_pend)$label, "排队中")
})

test_that("COMPLETED + 新产物 = 成功; COMPLETED + 无/旧产物 = 待核实; 空报告 = 待核实", {
  d <- make_out_dir()
  st <- diann_job_status(99, d[1], file.path(d[1], OF), sacct_fn = sa("99|COMPLETED|0:0|1:00|x"), squeue_fn = sq_empty)
  expect_true(st$label == "成功" && st$artifact_new && st$rc == 0)
  d2 <- make_out_dir(report = FALSE)
  st2 <- diann_job_status(99, d2[1], file.path(d2[1], OF), sacct_fn = sa("99|COMPLETED|0:0|1:00|x"), squeue_fn = sq_empty)
  expect_equal(st2$label, "待核实")
  d3 <- make_out_dir(mtime_epoch = 500)  # 产物 mtime 早于本次 start(1000) = 遗留
  st3 <- diann_job_status(99, d3[1], file.path(d3[1], OF), sacct_fn = sa("99|COMPLETED|0:0|1:00|x"), squeue_fn = sq_empty)
  expect_equal(st3$label, "待核实")
  d4 <- make_out_dir(empty_report = TRUE)  # 0 字节报告 = 无有效产物
  st4 <- diann_job_status(99, d4[1], file.path(d4[1], OF), sacct_fn = sa("99|COMPLETED|0:0|1:00|x"), squeue_fn = sq_empty)
  expect_equal(st4$label, "待核实")
})

test_that("FAILED: rc!=0 无产物 = 失败; teardown 信号码 + 新产物 = 待核实 (rcfile 优先于日志)", {
  d <- make_out_dir(rc_line = "exit code: 132")
  writeLines("132", file.path(d[1], "j.rc"))
  st <- diann_job_status(99, d[1], file.path(d[1], OF), script_path = file.path(d[1], "j.sh"),
                         sacct_fn = sa("99|FAILED|132:0|1:00|x"), squeue_fn = sq_empty)
  expect_true(st$label == "待核实" && st$rc == 132)
  d2 <- make_out_dir(report = FALSE, rc_line = "exit code: 2")
  st2 <- diann_job_status(99, d2[1], file.path(d2[1], OF), sacct_fn = sa("99|FAILED|2:0|0:05|x"), squeue_fn = sq_empty)
  expect_true(st2$label == "失败" && grepl("退出码 2", st2$reason))
})

test_that("TIMEOUT / CANCELLED (含 by uid 尾巴归一化)", {
  d <- make_out_dir()
  expect_equal(diann_job_status(99, d[1], file.path(d[1], OF), sacct_fn = sa("99|TIMEOUT|0:9|8:00:00|x"), squeue_fn = sq_empty)$label, "超时")
  d2 <- make_out_dir(report = FALSE)
  st2 <- diann_job_status(99, d2[1], file.path(d2[1], OF), sacct_fn = sa("99|CANCELLED by 1001|0:0|0:10|x"), squeue_fn = sq_empty)
  expect_true(st2$label == "已取消" && st2$state == "CANCELLED")
})

test_that("sacct 不可用时退化为 rc+产物合成并注明", {
  d <- make_out_dir()
  st <- diann_job_status(99, d[1], file.path(d[1], OF), sacct_fn = sa_none, squeue_fn = sq_empty)
  expect_true(st$label == "成功" && grepl("sacct", st$reason))
  d2 <- make_out_dir(report = FALSE, rc_line = "exit code: 2")
  st2 <- diann_job_status(99, d2[1], file.path(d2[1], OF), sacct_fn = sa_none, squeue_fn = sq_empty)
  expect_equal(st2$label, "失败")
  d3 <- make_out_dir(report = FALSE)
  st3 <- diann_job_status(99, d3[1], file.path(d3[1], OF), sacct_fn = sa_none, squeue_fn = sq_empty)
  expect_equal(st3$label, "未知")
})

test_that("产物层不可核验 (out_file 为空, 报告聚合模式): COMPLETED = 成功(未核验)", {
  d <- make_out_dir()
  st <- diann_job_status(99, d[1], "", sacct_fn = sa("99|COMPLETED|0:0|1:00|x"), squeue_fn = sq_empty)
  expect_true(st$label == "成功" && is.na(st$artifact_new))
  st2 <- diann_job_status(99, d[1], "", sacct_fn = sa("99|FAILED|2:0|1:00|x"), squeue_fn = sq_empty)
  expect_equal(st2$label, "失败")
})

test_that("无日志时产物新旧回退 submitted 时间", {
  d <- tempfile("noslurm_"); dir.create(d, showWarnings = FALSE)
  rf <- file.path(d, "report.tsv"); writeLines(c("h", "x"), rf)
  sub_t <- format(Sys.time() - 60, "%Y-%m-%d %H:%M:%S")
  st <- diann_job_status(99, d, rf, submitted = sub_t,
                         sacct_fn = sa("99|COMPLETED|0:0|1:00|x"), squeue_fn = sq_empty)
  expect_true(st$label == "成功" && st$artifact_new)
  # 产物早于提交 = 遗留
  Sys.setFileTime(rf, as.numeric(as.POSIXct(sub_t)) - 30)
  st2 <- diann_job_status(99, d, rf, submitted = sub_t,
                          sacct_fn = sa("99|COMPLETED|0:0|1:00|x"), squeue_fn = sq_empty)
  expect_equal(st2$label, "待核实")
})

test_that("slurm_state_normalize 剥离 uid 尾巴且大小写不敏感", {
  expect_equal(slurm_state_normalize("cancelled by 1001"), "CANCELLED")
  expect_equal(slurm_state_normalize("COMPLETED"), "COMPLETED")
  expect_equal(slurm_state_normalize("  timeout  "), "TIMEOUT")
})

# ---------- v1.12: 本地后端状态注入 (local provider) 与 log_path 契约 ----------

local_state_guard <- function() {
  old <- diann.gui::cfg_get("NOTIFY_STATE")
  td <- file.path(tempdir(), sprintf("locstate_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(td, showWarnings = FALSE, recursive = TRUE)
  diann.gui::set_core_const("NOTIFY_STATE", file.path(td, "notify.rds"))
  list(old = old, dir = td)
}

local_rec <- function(td, jobid, pid = 2147483000L, pid_start = NA_real_, rc = NULL,
                      cancelled = FALSE, timeout = FALSE) {
  sd <- file.path(td, "diann_gui_scripts")
  dir.create(sd, showWarnings = FALSE, recursive = TRUE)
  sp <- file.path(sd, sprintf("diann_%s.sh", jobid))
  writeLines("#!/bin/bash", sp)
  if (!is.null(rc)) writeLines(as.character(rc), sub("\\.sh$", ".rc", sp))
  if (isTRUE(cancelled)) file.create(paste0(sp, ".cancelled"))
  if (isTRUE(timeout)) file.create(paste0(sp, ".timeout"))
  log_out <- file.path(td, sprintf("local-%s.out", jobid))
  now <- as.numeric(Sys.time())
  writeLines(c(sprintf("DIANN_GUI_START_EPOCH %d", as.integer(now) - 30),
               sprintf("DIANN_GUI_END_EPOCH %d", as.integer(now))), log_out)
  list(jobid = as.character(jobid), task = "T", out_dir = td, script_path = sp,
       log_out = log_out, log_err = sub("\\.out$", ".err", log_out),
       rc_path = sub("\\.sh$", ".rc", sp), pid = pid, pid_start = pid_start,
       runner = "", submitted = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
       submitted_epoch = now - 60, time_sec = 0L, backend = "local")
}

local_status <- function(rec, td, out_file) {
  fns <- diann.gui:::local_status_fns()
  diann_job_status(rec$jobid, td, out_file, script_path = rec$script_path,
                   squeue_fn = fns$squeue_fn, sacct_fn = fns$sacct_fn,
                   log_path = rec$log_out)
}

test_that("local provider: 六个展示标签 (成功/失败/超时/已取消/待核实/未知)", {
  g <- local_state_guard()
  on.exit(diann.gui::set_core_const("NOTIFY_STATE", g$old), add = TRUE)
  td <- g$dir
  rep_ok <- file.path(td, "report.tsv"); writeLines(c("h", "r"), rep_ok)

  rec <- local_rec(td, "1000101", rc = "0"); diann.gui:::local_jobs_add(rec)
  st <- local_status(rec, td, rep_ok)
  expect_equal(st$label, "成功")
  expect_equal(st$rc, 0L)
  expect_true(isTRUE(st$artifact_new))

  rec2 <- local_rec(td, "1000102", rc = "2"); diann.gui:::local_jobs_add(rec2)
  st2 <- local_status(rec2, td, file.path(td, "missing_102.tsv"))
  expect_equal(st2$label, "失败")
  expect_match(st2$reason, "退出码 2")

  rec3 <- local_rec(td, "1000103", rc = "124", timeout = TRUE)
  diann.gui:::local_jobs_add(rec3)
  expect_equal(local_status(rec3, td, file.path(td, "missing_103.tsv"))$label, "超时")

  rec4 <- local_rec(td, "1000104", cancelled = TRUE)
  diann.gui:::local_jobs_add(rec4)
  expect_equal(local_status(rec4, td, file.path(td, "missing_104.tsv"))$label, "已取消")

  rec5 <- local_rec(td, "1000105", rc = "0")  # 调度完成但无本次产物
  diann.gui:::local_jobs_add(rec5)
  expect_equal(local_status(rec5, td, file.path(td, "missing_105.tsv"))$label, "待核实")

  # 未知: 本地状态文件里没有该作业, 也不提供主报告路径
  unknown <- list(jobid = "1999999", script_path = "")
  expect_equal(local_status(unknown, td, "")$label, "未知")
})

test_that("log_path: local-<ID>.out 被用于退出码/epoch (不再默认找 slurm-<ID>.out)", {
  g <- local_state_guard()
  on.exit(diann.gui::set_core_const("NOTIFY_STATE", g$old), add = TRUE)
  td <- g$dir
  jid <- "1000201"
  sd <- file.path(td, "diann_gui_scripts"); dir.create(sd, showWarnings = FALSE)
  sp <- file.path(sd, "diann_x.sh"); writeLines("#!/bin/bash", sp)
  now <- as.integer(Sys.time())
  lp <- file.path(td, sprintf("local-%s.out", jid))
  writeLines(c(sprintf("DIANN_GUI_START_EPOCH %d", now - 10), "exit code: 0",
               sprintf("DIANN_GUI_END_EPOCH %d", now)), lp)
  rep_ok <- file.path(td, "report.tsv"); writeLines(c("h", "r"), rep_ok)

  st <- diann_job_status(jid, td, rep_ok, script_path = sp, log_path = lp,
                         sacct_fn = sa_none, squeue_fn = sq_empty)
  expect_equal(st$label, "成功")
  expect_equal(st$rc, 0L)
  expect_true(isTRUE(st$artifact_new))

  # 不传 log_path 时维持 v1.11 默认 (slurm-<ID>.out): 读不到退出码 -> rc 未知
  st2 <- diann_job_status(jid, td, rep_ok, script_path = sp,
                          sacct_fn = sa_none, squeue_fn = sq_empty)
  expect_true(is.na(st2$rc))
})
