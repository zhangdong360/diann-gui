# 包级自托管: 只装用户库 + library + run_app() 即可运行 (不依赖仓库目录/shell 脚本)

test_that("run_app 暴露 app_only 参数, 供嵌入/legacy 使用", {
  expect_true("app_only" %in% names(formals(diann.gui::run_app)))
})

test_that("run_app(app_only = TRUE) 在任意工作目录返回 shiny.appobj", {
  old_home <- Sys.getenv("HOME")
  old_wd <- getwd()
  td <- file.path(tempdir(), sprintf("pkgonly_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(td, showWarnings = FALSE, recursive = TRUE)
  Sys.setenv(HOME = td)
  setwd(td)
  on.exit({
    setwd(old_wd)
    Sys.setenv(HOME = old_home)
    diann_load_config(reset = TRUE)
  }, add = TRUE)
  diann_load_config(reset = TRUE)

  app <- diann.gui::run_app(app_only = TRUE)
  expect_s3_class(app, "shiny.appobj")
  # 包内资源从 system.file 读取, 不依赖 getwd()
  expect_true(nzchar(diann.gui:::param_doc_path()))
  # 状态目录落在本次 HOME 下 (每用户隔离)
  expect_true(startsWith(diann.gui::cfg_get("NOTIFY_STATE"), td))
})

test_that("init_config + doctor 在包安装状态下可用", {
  old_home <- Sys.getenv("HOME")
  td <- file.path(tempdir(), sprintf("pkgcfg_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(td, showWarnings = FALSE, recursive = TRUE)
  Sys.setenv(HOME = td)
  on.exit({ Sys.setenv(HOME = old_home); diann_load_config(reset = TRUE) }, add = TRUE)

  p <- suppressMessages(diann.gui::init_config(file.path(td, ".diann_gui", "config.R"), auto = FALSE))
  expect_true(file.exists(p))

  df <- suppressMessages(capture.output(
    d <- diann.gui::doctor(apptainer_cands = data.frame(
      path = character(0), kind = character(0), source = character(0), version = character(0),
      ok = logical(0), checked_at = numeric(0), stringsAsFactors = FALSE),
      partitions = "compute", slurm_cmds = c(sbatch = "/usr/bin/sbatch"),
      sif_dirs = character(0), mail_conf = "/nonexistent", state_dir = td,
      deps = character(0))))
  expect_equal(d$status[d$check == "状态目录"], "ok")
})

# ---------- v1.12: 本地后端下 app 构建 (UI 条件渲染) ----------

test_that("本地后端: run_app(app_only=TRUE) 构建 local 版 UI (按钮/标题/无 sinfo)", {
  old_home <- Sys.getenv("HOME")
  old_env <- Sys.getenv("DIANN_GUI_EXEC_BACKEND", unset = NA_character_)
  old_wd <- getwd()
  td <- file.path(tempdir(), sprintf("pkgonly_local_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(td, showWarnings = FALSE, recursive = TRUE)
  Sys.setenv(HOME = td)
  Sys.setenv(DIANN_GUI_EXEC_BACKEND = "local")
  setwd(td)
  on.exit({
    setwd(old_wd)
    if (is.na(old_env)) Sys.unsetenv("DIANN_GUI_EXEC_BACKEND") else Sys.setenv(DIANN_GUI_EXEC_BACKEND = old_env)
    Sys.setenv(HOME = old_home)
    diann_load_config(reset = TRUE)
  }, add = TRUE)
  diann_load_config(reset = TRUE)

  expect_equal(exec_backend(), "local")
  expect_match(backend_label(), "本地")
  app <- diann.gui::run_app(app_only = TRUE)
  expect_s3_class(app, "shiny.appobj")
  # shiny.appobj 不保留 ui (names(app) 无 ui): 直接渲染包内 UI 构建函数验证条件渲染
  ui_obj <- diann.gui:::app_ui()
  expect_s3_class(ui_obj, "shiny.tag")
  html <- paste(as.character(htmltools::renderTags(ui_obj)$html), collapse = "")
  expect_match(html, "提交本地任务", fixed = TRUE)
  expect_match(html, "本地运行任务", fixed = TRUE)
  expect_match(html, "执行后端: 本地单机", fixed = TRUE)
  expect_false(grepl("sinfo_table", html, fixed = TRUE))
  expect_true(grepl("local-&lt;ID&gt;.out", html, fixed = TRUE))
  # 包内自带本地运行器 (R CMD INSTALL 后 inst/scripts 就位)
  runner <- diann.gui:::local_runner_path()
  expect_true(nzchar(runner))
  expect_true(file.exists(runner))
})

test_that("Slurm 模式 app 构建保持原样 (按钮/标题/含 sinfo)", {
  old_home <- Sys.getenv("HOME")
  old_env <- Sys.getenv("DIANN_GUI_EXEC_BACKEND", unset = NA_character_)
  old_wd <- getwd()
  td <- file.path(tempdir(), sprintf("pkgonly_slurm_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(td, showWarnings = FALSE, recursive = TRUE)
  Sys.setenv(HOME = td)
  Sys.setenv(DIANN_GUI_EXEC_BACKEND = "slurm")
  setwd(td)
  on.exit({
    setwd(old_wd)
    if (is.na(old_env)) Sys.unsetenv("DIANN_GUI_EXEC_BACKEND") else Sys.setenv(DIANN_GUI_EXEC_BACKEND = old_env)
    Sys.setenv(HOME = old_home)
    diann_load_config(reset = TRUE)
  }, add = TRUE)
  diann_load_config(reset = TRUE)

  expect_equal(exec_backend(), "slurm")
  app <- diann.gui::run_app(app_only = TRUE)
  expect_s3_class(app, "shiny.appobj")
  ui_obj <- diann.gui:::app_ui()
  html <- paste(as.character(htmltools::renderTags(ui_obj)$html), collapse = "")
  expect_match(html, "提交 Slurm 任务", fixed = TRUE)
  expect_match(html, "运行队列 (squeue)", fixed = TRUE)
  expect_match(html, "sinfo_table", fixed = TRUE)
})
