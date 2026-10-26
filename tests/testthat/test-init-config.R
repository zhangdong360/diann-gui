# init_config(): R 内生成每用户配置 (替代旧的 bin/diann-gui --init)

test_that("init_config_autofill 只替换对应注释行, 不动其它内容", {
  txt <- paste(c(
    "# APPTAINER_PATHS <- c(\"/share/app/conda/conda24/envs/apptainer/bin\")",
    "# DEFAULT_APPTAINER <- \"/x/apptainer\"",
    "# SLURM_PARTITIONS <- c(\"compute\")",
    "# SIF_DIRS <- c(\"/share/app/tools/diann\")",
    "# 其它注释保持不变"), collapse = "\n")
  out <- init_config_autofill(txt,
                              partitions = c("compute", "mgt"),
                              apptainer_dirs = c("/opt/ap/bin"),
                              default_apptainer = "/opt/ap/bin/apptainer",
                              sif_dirs = c("/share/app/tools/diann"))
  expect_match(out, 'SLURM_PARTITIONS <- c("compute", "mgt")', fixed = TRUE)
  expect_match(out, 'APPTAINER_PATHS <- c("/opt/ap/bin")', fixed = TRUE)
  expect_match(out, 'DEFAULT_APPTAINER <- "/opt/ap/bin/apptainer"', fixed = TRUE)
  expect_match(out, 'SIF_DIRS <- c("/share/app/tools/diann")', fixed = TRUE)
  expect_match(out, "# 其它注释保持不变", fixed = TRUE)
  expect_false(grepl("# SLURM_PARTITIONS", out, fixed = TRUE))
})

test_that("init_config_autofill 无探测结果时保持模板原样", {
  txt <- "# SLURM_PARTITIONS <- c(\"compute\")\n"
  expect_equal(init_config_autofill(txt), txt)
})

test_that("init_config 写文件 / 替换家目录 / 0600 / 幂等", {
  d <- file.path(tempdir(), sprintf("initcfg_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(d, showWarnings = FALSE)
  p <- file.path(d, "config.R")
  expect_equal(unname(diann.gui::init_config(p, auto = FALSE)), p)
  txt <- paste(readLines(p, warn = FALSE), collapse = "\n")
  expect_match(txt, "diann_gui 用户设置模板", fixed = TRUE)
  expect_false(grepl("DIANN_GUI_USER_HOME", txt, fixed = TRUE))
  expect_match(txt, path.expand("~"), fixed = TRUE)
  mode_dec <- as.integer(file.info(p)$mode)
  expect_equal(bitwAnd(mode_dec, 63L), 0L)  # 0600: 组/其他无权限

  # 已存在且 overwrite = FALSE: 不改动
  writeLines("USER-EDIT", p)
  diann.gui::init_config(p, auto = FALSE)
  expect_equal(readLines(p, warn = FALSE)[1], "USER-EDIT")

  # overwrite = TRUE: 覆盖
  diann.gui::init_config(p, overwrite = TRUE, auto = FALSE)
  expect_match(paste(readLines(p, warn = FALSE), collapse = "\n"), "diann_gui 用户设置模板", fixed = TRUE)
  unlink(d, recursive = TRUE)
})

test_that("init_config(auto = TRUE) 使用注入的探测结果", {
  d <- file.path(tempdir(), sprintf("initcfg_auto_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(d, showWarnings = FALSE)
  p <- file.path(d, "config.R")
  diann.gui::init_config(p, auto = TRUE, overwrite = TRUE,
                         partitions = c("compute", "mgt"),
                         apptainer_dirs = "/opt/fake/bin",
                         default_apptainer = "/opt/fake/bin/apptainer",
                         sif_dirs = "/share/app/tools/diann")
  txt <- paste(readLines(p, warn = FALSE), collapse = "\n")
  expect_match(txt, 'SLURM_PARTITIONS <- c("compute", "mgt")', fixed = TRUE)
  expect_match(txt, 'DEFAULT_APPTAINER <- "/opt/fake/bin/apptainer"', fixed = TRUE)
  expect_match(txt, 'SIF_DIRS <- c("/share/app/tools/diann")', fixed = TRUE)
  unlink(d, recursive = TRUE)
})
