# v1.13: 参数速查文档快照带 attribution 头注; 解析器须兼容且仍能解析全部参数

test_that("inst 快照带 attribution 头注 (来源/版权/不再许可声明)", {
  p <- system.file("docs", "DIANN_param_reference.md", package = "diann.gui")
  expect_true(nzchar(p))
  head_txt <- paste(readLines(p, n = 12, warn = FALSE), collapse = "\n")
  expect_match(head_txt, "vdemichev/DiaNN", fixed = TRUE)
  expect_match(head_txt, "Copyright (c) DIA-NN authors", fixed = TRUE)
  expect_match(head_txt, "NOT relicensed", fixed = TRUE)
})

test_that("parse_param_doc 兼容头注且能解析出大量参数 (含 --about)", {
  p <- system.file("docs", "DIANN_param_reference.md", package = "diann.gui")
  df <- parse_param_doc(p)
  expect_s3_class(df, "data.frame")
  expect_gt(nrow(df), 100)
  expect_true("--about" %in% df$flag)
  expect_true(all(grepl("^--", df$flag)))
})

test_that("parse_param_doc: 前置噪声行再多也能找到首个 <li> 行", {
  f <- tempfile("pd"); on.exit(unlink(f))
  writeLines(c("noise1", "noise2", "", "<li><strong>--demo</strong>demo flag</li>"), f)
  df <- parse_param_doc(f)
  expect_equal(df$flag, "--demo")
  expect_equal(df$desc, "demo flag")
})
