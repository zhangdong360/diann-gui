# 参数速查文档解析: v1.13 起快照不随包分发 (许可归属 DIA-NN 作者), 只解析
# 工作目录下的 DIANN_param_reference.md; 头注 (HTML 注释) 不破坏解析

test_that("param_doc_candidates: 只回退工作目录文件", {
  old_wd <- getwd()
  d <- tempfile("pdcand"); dir.create(d, showWarnings = FALSE)
  setwd(d); on.exit(setwd(old_wd), add = TRUE)
  expect_identical(param_doc_candidates(), file.path(d, "DIANN_param_reference.md"))
  expect_equal(param_doc_path(), "")
  writeLines("<li><strong>--demo</strong>x</li>", file.path(d, "DIANN_param_reference.md"))
  expect_equal(normalizePath(param_doc_path(), mustWork = FALSE),
               normalizePath(file.path(d, "DIANN_param_reference.md"), mustWork = FALSE))
})

test_that("parse_param_doc: 头注 (HTML 注释) 不破坏解析", {
  f <- tempfile("pd"); on.exit(unlink(f))
  writeLines(c("<!--",
               "Vendored DIA-NN parameter reference snapshot.",
               "Copyright (c) DIA-NN authors; not relicensed under diann.gui's MIT license.",
               "Retrieved: 2026-10-13.",
               "-->",
               "", "### Command-line reference", "",
               # 真实快照是单行超长 HTML: 两个条目在同一行 (解析器按行工作)
               "<li><strong>--about</strong>display information with basic links</li><li><strong>--fwhm</strong> (Enterprise edition) fwhm for centroiding</li>"), f)
  df <- parse_param_doc(f)
  expect_s3_class(df, "data.frame")
  expect_setequal(df$flag, c("--about", "--fwhm"))
  expect_match(df$desc[df$flag == "--about"], "display information")
})

test_that("parse_param_doc: 前置噪声行再多也能找到首个 <li> 行", {
  f <- tempfile("pd2"); on.exit(unlink(f))
  writeLines(c("noise1", "noise2", "", "<li><strong>--demo</strong>demo flag</li>"), f)
  df <- parse_param_doc(f)
  expect_equal(df$flag, "--demo")
  expect_equal(df$desc, "demo flag")
})

test_that("快照文件确已移出包分发", {
  expect_false(file.exists(system.file("docs", "DIANN_param_reference.md", package = "diann.gui")))
})
