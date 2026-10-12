# collapse_dots / path_in_scope: 路径范围守卫
test_that("collapse_dots 词法折叠 .. 与 . (前导 .. 保守保留, 由 normalizePath 兜底)", {
  expect_equal(collapse_dots("/a/b/../c"), "/a/c")
  expect_equal(collapse_dots("/a/./b/"), "/a/b")
  expect_equal(collapse_dots("/a/../../b"), "/../b")
  expect_equal(collapse_dots("rel/../x"), "x")
})

test_that("path_in_scope 接受根内路径, 拒绝根外与越界穿越", {
  root <- tempfile("scope_root_"); dir.create(root, showWarnings = FALSE)
  set_core_const("BASE_VOLUMES", c(Data = root))
  expect_true(path_in_scope(file.path(root, "x/y.tsv")))
  expect_true(path_in_scope(root))
  expect_false(path_in_scope("/etc/passwd"))
  expect_false(path_in_scope(file.path(root, "..", "escape")))
  expect_false(path_in_scope(sub("/[^/]+$", "", root)))  # 父目录: 前缀但不整段
  expect_identical(path_in_scope(c(root, "/tmp")), c(TRUE, FALSE))
  expect_false(path_in_scope(""))
  # 前缀边界: /rootX 不得因 startsWith 误判为根内
  sibling <- paste0(root, "X")
  expect_false(path_in_scope(sibling))
})

test_that("空向量安全返回", {
  set_core_const("BASE_VOLUMES", c(Data = tempdir()))
  expect_identical(path_in_scope(character(0)), logical(0))
})

test_that("diann_core 以 local=<app环境> source 后, 函数闭包能看到同环境的站点常量 (回归: app.R source 的环境契约, 违反时导入真实路径即断连)", {
  e <- new.env(parent = globalenv())
  e$CON_FASTA <- ""
  e$BASE_VOLUMES <- c(Data = tempdir())
  e$APPTAINER_PATHS <- character(0)
  e$APPTAINER_MODULE_FALLBACK <- ""
  e$BIND_PATHS <- character(0)
  source(file.path(PROJECT_ROOT, "diann_core.R"), local = e)
  expect_true(e$path_in_scope(file.path(tempdir(), "x.tsv")))
  expect_error(e$path_in_scope("/etc/passwd"), NA)
})

test_that("拆分模块 (changelog_data.R / ui_params.R) 同样遵守 local=<app环境> 契约, 且不泄漏到 globalenv", {
  skip_if_not_installed("shiny")
  suppressMessages(library(shiny))
  e <- new.env(parent = globalenv())
  e$CON_FASTA <- ""
  e$BASE_VOLUMES <- c(Data = tempdir())
  e$APPTAINER_PATHS <- character(0)
  e$APPTAINER_MODULE_FALLBACK <- ""
  e$BIND_PATHS <- character(0)
  source(file.path(PROJECT_ROOT, "diann_core.R"), local = e)
  source(file.path(PROJECT_ROOT, "changelog_data.R"), local = e)
  source(file.path(PROJECT_ROOT, "ui_params.R"), local = e)
  expect_true(exists("CHANGELOG", envir = e, inherits = FALSE))
  expect_true(exists("DIANN_RELEASE_NOTES", envir = e, inherits = FALSE))
  expect_true(exists("param_tabs_ui", envir = e, inherits = FALSE))
  expect_s3_class(e$param_tabs_ui(), "shiny.tag")
  expect_true(inherits(e$PARAM_CSS_TAG, "shiny.tag"))
  expect_false(exists("CHANGELOG", envir = globalenv(), inherits = FALSE))
  expect_false(exists("param_tabs_ui", envir = globalenv(), inherits = FALSE))
})
