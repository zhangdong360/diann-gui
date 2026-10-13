# ============================================================
# config.R — 配置内核: 加载用户/站点配置到包内环境 .cfg
#
# 配置发现顺序 (resolve_user_config):
#   1. 环境变量 DIANN_GUI_CONFIG 指定的文件 —— 程序化注入点, 供一键部署使用
#   2. ~/.diann_gui/config.R —— 每用户设置面 (模板 inst/config/config.example.R)
#   3. <工作目录>/config.R —— 中央 shiny-server 部署沿用
# 均不存在时使用内置默认 = "用户家目录模式": 数据/输出归当前用户, 作业以本人提交。
#
# 访问: cfg_get(key) 读; set_core_const(key, value) 写 (测试与站点注入接口)。
# diann-core 等模块的站点常量 (BASE_VOLUMES/CON_FASTA/APPTAINER_*/BIND_PATHS)
# 一律经 cfg_get 读取, 不再依赖散文件的闭包环境。
# ============================================================

.cfg <- new.env(parent = emptyenv())

#' 解析配置文件路径 (env → 每用户 → 工作目录), 找不到返回 ""
#' @export
resolve_user_config <- function(dir = getwd()) {
  env <- Sys.getenv("DIANN_GUI_CONFIG")
  if (nzchar(env) && file.exists(env)) return(normalizePath(env, mustWork = FALSE))
  user_cfg <- file.path(path.expand("~"), ".diann_gui", "config.R")
  if (file.exists(user_cfg)) return(user_cfg)
  local_cfg <- file.path(dir, "config.R")
  if (file.exists(local_cfg)) return(local_cfg)
  ""
}

#' 读取配置值
#' @export
cfg_get <- function(key, default = NULL) {
  if (exists(key, envir = .cfg, inherits = FALSE)) return(get(key, envir = .cfg, inherits = FALSE))
  default
}

#' 写入配置值 (测试与站点注入接口)
#' @export
set_core_const <- function(key, value) assign(key, value, envir = .cfg)

#' 加载配置文件并合并默认值 (幂等: 重复调用以后一次为准)
#'
#' @param file 配置文件路径; NULL = 自动发现 (resolve_user_config)
#' @export
diann_load_config <- function(file = NULL, reset = FALSE) {
  if (reset) rm(list = ls(.cfg, all.names = TRUE), envir = .cfg)
  file <- file %||% resolve_user_config()
  .cfg$CONFIG_FILE <- file
  if (nzchar(file) && file.exists(file)) {
    # scratch 环境挂 baseenv: 隔离全局命名空间, 又让配置里的 <- / c() 等基础函数可用
    scratch <- new.env(parent = baseenv())
    source(file, local = scratch)
    for (k in c("SIF_DIRS", "DEFAULT_SIF", "DATA_HOME", "BASE_VOLUMES", "CON_FASTA",
                "SHARED_GROUP", "SLURM_PARTITIONS", "APPTAINER_PATHS",
                "APPTAINER_MODULE_FALLBACK", "BIND_PATHS", "MAIL_PYTHON")) {
      if (exists(k, envir = scratch, inherits = FALSE)) {
        assign(k, get(k, envir = scratch, inherits = FALSE), envir = .cfg)
      }
    }
  }

  # ---- 默认值 (与 app.R 时代逐项一致) ----
  if (is.null(.cfg$SIF_DIRS)) .cfg$SIF_DIRS <- character(0)
  if (is.null(.cfg$DEFAULT_SIF)) .cfg$DEFAULT_SIF <- ""
  if (is.null(.cfg$DATA_HOME)) .cfg$DATA_HOME <- path.expand("~")
  if (is.null(.cfg$BASE_VOLUMES)) .cfg$BASE_VOLUMES <- c("Data" = .cfg$DATA_HOME)
  # 测试/演示钩子: 环境变量追加允许根 (冒号分隔), 供 e2e/CI 纳入合成夹具路径
  if (nzchar(Sys.getenv("DIANN_GUI_EXTRA_VOLUMES"))) {
    extra <- strsplit(Sys.getenv("DIANN_GUI_EXTRA_VOLUMES"), ":", fixed = TRUE)[[1]]
    extra <- extra[nzchar(extra)]
    .cfg$BASE_VOLUMES <- c(.cfg$BASE_VOLUMES, setNames(extra, paste0("Extra", seq_along(extra))))
  }
  if (is.null(.cfg$CON_FASTA)) .cfg$CON_FASTA <- ""
  if (is.null(.cfg$SHARED_GROUP)) .cfg$SHARED_GROUP <- ""
  if (is.null(.cfg$SLURM_PARTITIONS)) .cfg$SLURM_PARTITIONS <- c("compute")
  if (is.null(.cfg$APPTAINER_PATHS)) .cfg$APPTAINER_PATHS <- character(0)
  if (is.null(.cfg$APPTAINER_MODULE_FALLBACK)) .cfg$APPTAINER_MODULE_FALLBACK <- ""
  if (is.null(.cfg$BIND_PATHS)) .cfg$BIND_PATHS <- character(0)

  # ---- 邮件 ----
  if (is.null(.cfg$MAIL_PYTHON)) .cfg$MAIL_PYTHON <- Sys.which("python3")
  .cfg$MAIL_PY <- system.file("python", "mail_notify.py", package = "diann.gui")
  .cfg$MAIL_CONF <- local({
    env <- Sys.getenv("DIANN_GUI_MAIL_CONF")
    if (nzchar(env) && file.exists(env)) return(env)
    user_mc <- file.path(path.expand("~"), ".diann_gui", "mail_config.txt")
    if (file.exists(user_mc)) return(user_mc)
    file.path(getwd(), "mail_config.txt")
  })
  .cfg$MAIL_ENABLED <- nzchar(.cfg$MAIL_PYTHON) && file.exists(.cfg$MAIL_CONF)

  # ---- 通知状态文件 (HOME 相对, 每用户独立; 不可写回退 /tmp) ----
  if (is.null(.cfg$NOTIFY_STATE)) {
    cand <- file.path(Sys.getenv("HOME"), "diann_gui_notify_state.rds")
    if (!dir.exists(dirname(cand)) || file.access(dirname(cand), 2) != 0) {
      cand <- file.path("/tmp", "diann_gui_notify_state.rds")
    }
    .cfg$NOTIFY_STATE <- cand
  }
  .cfg$NOTIFY_LOCK_DIR <- paste0(.cfg$NOTIFY_STATE, ".lock")
  .cfg$NOTIFY_PIDFILE <- file.path(dirname(.cfg$NOTIFY_STATE), "diann_gui_notify_watch.pid")
  .cfg$NOTIFY_WATCH_LOG <- file.path(dirname(.cfg$NOTIFY_STATE), "diann_gui_notify_watch.log")

  invisible(.cfg)
}
