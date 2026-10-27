# v1.14 任务队列 ↔ 结果分析闭环: 输出目录矩阵发现

test_that("analysis_find_matrices: pg_matrix 优先、排除归档/空文件/主报告", {
  d <- file.path(tempdir(), sprintf("anlink_%d", as.integer(Sys.time())))
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(d, recursive = TRUE), add = TRUE)
  # 主报告 (前体级, 非矩阵) — 不应入选
  writeLines(c("Protein.Names", "P1"), file.path(d, "report.tsv"))
  # 两个矩阵候选: pg_matrix 与 precursor_matrix, 前者优先
  writeLines(c("Protein.Group", "P1"), file.path(d, "report.pg_matrix.tsv"))
  Sys.setFileTime(file.path(d, "report.pg_matrix.tsv"), as.numeric(Sys.time()) - 100)
  writeLines(c("Precursor.Id", "1"), file.path(d, "report.precursor_matrix.tsv"))
  Sys.setFileTime(file.path(d, "report.precursor_matrix.tsv"), as.numeric(Sys.time()))
  # 归档 (.pre_) 与空文件 — 不应入选
  writeLines(c("Protein.Group", "P1"), file.path(d, "report.pg_matrix.pre_20260101_000000.tsv"))
  writeLines(character(0), file.path(d, "report.empty_matrix.tsv"))

  ms <- analysis_find_matrices(d)
  expect_identical(basename(ms$path[1]), "report.pg_matrix.tsv")
  expect_identical(basename(ms$path[2]), "report.precursor_matrix.tsv")
  expect_false(any(grepl("\\.pre_", basename(ms$path))))
  expect_false(any(grepl("empty_matrix", basename(ms$path))))
  expect_false("report.tsv" %in% basename(ms$path))
  expect_true(all(ms$size > 0))
})

test_that("analysis_find_matrices: 目录不存在/无矩阵返回空表", {
  e <- analysis_find_matrices("/nonexistent_dir_xyz")
  expect_identical(nrow(e), 0L)
  d <- file.path(tempdir(), sprintf("anlink2_%d", as.integer(Sys.time())))
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(d, recursive = TRUE), add = TRUE)
  writeLines(c("Protein.Names", "P1"), file.path(d, "report.tsv"))
  expect_identical(nrow(analysis_find_matrices(d)), 0L)
})
