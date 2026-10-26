# ============================================================
# config.R — 配置内核: 加载用户/站点配置到包内环境 .cfg
#
# 配置发现顺序 (resolve_user_config):
#   1. 环境变量 DIANN_GUI_CONFIG 指定的文件 —— 程序化注入点, 供一键部署使用
#   2. ~/.diann_gui/config.R —— 每用户设置面 (模板 inst/config/config.example.R)
#   3. <工作目录>/diann_gui_config.R —— 显式命名的项目级配置
# 均不存在时使用内置默认 = "用户家目录模式": 数据/输出归当前用户, 作业以本人提交。
#
# 访问: cfg_get(key) 读; set_core_const(key, value) 写 (测试与站点注入接口)。
# diann-core 等模块的站点常量 (BASE_VOLUMES/CON_FASTA/APPTAINER_*/BIND_PATHS)
# 一律经 cfg_get 读取, 不再依赖散文件的闭包环境。
# ============================================================

.cfg <- new.env(parent = emptyenv())

#' 解析配置文件路径 (env → 每用户 → 显式项目文件), 找不到返回 ""
#'
#' 顺序: `DIANN_GUI_CONFIG` → `~/.diann_gui/config.R` → `<dir>/diann_gui_config.R`。
#' v1.13 起 `<dir>/config.R` 完全不再被读取 (legacy 中央部署已删除): 用户在
#' R / RStudio 里跑 `run_app()` 时, 项目目录里同名的 `config.R` 不应劫持配置;
#' 需要项目级配置请显式命名为 `diann_gui_config.R`。
#' @export
resolve_user_config <- function(dir = getwd()) {
  env <- Sys.getenv("DIANN_GUI_CONFIG")
  if (nzchar(env) && file.exists(env)) return(normalizePath(env, mustWork = FALSE))
  user_cfg <- file.path(path.expand("~"), ".diann_gui", "config.R")
  if (file.exists(user_cfg)) return(user_cfg)
  explicit <- file.path(dir, "diann_gui_config.R")
  if (file.exists(explicit)) return(normalizePath(explicit, mustWork = FALSE))
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
                "SLURM_PARTITIONS", "SLURM_EXTRA_ARGS", "APPTAINER_PATHS",
                "APPTAINER_MODULE_FALLBACK", "BIND_PATHS", "MAIL_PYTHON",
                "DEFAULT_APPTAINER", "APPTAINER_STRICT_CHECK", "RETENTION_DAYS",
                "EXEC_BACKEND", "LOCAL_REQUIRE_EXCLUSIVE_HOST",
                "LOCAL_NICE", "LOCAL_TIMEOUT_GRACE", "LOCAL_MAX_JOBS", "LOCAL_MEM_ADVISORY")) {
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
  if (is.null(.cfg$SLURM_PARTITIONS)) .cfg$SLURM_PARTITIONS <- c("compute")
  if (is.null(.cfg$APPTAINER_PATHS)) .cfg$APPTAINER_PATHS <- character(0)
  if (is.null(.cfg$APPTAINER_MODULE_FALLBACK)) .cfg$APPTAINER_MODULE_FALLBACK <- ""
  if (is.null(.cfg$BIND_PATHS)) .cfg$BIND_PATHS <- character(0)
  if (is.null(.cfg$DEFAULT_APPTAINER)) .cfg$DEFAULT_APPTAINER <- ""
  if (is.null(.cfg$APPTAINER_STRICT_CHECK)) .cfg$APPTAINER_STRICT_CHECK <- FALSE
  if (is.null(.cfg$SLURM_EXTRA_ARGS)) .cfg$SLURM_EXTRA_ARGS <- character(0)
  if (is.null(.cfg$RETENTION_DAYS) || !is.finite(.cfg$RETENTION_DAYS)) .cfg$RETENTION_DAYS <- 90

  # ---- 执行后端 (v1.12: Slurm 可选 / 本地单机) ----
  # 默认 auto: 有 sbatch 用 Slurm (与 v1.11 行为一致), 无 Slurm 自动本地执行。
  # 安全阀见 R/backend.R 的 detect_exec_backend() 与 run_app() 的启动检查。
  if (is.null(.cfg$EXEC_BACKEND)) .cfg$EXEC_BACKEND <- "auto"
  if (is.null(.cfg$LOCAL_REQUIRE_EXCLUSIVE_HOST)) .cfg$LOCAL_REQUIRE_EXCLUSIVE_HOST <- TRUE
  if (is.null(.cfg$LOCAL_NICE) || !is.finite(.cfg$LOCAL_NICE)) .cfg$LOCAL_NICE <- 10L
  if (is.null(.cfg$LOCAL_TIMEOUT_GRACE) || !is.finite(.cfg$LOCAL_TIMEOUT_GRACE)) .cfg$LOCAL_TIMEOUT_GRACE <- 30L
  if (is.null(.cfg$LOCAL_MAX_JOBS) || !is.finite(.cfg$LOCAL_MAX_JOBS)) .cfg$LOCAL_MAX_JOBS <- 0L
  if (is.null(.cfg$LOCAL_MEM_ADVISORY)) .cfg$LOCAL_MEM_ADVISORY <- TRUE

  # ---- 邮件 ----
  if (is.null(.cfg$MAIL_PYTHON)) .cfg$MAIL_PYTHON <- Sys.which("python3")
  .cfg$MAIL_PY <- system.file("python", "mail_notify.py", package = "diann.gui")
  .cfg$MAIL_CONF <- local({
    env <- Sys.getenv("DIANN_GUI_MAIL_CONF")
    if (nzchar(env) && file.exists(env)) return(env)
    user_mc <- file.path(path.expand("~"), ".diann_gui", "mail_config.txt")
    if (file.exists(user_mc)) return(user_mc)
    user_mc  # 默认返回每用户路径 (v1.13 起不再读工作目录 mail_config.txt)
  })
  .cfg$MAIL_ENABLED <- nzchar(.cfg$MAIL_PYTHON) && file.exists(.cfg$MAIL_CONF)

  # ---- 通知状态文件 (HOME 相对, 每用户独立) ----
  # HOME 不可写时回退到 <TMPDIR>/diann_gui-<user> (0700)。不再使用固定的
  # /tmp/diann_gui_notify_state.rds: 多用户会互相覆盖, 且他人可预置符号链接
  # (状态文件中含收件邮箱)。
  if (is.null(.cfg$NOTIFY_STATE)) .cfg$NOTIFY_STATE <- notify_state_default()
  .cfg$NOTIFY_LOCK_DIR <- paste0(.cfg$NOTIFY_STATE, ".lock")
  .cfg$NOTIFY_PIDFILE <- file.path(dirname(.cfg$NOTIFY_STATE), "diann_gui_notify_watch.pid")
  .cfg$NOTIFY_WATCH_LOG <- file.path(dirname(.cfg$NOTIFY_STATE), "diann_gui_notify_watch.log")

  # ---- 执行后端解析缓存 (最佳努力探测, 不做 fail-fast) ----
  # 真正的安全拦截在 run_app() 里的 backend_startup_check(): 普通函数/测试调用
  # diann_load_config() 时不应直接报错 (否则单测与 doctor 无法离线运行)。
  .cfg$EXEC_BACKEND_INFO <- tryCatch(
    detect_exec_backend(require_exclusive = isTRUE(.cfg$LOCAL_REQUIRE_EXCLUSIVE_HOST)),
    error = function(e) list(request = "auto", backend = "local", auto = TRUE,
                             slurm_available = FALSE, traces = FALSE,
                             warn = conditionMessage(e), error = character(0)))
  .cfg$EXEC_BACKEND_RESOLVED <- .cfg$EXEC_BACKEND_INFO$backend

  invisible(.cfg)
}

# 默认状态文件位置: 优先 $HOME; 不可写时用 per-user 临时目录 (稳定路径 + 0700)。
notify_state_default <- function() {
  home <- Sys.getenv("HOME")
  if (nzchar(home) && dir.exists(home) && file.access(home, 2) == 0) {
    return(file.path(home, "diann_gui_notify_state.rds"))
  }
  user <- Sys.info()[["user"]]
  tag <- if (nzchar(user)) gsub("[^A-Za-z0-9_.-]", "_", user) else as.character(Sys.getpid())
  base <- file.path(Sys.getenv("TMPDIR", unset = "/tmp"), paste0("diann_gui-", tag))
  ok <- dir.exists(base) || dir.create(base, showWarnings = FALSE, recursive = TRUE, mode = "0700")
  if (ok) {
    own <- file.info(base)$uname
    if (!is.na(own) && nzchar(user) && !identical(own, user)) ok <- FALSE
  }
  if (ok) {
    Sys.chmod(base, "0700")
    return(file.path(base, "diann_gui_notify_state.rds"))
  }
  # 最后兜底: 本会话 tempdir (至少不会跨用户互相覆盖)
  file.path(tempdir(), "diann_gui_notify_state.rds")
}
