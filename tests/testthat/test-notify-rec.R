# 通知状态文件: 锁 + 原子写 + 记录字段 (临时 HOME, 不碰真实队列)
test_that("mkdir 锁互斥并可释放", {
  expect_true(notify_lock_acquire(timeout = 2))
  expect_false(notify_lock_acquire(timeout = 1))
  notify_lock_release()
  expect_true(notify_lock_acquire(timeout = 2))
  notify_lock_release()
})

test_that("diann_notify_add 补默认字段, save/load 往返一致", {
  unlink(c(NOTIFY_STATE, paste0(NOTIFY_STATE, ".lock")), recursive = TRUE, force = TRUE)
  set_core_const("MAIL_ENABLED", TRUE)  # 临时打开闸门 (add 只检查标志, 不真正发信)
  on.exit(set_core_const("MAIL_ENABLED", FALSE), add = TRUE)
  diann_notify_add(list(jobid = "101", to = "a@b.c", task = "T", out_dir = "/o",
                        out_file = "/o/report.tsv", sif = "/x.sif",
                        script_path = "/o/s.sh", desc_file = ""))
  st <- diann_notify_load()
  expect_length(st$recs, 1)
  r <- st$recs[[1]]
  expect_identical(as.character(r$jobid), "101")
  expect_false(r$done)
  expect_equal(r$attempts, 0L)
  expect_true(nzchar(r$submitted))
  # 新记录插最前
  diann_notify_add(list(jobid = "102", to = "a@b.c", task = "T2", out_dir = "/o",
                        out_file = "/o/report.tsv", sif = "/x.sif",
                        script_path = "/o/s2.sh", desc_file = ""))
  st2 <- diann_notify_load()
  expect_equal(as.character(st2$recs[[1]]$jobid), "102")
  unlink(c(NOTIFY_STATE, paste0(NOTIFY_STATE, ".lock")), recursive = TRUE, force = TRUE)
})

test_that("损坏的状态文件安全回退为空", {
  writeLines("not an rds", NOTIFY_STATE)
  st <- diann_notify_load()
  expect_equal(length(st$recs), 0)
  unlink(NOTIFY_STATE, force = TRUE)
})

test_that("notify_defer_unknown: 未知状态在 3 轮内延后发送, 之后才退化", {
  st <- list(label = "未知")
  expect_true(notify_defer_unknown(st, 0))
  expect_true(notify_defer_unknown(st, 2))
  expect_false(notify_defer_unknown(st, 3))
  expect_false(notify_defer_unknown(list(label = "成功"), 0))
  expect_false(notify_defer_unknown(NULL, 0))
})

test_that("watcher_spawn_command: 显式带用户库路径与配置文件", {
  cmd <- watcher_spawn_command(state = "/tmp/s.rds", pidfile = "/tmp/s.pid",
                               logf = "/tmp/s.log", cfg_file = "/tmp/c.R")
  expect_match(cmd, "DIANN_GUI_CONFIG='/tmp/c.R'", fixed = TRUE)
  expect_match(cmd, ".libPaths(c(", fixed = TRUE)
  expect_match(cmd, "watch_daemon", fixed = TRUE)
  expect_match(cmd, "--no-save --slave", fixed = TRUE)
  expect_match(cmd, "< /dev/null &", fixed = TRUE)
  cmd2 <- watcher_spawn_command(state = "/tmp/s.rds", pidfile = "/tmp/s.pid",
                                logf = "/tmp/s.log", cfg_file = "")
  expect_false(grepl("DIANN_GUI_CONFIG", cmd2, fixed = TRUE))
})
