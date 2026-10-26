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

# ---------- v1.12 schema v3: backend/pid 列 + 后端日志契约 ----------

test_that("v3 写入: backend/pid 落盘, 日志列按后端契约生成 (local-<id>.out)", {
  unlink(registry_file())
  expect_true(diann.gui:::jobs_registry_add("1000001", "L1", "/o", backend = "local", pid = 4321))
  got <- diann.gui:::jobs_registry_load()
  expect_true(all(c("backend", "pid") %in% names(got)))
  expect_equal(got$backend[got$jobid == "1000001"], "local")
  expect_equal(got$pid[got$jobid == "1000001"], "4321")
  expect_equal(got$日志[got$jobid == "1000001"], "/o/local-1000001.out")
  # 显式 log 优先 (提交方已知道真实路径时不被契约覆盖)
  expect_true(diann.gui:::jobs_registry_add("1000002", "L2", "/o", backend = "local",
                                            log = "/x/custom.out"))
  got <- diann.gui:::jobs_registry_load()
  expect_equal(got$日志[got$jobid == "1000002"], "/x/custom.out")
  # 缺省 = slurm, 日志仍是 slurm-<id>.out; 非法 backend 归一为 slurm; pid NA 保持 NA
  expect_true(diann.gui:::jobs_registry_add("777", "S", "/o"))
  expect_true(diann.gui:::jobs_registry_add("778", "S2", "/o", backend = "cloud", pid = NA))
  got <- diann.gui:::jobs_registry_load()
  expect_equal(got$backend[got$jobid == "777"], "slurm")
  expect_equal(got$日志[got$jobid == "777"], "/o/slurm-777.out")
  expect_equal(got$backend[got$jobid == "778"], "slurm")
  expect_true(is.na(got$pid[got$jobid == "778"]))
  unlink(registry_file())
})

test_that("v2 注册表可读: 缺 backend/pid 列补 NA, 行数据不丢 (旧记录按 slurm 解释)", {
  f <- registry_file()
  unlink(f)
  df <- data.frame(jobid = c("11", "12"), 任务名 = c("A", "B"), 输出目录 = "/o",
                   日志 = c("/o/slurm-11.out", "/o/slurm-12.out"),
                   提交时间 = c("2026-01-01 00:00:00", "2026-01-02 00:00:00"),
                   script_path = c("/o/a.sh", "/o/b.sh"), out_file = c("/o/a.tsv", "/o/b.tsv"),
                   sif = "/x.sif", apptainer = "/opt/ap", 版本 = "2.7.0",
                   stringsAsFactors = FALSE)
  saveRDS(df, f)
  got <- diann.gui:::jobs_registry_load()
  expect_equal(nrow(got), 2L)
  expect_true(all(is.na(got$backend)))
  expect_true(all(is.na(got$pid)))
  expect_equal(got$jobid, c("11", "12"))
  expect_equal(got$script_path, c("/o/a.sh", "/o/b.sh"))
  unlink(f)
})
