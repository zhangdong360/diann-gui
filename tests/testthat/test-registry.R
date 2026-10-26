# jobs_registry_add(): 注册表滚动保留最近 300 条
# 2026-10 审查: 原实现 rbind 后 head(df, 300) 保留的是最旧的 300 条,
# 第 301 次提交起新记录会被静默丢弃 (月报/日志定位从此看不到新作业)。

registry_file <- function() diann.gui:::jobs_registry_file()

seed_registry <- function(ids) {
  f <- registry_file()
  unlink(f)
  df <- data.frame(jobid = as.character(ids), 任务名 = "T", 输出目录 = "/o",
                   日志 = "/o/slurm-x.out", 提交时间 = "2026-01-01 00:00:00",
                   stringsAsFactors = FALSE)
  saveRDS(df, f)
  invisible(f)
}

test_that("超过 300 条时保留最新记录, 最旧一条被淘汰", {
  seed_registry(1:300)
  expect_true(diann.gui:::jobs_registry_add("301", "T301", "/o"))
  got <- diann.gui:::jobs_registry_load()
  expect_equal(nrow(got), 300L)
  expect_equal(got$jobid[nrow(got)], "301")     # 新记录必须在
  expect_equal(got$jobid[1], "2")                # 最旧的 "1" 被淘汰
  expect_true(all(c("300", "301") %in% got$jobid))
  unlink(registry_file())
})

test_that("同 JobID 重新提交覆盖旧记录且不重复", {
  seed_registry(1:299)
  expect_true(diann.gui:::jobs_registry_add("299", "T299-new", "/o2"))
  got <- diann.gui:::jobs_registry_load()
  expect_equal(nrow(got), 299L)
  expect_equal(sum(got$jobid == "299"), 1L)
  expect_equal(got$任务名[got$jobid == "299"], "T299-new")
  unlink(registry_file())
})

test_that("损坏的注册表安全回退为空表并可继续写入", {
  f <- registry_file()
  unlink(f)
  writeLines("not an rds", f)
  expect_equal(nrow(diann.gui:::jobs_registry_load()), 0L)
  expect_true(diann.gui:::jobs_registry_add("7", "T7", "/o"))
  got <- diann.gui:::jobs_registry_load()
  expect_equal(nrow(got), 1L)
  expect_equal(got$jobid, "7")
  unlink(f)
})
