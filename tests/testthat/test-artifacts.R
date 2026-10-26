# archive_stale_artifacts(): 提交前归档旧主报告/矩阵
# 2026-10 审查: 原实现把用户报告名拼进 list.files 正则, report 名为 "report[1]" 时
# 提交直接抛 "invalid 'pattern' regular expression"; 名为 "." 时会批量改名目录内全部 tsv。

mk_art_dir <- function() {
  d <- file.path(tempdir(), sprintf("art_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  d
}
touch <- function(dir, name, size = 10L) {
  p <- file.path(dir, name)
  writeBin(as.raw(rep(0x41, size)), p)
  p
}

test_that("归档同名主报告与矩阵, 其它 tsv 不受影响", {
  d <- mk_art_dir()
  main <- touch(d, "report.tsv")
  mat <- touch(d, "report.matrix.tsv")
  other <- touch(d, "other.tsv")
  empty <- touch(d, "report.pre_20200101_000000.tsv")  # 已归档的旧文件不再重复归档
  empty_m <- touch(d, "report.matrix.pre_20200101_000000.tsv")
  old_m <- touch(d, "old_matrix.tsv")

  res <- archive_stale_artifacts(d, file.path(d, "report.tsv"))
  expect_equal(nrow(res), 2L)
  expect_setequal(res$from, c("report.tsv", "report.matrix.tsv"))
  expect_false(file.exists(main))
  expect_false(file.exists(mat))
  expect_true(file.exists(other))
  expect_true(file.exists(empty))
  expect_true(file.exists(empty_m))
  expect_true(file.exists(old_m))
  expect_true(all(file.exists(file.path(d, res$to))))
})

test_that("报告名含正则元字符时不报错且只归档精确匹配", {
  d <- mk_art_dir()
  for (nm in c("rep(1).tsv", "report[1].tsv", "a+b.tsv", "x.y.tsv")) touch(d, nm)
  touch(d, "report1.tsv")  # 不应被 rep(1) 误伤

  expect_silent(res1 <- archive_stale_artifacts(d, file.path(d, "rep(1).tsv")))
  expect_equal(nrow(res1), 1L)
  expect_silent(res2 <- archive_stale_artifacts(d, file.path(d, "report[1].tsv")))
  expect_equal(nrow(res2), 1L)
  expect_true(file.exists(file.path(d, "report1.tsv")))
})

test_that("报告名为 '.' 时不误伤其它 tsv", {
  d <- mk_art_dir()
  keep <- touch(d, "report.tsv")
  touch(d, "something.tsv")
  res <- archive_stale_artifacts(d, file.path(d, "."))  # base = "." -> 只匹配 "..tsv"
  expect_equal(nrow(res), 0L)
  expect_true(file.exists(keep))
  expect_true(file.exists(file.path(d, "something.tsv")))
})

test_that("空参数/不存在的目录安全返回空表", {
  empty <- data.frame(from = character(0), to = character(0), stringsAsFactors = FALSE)
  expect_equal(archive_stale_artifacts("", ""), empty)
  expect_equal(archive_stale_artifacts("/nonexistent/dir", "/nonexistent/dir/r.tsv"), empty)
  d <- mk_art_dir()
  expect_equal(archive_stale_artifacts(d, ""), empty)
})

test_that("0 字节旧产物不归档", {
  d <- mk_art_dir()
  p <- touch(d, "report.tsv", size = 0L)
  res <- archive_stale_artifacts(d, file.path(d, "report.tsv"))
  expect_equal(nrow(res), 0L)
  expect_true(file.exists(p))
})

test_that("safe_job_name: 路径分隔符/换行被替换, 空值兜底, 长度受限", {
  expect_equal(safe_job_name("DIANN_Task"), "DIANN_Task")
  expect_equal(safe_job_name("a/b"), "a-b")
  expect_equal(safe_job_name("a\\b"), "a-b")
  expect_equal(safe_job_name("a\nb"), "a b")
  expect_equal(safe_job_name("..evil"), "evil")
  expect_equal(safe_job_name("   "), "DIANN_Task")
  expect_equal(safe_job_name(NULL), "DIANN_Task")
  expect_equal(safe_job_name("小鼠_样品A"), "小鼠_样品A")
  expect_equal(nchar(safe_job_name(strrep("x", 100))), 64L)
})

test_that("cleanup_old_artifacts: 按 mtime 清理过期脚本/归档, 保留新文件", {
  d <- mk_art_dir()
  sd <- file.path(d, "diann_gui_scripts"); dir.create(sd, showWarnings = FALSE)
  old_sh <- touch(sd, "diann_old.sh")
  old_rc <- touch(sd, "diann_old.rc")
  old_desc <- touch(sd, "diann_old_desc.txt")
  new_sh <- touch(sd, "diann_new.sh")
  old_arc <- touch(d, "report.pre_20200101_000000.tsv")
  new_arc <- touch(d, "report.pre_20990101_000000.tsv")
  Sys.setFileTime(c(old_sh, old_rc, old_desc, old_arc), as.numeric(Sys.time()) - 100 * 86400)

  expect_equal(cleanup_old_artifacts(d, days = 90), 4L)
  expect_false(file.exists(old_sh))
  expect_false(file.exists(old_rc))
  expect_false(file.exists(old_desc))
  expect_false(file.exists(old_arc))
  expect_true(file.exists(new_sh))
  expect_true(file.exists(new_arc))
  expect_equal(cleanup_old_artifacts(d, days = 0), 0L)  # 0 = 关闭
  expect_equal(cleanup_old_artifacts("/nonexistent/dir", days = 90), 0L)
})
