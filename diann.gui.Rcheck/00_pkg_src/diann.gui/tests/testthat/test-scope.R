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

# ---- 包化后的配置内核契约 ----
test_that("diann_load_config 默认 = 用户家目录模式", {
  home <- file.path(tempdir(), sprintf("cfg_home_%d", Sys.getpid()))
  dir.create(home, recursive = TRUE, showWarnings = FALSE)
  old_home <- Sys.getenv("HOME"); Sys.setenv(HOME = home)
  old_cfg <- Sys.getenv("DIANN_GUI_CONFIG"); Sys.unsetenv("DIANN_GUI_CONFIG")
  old_xv <- Sys.getenv("DIANN_GUI_EXTRA_VOLUMES"); Sys.unsetenv("DIANN_GUI_EXTRA_VOLUMES")
  on.exit({ Sys.setenv(HOME = old_home, DIANN_GUI_CONFIG = old_cfg,
                       DIANN_GUI_EXTRA_VOLUMES = old_xv); diann_load_config(reset = TRUE) }, add = TRUE)
  diann_load_config(reset = TRUE)
  expect_equal(cfg_get("DATA_HOME"), home)
  expect_equal(names(cfg_get("BASE_VOLUMES")), "Data")
  expect_equal(cfg_get("SIF_DIRS"), character(0))
  expect_false(isTRUE(cfg_get("MAIL_ENABLED")))  # 无 mail_config → 邮件停用
})

test_that("配置文件可覆写默认值, DIANN_GUI_CONFIG 优先级最高", {
  dir <- tempdir()
  usr <- file.path(dir, ".diann_gui"); dir.create(usr, recursive = TRUE, showWarnings = FALSE)
  cfg_user <- file.path(usr, "config.R"); writeLines('DATA_HOME <- "/from/user-home"', cfg_user)
  cfg_env  <- file.path(dir, "cfg_env.R");  writeLines('DATA_HOME <- "/from/env"', cfg_env)
  old_home <- Sys.getenv("HOME"); Sys.setenv(HOME = dir)
  old_cfg <- Sys.getenv("DIANN_GUI_CONFIG"); Sys.unsetenv("DIANN_GUI_CONFIG")
  on.exit({ Sys.setenv(HOME = old_home, DIANN_GUI_CONFIG = old_cfg); diann_load_config(reset = TRUE) }, add = TRUE)
  diann_load_config(reset = TRUE)
  expect_equal(cfg_get("DATA_HOME"), "/from/user-home")
  Sys.setenv(DIANN_GUI_CONFIG = cfg_env)
  diann_load_config(reset = TRUE)
  expect_equal(cfg_get("DATA_HOME"), "/from/env")
})

test_that("DIANN_GUI_EXTRA_VOLUMES 追加路径守卫根 (e2e/CI 钩子)", {
  old_xv <- Sys.getenv("DIANN_GUI_EXTRA_VOLUMES")
  Sys.setenv(DIANN_GUI_EXTRA_VOLUMES = "/share/home/demo")
  on.exit({ Sys.setenv(DIANN_GUI_EXTRA_VOLUMES = old_xv); diann_load_config(reset = TRUE) }, add = TRUE)
  diann_load_config(reset = TRUE)
  bv <- cfg_get("BASE_VOLUMES")
  expect_true("/share/home/demo" %in% bv)
  set_core_const("BASE_VOLUMES", bv)
  expect_true(path_in_scope("/share/home/demo/lib/demo.speclib"))
})
