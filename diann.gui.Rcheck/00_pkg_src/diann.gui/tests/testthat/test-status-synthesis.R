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
