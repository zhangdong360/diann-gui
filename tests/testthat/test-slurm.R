# Slurm 查询收敛: 一次 squeue + 一次 sacct, 20 s 缓存, 供监控页/通知面板共用

test_that("slurm_snapshot: 解析 squeue/sacct 并复用缓存", {
  calls <- 0L
  sq <- function(u) { calls <<- calls + 1L; c("101|taskA|RUNNING|1:23|(Priority)",
                                              "102|taskB|PENDING|0:00|(Resources)") }
  sa <- function(u) c("101|taskA|COMPLETED|1:23|2026-10-20T10:00:00",
                      "103|taskC|FAILED|0:05|2026-10-20T11:00:00")
  s1 <- slurm_snapshot(user = "u", refresh = TRUE, squeue_fun = sq, sacct_fun = sa)
  expect_equal(calls, 1L)
  expect_equal(length(s1$lines), 2L)
  expect_equal(s1$squeue_map[["101"]], "RUNNING")
  expect_equal(s1$squeue_map[["102"]], "PENDING")
  expect_equal(s1$sacct_map[["103"]], "FAILED")
  # 缓存: 未过期不再调用
  s2 <- slurm_snapshot(user = "u", max_age = 20, squeue_fun = sq, sacct_fun = sa, refresh = FALSE)
  expect_equal(calls, 1L)
  expect_identical(s1$at, s2$at)
  # 强制刷新
  slurm_snapshot(user = "u", refresh = TRUE, squeue_fun = sq, sacct_fun = sa)
  expect_equal(calls, 2L)
})

test_that("slurm_snapshot_fns 让 diann_job_status 不再起子进程", {
  snap <- list(squeue_map = list("7" = "RUNNING"), sacct_map = list("8" = "COMPLETED"),
               lines = character(0), sacct_lines = character(0), at = 0)
  fns <- slurm_snapshot_fns(snap)
  expect_equal(fns$squeue_fn(7), "RUNNING")
  expect_equal(fns$sacct_fn(8), "8|COMPLETED")
  expect_length(fns$squeue_fn(999), 0)
  expect_length(fns$sacct_fn(999), 0)
})

test_that("slurm_queue_states: 一次查询返回 jobid -> 状态", {
  n <- 0L
  sq <- function(u) { n <<- n + 1L; c("1|a|RUNNING|0:01|x", "2|b|PENDING|0:00|y") }
  m <- slurm_queue_states(user = "u2", squeue_fun = sq)
  expect_equal(n, 1L)
  expect_equal(m[["1"]], "RUNNING")
  expect_equal(m[["2"]], "PENDING")
})
