
# ============================================================
# App directory: inferred from --file= when run via Rscript. Under shiny-server
# the worker's working directory is the (possibly staged/symlinked) app directory,
# so resolve app.R itself through symlinks to find the REAL project directory —
# config.R, notify scripts and docs live next to the physical app.R, which a
# symlinked deployment would otherwise miss.
# ============================================================
app_dir <- local({
  a <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", a[grepl("^--file=", a)])
  if (length(f)) {
    dirname(normalizePath(f[1], mustWork = FALSE))
  } else {
    entry <- file.path(getwd(), "app.R")
    if (file.exists(entry)) dirname(normalizePath(entry, mustWork = FALSE)) else getwd()
  }
})

# Optional site configuration: copy config.example.R to config.R next to
# app.R and set your cluster's paths there. Anything defined in config.R
# overrides the built-in defaults below.
CONFIG_FILE <- file.path(app_dir, "config.R")
if (file.exists(CONFIG_FILE)) source(CONFIG_FILE)

# Optional extra R library tree holding the GUI's dependency packages
if (!exists("EXTRA_LIB")) EXTRA_LIB <- NULL
if (length(EXTRA_LIB) == 1 && nzchar(EXTRA_LIB) && dir.exists(EXTRA_LIB)) {
  .libPaths(c(EXTRA_LIB, .libPaths()))
}

# 纯函数核心 (参数校验/命令构建与解析/sbatch 模板/路径守卫), 与 testthat 测试套件共用;
# 其运行期引用的站点常量 (BASE_VOLUMES/CON_FASTA/APPTAINER_*/BIND_PATHS) 已在上方就绪。
# local = TRUE 必不可少: 默认 FALSE 会把函数装进 globalenv, 而 BASE_VOLUMES 定义在
# shiny 的 app 环境里——path_in_scope 等从自身闭包链上找不到它, 导入含真实路径的
# 命令时会话直接断开 (与 tests/testthat/helper.R 的 local=TRUE 同源教训)
source(file.path(app_dir, "diann_core.R"), local = TRUE)
stopifnot(exists("build_diann_chunks"), exists("parse_diann_command"), exists("path_in_scope"))

library(shiny)
library(shinydashboard)
library(shinyFiles)
# UI 与数据模块: 一律 local=TRUE source 进本环境 (2026-10-09 事故防线);
# 顺序须在 diann_core 之后 (ui_params 依赖其 vm_default) 且在 shiny 载入之后
# (ui_params 构造 CSS 常量)。changelog_data 为纯数据, 须在 ui 构造之前。
source(file.path(app_dir, "changelog_data.R"), local = TRUE)
source(file.path(app_dir, "ui_params.R"), local = TRUE)

# ============================================================
# 配置区 Configuration — every constant below can be overridden from
# config.R (loaded above if present). The built-in defaults suit a simple
# deployment where the app's run user owns the data tree; shared/multi-user
# setups configure DATA_HOME / SHARED_GROUP instead.
# ============================================================

# SIF 镜像扫描目录（递归查找 diann*.sif，下拉框按版本去重，保留扫描到的第一个）
if (!exists("SIF_DIRS")) SIF_DIRS <- c(path.expand("~"))
if (!exists("DEFAULT_SIF")) DEFAULT_SIF <- ""  # empty = use the first scanned image

# 文件/目录浏览根（自动过滤不存在的路径）
if (!exists("DATA_HOME")) DATA_HOME <- path.expand("~")
BASE_VOLUMES <- if (exists("BASE_VOLUMES")) BASE_VOLUMES else c("Data" = DATA_HOME)
# 测试/演示钩子: 环境变量追加允许根 (冒号分隔), 供 e2e/CI 把合成夹具路径纳入范围。
# 生产不设置该变量, 行为不变; 路径守卫 path_in_scope 只做前缀检查, 不要求目录存在
if (nzchar(Sys.getenv("DIANN_GUI_EXTRA_VOLUMES"))) {
  extra <- strsplit(Sys.getenv("DIANN_GUI_EXTRA_VOLUMES"), ":", fixed = TRUE)[[1]]
  extra <- extra[nzchar(extra)]
  BASE_VOLUMES <- c(BASE_VOLUMES, setNames(extra, paste0("Extra", seq_along(extra))))
}

# Optional shared-directory repair. When output directories must also be
# writable by other users (e.g. lab members whose data lands under another
# account's home), set SHARED_GROUP in config.R to a Unix group containing
# both the app's run user and those users. Every directory the GUI creates
# is repaired up the tree to DATA_HOME: chmod 2770 (setgid + group-writable)
# and chgrp SHARED_GROUP. This is needed because R's dir.create(recursive=TRUE)
# loses setgid on intermediate parents and assigns them the run user's primary
# group — repairs at the leaf alone would still lock users out mid-path.
# Leave SHARED_GROUP empty ("") to disable the repair entirely.
if (!exists("SHARED_GROUP")) SHARED_GROUP <- ""
fix_shared_dirs <- function(leafs) {
  if (!nzchar(SHARED_GROUP)) return(invisible(NULL))
  for (leaf in leafs) {
    d <- normalizePath(leaf, mustWork = FALSE)
    while (nzchar(d) && d != "/" && d != DATA_HOME) {
      try(Sys.chmod(d, "2770"), silent = TRUE)
      try(suppressWarnings(system2("chgrp", c(SHARED_GROUP, d), stderr = FALSE)), silent = TRUE)
      p <- dirname(d)
      if (identical(p, d)) break
      d <- p
    }
  }
}


# Slurm partitions offered in the submit form (the first one is the default)
if (!exists("SLURM_PARTITIONS")) SLURM_PARTITIONS <- c("compute")

# Apptainer invocation: the generated sbatch script tries each directory in
# APPTAINER_PATHS for an apptainer binary; if none works it falls back to
# `module load APPTAINER_MODULE_FALLBACK` (empty string = no module fallback).
if (!exists("APPTAINER_PATHS")) APPTAINER_PATHS <- character(0)
if (!exists("APPTAINER_MODULE_FALLBACK")) APPTAINER_MODULE_FALLBACK <- ""

# Extra host paths bind-mounted into the container at runtime. Apptainer only
# binds $HOME/cwd by default — add e.g. a shared /share if data lives elsewhere.
if (!exists("BIND_PATHS")) BIND_PATHS <- character(0)

# 邮件通知: 独立守护进程 notify_watch.R 在作业离队后调用 mail_notify.py 发送。
# Email notification (optional): SMTP credentials live in mail_config.txt next
# to app.R (template: mail_config.example.txt). MAIL_PYTHON may be set in
# config.R; without it python3 is looked up on PATH. Without mail_config.txt
# the whole feature stays dormant (no enqueue, no watcher, no mail UI hints).
MAIL_PY <- file.path(app_dir, "mail_notify.py")
MAIL_CONF <- file.path(app_dir, "mail_config.txt")

# ============================================================
# Job completion email notifications (optional)
# Mechanism: on submit, jobs carrying a notify address are written to a state
# file; a standalone daemon (notify_watch.R, spawned detached by the worker so
# it survives worker recycling — workers only live while a page is open) polls
# squeue, and once a job leaves the queue it parses slurm-<id>.out for the exit
# code and sends mail via mail_notify.py. This design exists because Slurm's
# built-in --mail-user is often unusable on compute nodes without outbound
# network — mail is sent from wherever this app runs (a node with SMTP access).
# State file / locking / sending logic lives in notify_common.R, sourced by
# both app.R and notify_watch.R.
# ============================================================
NOTIFY_COMMON <- file.path(app_dir, "notify_common.R")
NOTIFY_WATCH_SCRIPT <- file.path(app_dir, "notify_watch.R")
if (file.exists(NOTIFY_COMMON)) source(NOTIFY_COMMON)
# notify_common.R 被 source 到 globalenv, 看不见本文件环境里的 MAIL_PYTHON/MAIL_CONF
# (shiny 将 app.R 顶层代码运行在 globalenv 的子环境中, 子环境能向上查找、父环境不能向下),
# 因此它算出的 MAIL_ENABLED 只对 watcher 进程正确; 此处用 <<- 覆写 globalenv 中的
# MAIL_ENABLED, 让 app 进程内的入队/拉起闸门用到真实配置
MAIL_ENABLED <<- is.character(MAIL_PYTHON) && nzchar(MAIL_PYTHON) && file.exists(MAIL_CONF)


# ---- GUI 持久提交注册表 (跨会话按 JobID 定位日志; worker 被回收后本会话列表即丢失) ----
# 与通知状态文件同目录 (worker 身份可写), 复用其 mkdir 互斥锁 + 临时文件 rename 原子写
JOBS_REGISTRY <- if (exists("NOTIFY_STATE")) file.path(dirname(NOTIFY_STATE), "diann_gui_jobs_registry.rds") else "/tmp/diann_gui_jobs_registry.rds"
jobs_registry_load <- function() {
  empty <- data.frame(jobid = character(0), 任务名 = character(0), 输出目录 = character(0),
                      日志 = character(0), 提交时间 = character(0), stringsAsFactors = FALSE)
  if (!file.exists(JOBS_REGISTRY)) return(empty)
  tryCatch(readRDS(JOBS_REGISTRY), error = function(e) empty)
}
jobs_registry_add <- function(jobid, task, out_dir) {
  have_lock <- exists("notify_lock_acquire")
  if (have_lock && !notify_lock_acquire()) return(invisible(FALSE))
  on.exit(if (have_lock) notify_lock_release(), add = TRUE)
  df <- jobs_registry_load()
  df <- df[df$jobid != as.character(jobid), , drop = FALSE]  # 同 ID 重新提交则覆盖
  df <- rbind(df, data.frame(
    jobid = as.character(jobid), 任务名 = as.character(task), 输出目录 = as.character(out_dir),
    日志 = file.path(out_dir, sprintf("slurm-%s.out", jobid)),
    提交时间 = format(Sys.time(), "%Y-%m-%d %H:%M:%S"), stringsAsFactors = FALSE))
  df <- utils::head(df, 300)  # 只保留最近 300 条
  tmp <- sprintf("%s.tmp.%d", JOBS_REGISTRY, Sys.getpid())
  ok <- tryCatch({ saveRDS(df, tmp); file.rename(tmp, JOBS_REGISTRY) },
                 error = function(e) FALSE, warning = function(w) FALSE)
  if (!identical(ok, TRUE)) try(unlink(tmp), silent = TRUE)
  invisible(ok)
}

# 拉起 watcher (已有存活实例则跳过); worker 启动与每次提交成功后调用, 兼作失联对账
ensure_diann_watcher <- function() {
  if (!exists("MAIL_ENABLED", inherits = TRUE) || !isTRUE(MAIL_ENABLED)) return(invisible(FALSE))
  if (!file.exists(NOTIFY_WATCH_SCRIPT)) return(invisible(FALSE))
  pid <- if (file.exists(NOTIFY_PIDFILE)) {
    suppressWarnings(as.integer(readLines(NOTIFY_PIDFILE, warn = FALSE)[1]))
  } else NA_integer_
  if (!is.na(pid) && pid > 0 && system(sprintf("kill -0 %d 2>/dev/null", pid)) == 0L) {
    return(invisible(TRUE))
  }
  # 派生方式实测 (2026-10-03): worker 内 setsid 会失败 (rc=1), 而
  # `nohup ... &` + wait=TRUE 可用 —— sh 立即退出, watcher 被过继给 init (PPID=1),
  # 脱离 worker 进程生命周期
  cmd <- sprintf("nohup %s %s --state %s --pidfile %s --interval 60 >> %s 2>&1 < /dev/null &",
                 shQuote(file.path(R.home("bin"), "Rscript")), shQuote(NOTIFY_WATCH_SCRIPT),
                 shQuote(NOTIFY_STATE), shQuote(NOTIFY_PIDFILE), shQuote(NOTIFY_WATCH_LOG))
  system(cmd, wait = TRUE)
  invisible(TRUE)
}
try(ensure_diann_watcher(), silent = TRUE)

# 内置污染物 FASTA (cRAP, 序列 ID 带 cRAP- 前缀), 配合 --cont-quant-exclude 使用
# Built-in contaminant FASTA (cRAP, sequence IDs carry a cRAP- prefix), added
# to the command when contaminant quantification is enabled; empty = none.
if (!exists("CON_FASTA")) CON_FASTA <- ""

# 参数速查文档（GUI 内"参数速查"页解析显示）
PARAM_DOC_CANDIDATES <- c(
  file.path(app_dir, "DIANN参数说明.md"),
  file.path(app_dir, "docs", "DIANN参数说明.md")
)
PARAM_DOC <- {
  ok <- PARAM_DOC_CANDIDATES[file.exists(PARAM_DOC_CANDIDATES)]
  if (length(ok)) ok[1] else ""
}

# ============================================================
# SIF 镜像扫描（模块级执行一次）
# ============================================================
scan_sif_images <- function(dirs) {
  paths <- unlist(lapply(dirs, function(d) {
    if (dir.exists(d)) {
      list.files(d, pattern = "(?i)^diann.*\\.sif$", full.names = TRUE, recursive = TRUE)
    } else character(0)
  }), use.names = FALSE)
  paths <- unique(normalizePath(paths, mustWork = FALSE))
  if (!length(paths)) return(data.frame(ver = character(), path = character()))
  ver <- sub("(?i).*diann[-._ ]?([0-9]+(?:\\.[0-9]+)*).*", "\\1", basename(paths), perl = TRUE)
  df <- data.frame(path = paths, ver = ver, stringsAsFactors = FALSE)
  df <- df[df$ver != "", ]
  df <- df[order(df$ver, decreasing = TRUE), ]
  df[!duplicated(df$ver), ]
}
sif_df <- scan_sif_images(SIF_DIRS)

sif_choices <- if (nrow(sif_df)) {
  labels <- sprintf("v%s · %s", sif_df$ver, sif_df$path)
  setNames(sif_df$path, labels)
} else character(0)
sif_selected <- if (DEFAULT_SIF %in% sif_df$path) DEFAULT_SIF else if (nrow(sif_df)) sif_df$path[1] else NULL

# ============================================================
# 参数解析：解析 DIANN参数说明.md 中的官方命令行参考
# ============================================================
html_unescape <- function(x) {
  x <- gsub("&lt;", "<", x, fixed = TRUE)
  x <- gsub("&gt;", ">", x, fixed = TRUE)
  x <- gsub("&quot;", "\"", x, fixed = TRUE)
  x <- gsub("&#39;", "'", x, fixed = TRUE)
  gsub("&amp;", "&", x, fixed = TRUE)
}
parse_param_doc <- function(path) {
  txt <- readLines(path, n = 6, warn = FALSE)
  idx <- which(grepl("<li", txt))[1]
  if (is.na(idx)) return(NULL)
  line <- txt[idx]
  entries <- regmatches(line, gregexpr("<li[^>]*><strong[^>]*>(--[^<]+)</strong>(.*?)</li>", line, perl = TRUE))[[1]]
  if (!length(entries)) return(NULL)
  flag <- sub(".*<strong[^>]*>(--[^<]+)</strong>.*", "\\1", entries, perl = TRUE)
  desc <- gsub("<[^>]+>", "", sub(".*</strong>", "", entries, perl = TRUE))
  data.frame(flag = flag, desc = html_unescape(desc), stringsAsFactors = FALSE)
}
param_ref <- if (file.exists(PARAM_DOC)) parse_param_doc(PARAM_DOC) else NULL

# ============================================================
# GUI 版本与更新说明
# ============================================================
GUI_VERSION <- "v1.9"


# ============================================================
# UI
# ============================================================


ui <- dashboardPage(
  dashboardHeader(title = span("DIA-NN 控制台", tags$small(GUI_VERSION))),
  dashboardSidebar(
    sidebarMenu(
      menuItem("提交分析", tabName = "analysis", icon = icon("play-circle")),
      menuItem("任务队列", tabName = "monitor", icon = icon("list-ul")),
      menuItem("参数速查", tabName = "help", icon = icon("book")),
      menuItem("更新说明", tabName = "changelog", icon = icon("history"))
    )
  ),
  dashboardBody(
    tags$head(PARAM_CSS_TAG),
    tabItems(
      # ==================== 提交分析 ====================
      tabItem(tabName = "analysis",
        fluidRow(
          box(title = "1. DIA-NN 版本 (sif 镜像)", status = "primary", solidHeader = TRUE, width = 12, collapsible = TRUE,
              column(4,
                selectInput("sif_version", "版本 (自动扫描 diann*.sif):", choices = sif_choices, selected = sif_selected)
              ),
              column(4,
                checkboxInput("use_custom_sif", "使用自定义镜像路径", FALSE),
                conditionalPanel("input.use_custom_sif == 1",
                  textInput("custom_sif", "sif 文件完整路径:", placeholder = "/path/to/diann-x.y.z.sif")
                )
              ),
              column(4,
                tags$label("当前生效镜像:"), br(),
                verbatimTextOutput("sif_display"),
                helpText("不同版本通过不同 sif 镜像实现；若版本下拉为空请检查 config.R 中的 SIF_DIRS。")
              )
          )
        ),
        fluidRow(
          box(title = "2. 文件与数据库", status = "primary", solidHeader = TRUE, width = 12,
              column(3,
                radioButtons("raw_mode", "RAW 输入方式:", inline = TRUE,
                             choices = c("选择文件" = "files", "扫描目录" = "dir")),
                conditionalPanel("input.raw_mode == 'files'",
                  shinyFilesButton("raw_files", "选择 RAW 文件", "选择待分析的原始文件 (可多选)", multiple = TRUE)
                ),
                conditionalPanel("input.raw_mode == 'dir'",
                  shinyDirButton("raw_dir_btn", "选择 RAW 目录", "选择包含原始文件的目录 (递归扫描)"),
                  verbatimTextOutput("raw_dir_display")
                ),
                verbatimTextOutput("raw_path_display"),
                helpText("注意: DIA-NN 会在 RAW 目录生成 *.raw.quant 缓存并自动复用, 同一目录混用不同谱库/版本的分析可能报 library size mismatch, 必要时删除 *.raw.quant")
              ),
              column(3,
                shinyFilesButton("lib_file", "选择光谱库", "选择光谱库 (可选, .speclib/.parquet/.tsv/.msp/.sptxt)", multiple = FALSE),
                verbatimTextOutput("lib_path_display"),
                helpText("与 FASTA 至少提供一个")
              ),
              column(3,
                shinyFilesButton("fasta_file", "选择 FASTA", "选择蛋白序列库 (可多选, 无库分析时必选)", multiple = TRUE),
                verbatimTextOutput("fasta_path_display"),
                checkboxInput("cont_exclude", "启用污染物扣除 (cRAP)", FALSE),
                conditionalPanel("input.cont_exclude == 1",
                  textInput("cont_tag", "排除标签 (--cont-quant-exclude):", "cRAP-"),
                  helpText("自动附加内置 cRAP 污染物库 (125 条) 并从定量中排除该类蛋白")
                )
              ),
              column(3,
                shinyFilesButton("ref_file", "选择校准库", "选择专用校准谱库 --ref (可选)", multiple = FALSE),
                verbatimTextOutput("ref_path_display"),
                helpText("可选: 仅用于校准的小型谱库")
              )
          )
        ),
        fluidRow(
          box(title = "3. 输出设置", status = "success", solidHeader = TRUE, width = 4,
              shinyDirButton("out_dir", "选择输出目录", "选择结果存放目录"),
              verbatimTextOutput("out_path_display"),
              textInput("report_name", "主报告文件名 (自动加 .tsv):", "report"),
              shinyDirButton("temp_dir", "选择临时目录 --temp (可选)", "选择临时目录"),
              verbatimTextOutput("temp_path_display"),
              checkboxInput("convert_only", "仅执行 RAW→DIA 转换 (--convert)", FALSE),
              helpText("勾选后忽略分析参数; 转换后的 .dia 文件保存在 RAW 文件所在目录")
          ),
          box(title = "4. 分析参数", status = "warning", solidHeader = TRUE, width = 8,
              fluidRow(
                column(4, actionButton("preset_lib", "预设: FASTA 生成预测库", icon = icon("magic"), width = "100%")),
                column(4, actionButton("preset_convert", "预设: RAW 转 DIA (仅转换)", icon = icon("file-export"), width = "100%")),
                column(4, helpText("预设仅切换常用开关组合, 其余参数仍可手动调整。"))
              ),
              br(),
              param_tabs_ui()
          )
        ),
        fluidRow(
          box(title = "命令导入 (自动识别并填充参数)", status = "info", solidHeader = TRUE, width = 12,
              collapsible = TRUE, collapsed = TRUE,
              column(8,
                textAreaInput("import_cmd", "粘贴 DIA-NN 命令 (支持 Windows GUI 生成的命令、本页预览的 Slurm 脚本):",
                              height = "90px",
                              placeholder = "diann.exe --f C:\\data\\run.raw --lib C:\\lib.parquet --qvalue 0.01 --matrices ...")
              ),
              column(4,
                actionButton("import_btn", "解析并填充参数", icon = icon("download"), class = "btn-primary", width = "100%"),
                checkboxInput("use_imported_raws", "覆盖 RAW 文件 (用导入路径)", FALSE),
                checkboxInput("use_imported_lib", "覆盖光谱库 library (用导入路径)", FALSE),
                checkboxInput("use_imported_fasta", "覆盖 FASTA (用导入路径)", FALSE),
                checkboxInput("use_imported_ref", "覆盖校准库 ref (用导入路径)", FALSE),
                checkboxInput("use_imported_out", "覆盖输出目录 (用导入路径)", FALSE),
                checkboxInput("use_imported_temp", "覆盖临时目录 (用导入路径)", FALSE)
              ),
              verbatimTextOutput("import_result")
          )
        ),
        fluidRow(
          box(title = "5. Slurm 资源", status = "info", solidHeader = TRUE, width = 12,
              column(3, textInput("job_name", "任务名称:", "DIANN_Task")),
              column(3, selectInput("partition", "计算分区:", choices = SLURM_PARTITIONS, selected = SLURM_PARTITIONS[1])),
              column(3, numericInput("mem_gb", "内存 (GB):", 64, min = 1, max = 4096)),
              column(3, numericInput("time_h", "时限 (小时, 留空=不限):", NA, min = 1)),
              helpText("CPU 核数不在此设置: Slurm 的 --cpus-per-task 与 DIA-NN 的 --threads 同源, 由「4. 分析参数 → 常规 → 线程数」决定。")
          )
        ),
        fluidRow(
          box(title = "6. 命令预览与提交", status = "danger", solidHeader = TRUE, width = 12,
              fluidRow(
                column(4,
                  textInput("notify_email", "邮箱通知 (可选):", placeholder = "someone@126.com, someone2@126.com"),
                  helpText("作业结束时自动发送邮件, 含项目简介与结果简介; 多个邮箱用英文逗号分隔。")
                ),
                column(8,
                  textAreaInput("project_desc", "项目简介 (可选, 随完成邮件发送):",
                                height = "70px",
                                placeholder = "例如: 小鼠单细胞 DIA 数据, 考察 XX 处理组的蛋白组差异…")
                )
              ),
              fluidRow(
                column(8,
                  uiOutput("validation_msgs"),
                  tags$div(class = "scrollbox", verbatimTextOutput("preview"))
                ),
                column(4,
                  actionButton("submit_job", "提交 Slurm 任务", icon = icon("paper-plane"),
                               class = "btn-lg btn-success", width = "100%"),
                  br(), br(),
                  helpText("提交前请确认上方校验提示为空、命令预览符合预期。",
                           "Slurm 脚本将保存到 输出目录/diann_gui_scripts/ 下, stdout/stderr 日志为输出目录下 slurm-<任务ID>.out/.err。")
                )
              )
          )
        )
      ),

      # ==================== 任务队列 ====================
      tabItem(tabName = "monitor",
        fluidRow(
          box(title = "集群节点资源 (sinfo)", status = "info", solidHeader = TRUE, width = 12,
              tableOutput("sinfo_table")
          )
        ),
        fluidRow(
          box(title = "运行队列 (squeue)", status = "primary", solidHeader = TRUE, width = 12,
              checkboxInput("auto_refresh", "自动刷新 (10 秒)", TRUE),
              actionButton("refresh_q", "立即刷新", icon = icon("sync")),
              tags$div(class = "scrollbox", verbatimTextOutput("squeue_output"))
          )
        ),
        fluidRow(
          box(title = "近期历史 (sacct, 最近一天)", status = "primary", solidHeader = TRUE, width = 12, collapsible = TRUE,
              tableOutput("sacct_table"),
              helpText("作业ID: Slurm 作业号 | 作业名: 提交时的任务名称 | 状态: 作业结果 (已完成/运行中/排队中/失败/超时/已取消等) | 运行时长: 作业实际运行时间 | 结束时间: 作业退出时刻")
          )
        ),
        fluidRow(
          box(title = "取消作业", status = "danger", solidHeader = TRUE, width = 4,
              numericInput("cancel_id", "作业 ID:", NA),
              actionButton("cancel_btn", "scancel 取消该作业", icon = icon("ban"), class = "btn-danger", width = "100%")
          ),
          box(title = "运行日志查看 (slurm-<ID>.out 尾部)", status = "warning", solidHeader = TRUE, width = 8,
              fluidRow(
                column(4, numericInput("log_id", "作业 ID:", NA)),
                column(8,
                  shinyDirButton("log_dir_btn", "指定日志目录 (可选, 留空自动定位)", "选择包含日志的目录"),
                  verbatimTextOutput("log_dir_display")
                )
              ),
              actionButton("view_log", "查看日志 (尾部 120 行)", icon = icon("file-alt")),
              tags$div(class = "scrollbox", verbatimTextOutput("log_output"))
          )
        ),
        fluidRow(
          box(title = "本会话提交记录", status = "info", solidHeader = TRUE, width = 12,
              tableOutput("jobs_table"),
              verbatimTextOutput("notify_status")
          )
        )
      ),

      # ==================== 参数速查 ====================
      tabItem(tabName = "help",
        box(title = "DIA-NN 命令行参数速查", status = "primary", solidHeader = TRUE, width = 12,
            verbatimTextOutput("doc_path_display"),
            tags$div(class = "scrollbox", uiOutput("param_ref"))
        )
      ),

      # ==================== 更新说明 ====================
      tabItem(tabName = "changelog",
        fluidRow(
          box(title = "DIA-NN 版本说明 (含实测结论)", status = "info", solidHeader = TRUE, width = 12,
              uiOutput("version_notes"),
              tags$strong("本机已扫描到的 sif 镜像:"),
              tableOutput("sif_table")
          )
        ),
        fluidRow(
          box(title = "DIA-NN 2.0 系列官方更新日志 (Release Notes 原文, 新的在前)", status = "info",
              solidHeader = TRUE, width = 12, collapsible = TRUE, collapsed = TRUE,
              uiOutput("diann_release_notes")
          )
        ),
        fluidRow(
          box(title = sprintf("GUI 更新日志 (当前 %s)", GUI_VERSION), status = "primary",
              solidHeader = TRUE, width = 12,
              uiOutput("gui_changelog")
          )
        )
      )
    )
  )
)

# ============================================================
# Server
# ============================================================
server <- function(input, output, session) {
  volumes <- BASE_VOLUMES[file.exists(unname(BASE_VOLUMES))]
  user <- Sys.getenv("USER"); if (!nzchar(user)) user <- Sys.info()[["user"]]

  # 运行用户无权访问数据根目录时, 文件浏览器会静默显示为空 — 在此明确提示。
  # 不存在的卷 (如 e2e/演示用的合成根 /share/home/demo) 静默跳过:
  # 选择器本就按 file.exists 过滤, 这类卷是配置里的既定测试设施而非故障
  acc <- file.access(unname(BASE_VOLUMES), 4)
  denied <- (is.na(acc) | acc != 0) & file.exists(unname(BASE_VOLUMES))
  if (any(denied)) {
    showNotification(
      HTML(paste0(
        "<b>数据目录不可访问</b><br>当前 GUI 以用户 <b>", user, "</b> 运行, 无权读取 ",
        paste(sprintf("%s (%s)", names(BASE_VOLUMES)[denied], unname(BASE_VOLUMES)[denied]), collapse = ", "),
        "。<br>请让管理员将 shiny-server 的 run_as 改为该目录的属主用户并重启服务。"
      )),
      type = "error", duration = NULL
    )
  }

  # 本会话提交记录
  jobs <- reactiveValues(jobs = data.frame(
    jobid = character(), 任务名 = character(), 版本 = character(),
    输出目录 = character(), 提交时间 = character(), 邮箱 = character(), stringsAsFactors = FALSE
  ))

  # 命令导入的文件路径覆盖层 (shinyFiles 选择器无法编程填充, 导入后按类勾选覆盖)
  ov <- reactiveValues(raws = character(0), fastas = character(0),
                       lib = "", ref = "", temp = "", out_dir = "")
  import_txt <- reactiveValues(txt = "尚未导入命令")

  # ---------- 文件选择器 ----------
  shinyFileChoose(input, "raw_files", roots = volumes, filetypes = c("raw", "mzML", "dia", "wiff"))
  shinyFileChoose(input, "lib_file", roots = volumes, filetypes = c("speclib", "parquet", "tsv", "msp", "sptxt"))
  shinyFileChoose(input, "ref_file", roots = volumes, filetypes = c("speclib", "parquet", "tsv", "msp", "sptxt"))
  shinyFileChoose(input, "fasta_file", roots = volumes, filetypes = c("fasta", "fa"))
  shinyDirChoose(input, "out_dir", roots = volumes)
  shinyDirChoose(input, "temp_dir", roots = volumes)
  shinyDirChoose(input, "raw_dir_btn", roots = volumes)
  shinyDirChoose(input, "log_dir_btn", roots = volumes)

  selected_raws <- reactive({
    if (isTRUE(input$use_imported_raws) && length(ov$raws)) ov$raws
    else as.character(parseFilePaths(volumes, input$raw_files)$datapath)
  })
  selected_lib <- reactive({
    if (isTRUE(input$use_imported_lib) && nz_str(ov$lib)) ov$lib
    else as.character(parseFilePaths(volumes, input$lib_file)$datapath)
  })
  selected_ref <- reactive({
    if (isTRUE(input$use_imported_ref) && nz_str(ov$ref)) ov$ref
    else as.character(parseFilePaths(volumes, input$ref_file)$datapath)
  })
  selected_fasta <- reactive({
    if (isTRUE(input$use_imported_fasta) && length(ov$fastas)) ov$fastas
    else as.character(parseFilePaths(volumes, input$fasta_file)$datapath)
  })
  selected_out_dir <- reactive({
    if (isTRUE(input$use_imported_out) && nz_str(ov$out_dir)) ov$out_dir
    else as.character(parseDirPath(volumes, input$out_dir))
  })
  selected_temp_dir <- reactive({
    if (isTRUE(input$use_imported_temp) && nz_str(ov$temp)) ov$temp
    else as.character(parseDirPath(volumes, input$temp_dir))
  })
  selected_raw_dir <- reactive(as.character(parseDirPath(volumes, input$raw_dir_btn)))
  selected_log_dir <- reactive(as.character(parseDirPath(volumes, input$log_dir_btn)))

  # ---------- 路径回显 ----------
  output$sif_display <- renderText({
    if (isTRUE(input$use_custom_sif)) {
      p <- trimws(input$custom_sif)
      if (nzchar(p)) paste0("(自定义) ", p) else "(未填写自定义路径)"
    } else if (!is.null(sif_selected) && !is.null(input$sif_version)) {
      sprintf("(v%s) %s",
              sif_df$ver[match(input$sif_version, sif_df$path)], input$sif_version)
    } else "未找到可用镜像"
  })
  output$raw_path_display <- renderText({
    mk <- if (isTRUE(input$use_imported_raws) && length(ov$raws)) "(导入) " else ""
    if (length(selected_raws())) paste0(mk, paste(selected_raws(), collapse = "\n")) else "未选 RAW 文件"
  })
  output$raw_dir_display <- renderText({
    if (length(selected_raw_dir())) selected_raw_dir() else "未选目录"
  })
  output$lib_path_display <- renderText({
    mk <- if (isTRUE(input$use_imported_lib) && nz_str(ov$lib)) "(导入) " else ""
    if (length(selected_lib())) paste0(mk, selected_lib()) else "未选光谱库"
  })
  output$ref_path_display <- renderText({
    mk <- if (isTRUE(input$use_imported_ref) && nz_str(ov$ref)) "(导入) " else ""
    if (length(selected_ref())) paste0(mk, selected_ref()) else "未选校准库"
  })
  output$fasta_path_display <- renderText({
    mk <- if (isTRUE(input$use_imported_fasta) && length(ov$fastas)) "(导入) " else ""
    if (length(selected_fasta())) paste0(mk, paste(selected_fasta(), collapse = "\n")) else "未选 FASTA"
  })
  output$out_path_display <- renderText({
    mk <- if (isTRUE(input$use_imported_out) && nz_str(ov$out_dir)) "(导入) " else ""
    if (length(selected_out_dir())) paste0(mk, selected_out_dir()) else "未选输出目录"
  })
  output$temp_path_display <- renderText({
    mk <- if (isTRUE(input$use_imported_temp) && nz_str(ov$temp)) "(导入) " else ""
    if (length(selected_temp_dir())) paste0(mk, selected_temp_dir()) else "未选临时目录 (使用默认)"
  })
  output$log_dir_display <- renderText({
    if (length(selected_log_dir())) selected_log_dir() else "未指定 (自动定位: 手动目录 → 本会话提交记录 → GUI 注册表 → scontrol → sacct 工作目录)"
  })

  # ---------- 参数收集 ----------
  params_ready <- reactive({
    out_dir <- if (length(selected_out_dir())) selected_out_dir() else ""
    rep_name <- trimws(input$report_name)
    sif <- if (isTRUE(input$use_custom_sif)) trimws(input$custom_sif) else input$sif_version
    time_h <- input$time_h
    if (!is.null(time_h) && length(time_h) == 1 && !is.na(time_h) && time_h < 1) time_h <- NA_real_
    list(
      job_name = trimws(input$job_name %||% ""), partition = input$partition %||% "compute",
      threads = input$threads %||% 16, mem_gb = input$mem_gb %||% 64, time_h = time_h,
      sif = sif,
      ver = if (nz_str(sif)) {
        v <- sub("(?i).*diann[-._ ]?([0-9]+(?:\\.[0-9]+)*).*", "\\1", basename(sif), perl = TRUE)
        if (nzchar(v)) v else "自定义"
      } else "",
      raw_mode = input$raw_mode,
      raws = selected_raws(), raw_dir = if (length(selected_raw_dir())) selected_raw_dir() else "",
      lib = if (length(selected_lib())) selected_lib() else "",
      ref = if (length(selected_ref())) selected_ref() else "",
      fastas = selected_fasta(),
      temp = if (length(selected_temp_dir())) selected_temp_dir() else "",
      out_dir = out_dir,
      out_file = if (nz_str(out_dir) && nz_str(rep_name)) file.path(out_dir, paste0(rep_name, ".tsv")) else "",
      slurm_out = if (nz_str(out_dir)) file.path(out_dir, "slurm-%j.out") else "",
      slurm_err = if (nz_str(out_dir)) file.path(out_dir, "slurm-%j.err") else "",
      verbose = as.integer(input$verbose %||% 1), qvalue = input$qvalue %||% 0.01,
      reanalyse = input$mbr, rt_prof = input$rt_prof, peptidoforms = input$peptidoforms,
      proteoforms = input$proteoforms, matrices = input$matrices,
      indiv_reports = input$indiv_reports, unimod4 = input$unimod4,
      mass_acc = input$mass_acc, mass_acc_ms1 = input$mass_acc_ms1, window = input$window,
      min_peak = input$min_peak, rt_window = input$rt_window, im_window = input$im_window,
      quant_qvalue = input$quant_qvalue, protein_quant_qvalue = input$protein_quant_qvalue,
      matrix_qvalue = input$matrix_qvalue,
      var_mods_max = input$var_mods_max,
      var_mod_rows = lapply(1:6, function(i) c(
        trimws(input[[paste0("vm_name_", i)]]),
        trimws(input[[paste0("vm_mass_", i)]]),
        trimws(input[[paste0("vm_sites_", i)]])
      )),
      fixed_mod_rows = lapply(1:3, function(i) c(
        trimws(input[[paste0("fm_name_", i)]]),
        trimws(input[[paste0("fm_mass_", i)]]),
        trimws(input[[paste0("fm_sites_", i)]])
      )),
      met_excision = input$met_excision, reannotate = input$reannotate,
      use_cut = input$use_cut %||% FALSE, cut = trimws(input$cut %||% ""),
      missed_cleavages = input$missed_cleavages,
      min_pep_len = input$min_pep_len, max_pep_len = input$max_pep_len,
      min_pr_mz = input$min_pr_mz, max_pr_mz = input$max_pr_mz,
      min_pr_charge = input$min_pr_charge, max_pr_charge = input$max_pr_charge,
      min_fr_mz = input$min_fr_mz, max_fr_mz = input$max_fr_mz,
      predictor = input$predictor, light_models = input$light_models,
      gen_spec_lib = input$gen_spec_lib,
      out_lib = trimws(input$out_lib %||% ""), out_lib_qvalue = input$out_lib_qvalue,
      export_quant = input$export_quant, report_decoys = input$report_decoys,
      individual_windows = input$individual_windows, individual_mass_acc = input$individual_mass_acc,
      global_norm = input$global_norm, no_rt_norm = input$no_rt_norm, no_prot_norm = input$no_prot_norm,
      high_acc = input$high_acc, no_skyline = input$no_skyline, no_stats = input$no_stats,
      xic = input$xic, min_corr = input$min_corr,
      fasta_search = input$fasta_search %||% FALSE,
      convert_only = input$convert_only %||% FALSE,
      cont_exclude = input$cont_exclude %||% FALSE,
      cont_tag = trimws(input$cont_tag %||% "cRAP-"),
      extra = input$extra_args %||% "",
      notify_email = trimws(input$notify_email %||% ""),
      project_desc = trimws(input$project_desc %||% "")
    )
  })

  # ---------- 校验 ----------
  validation_msgs <- reactive({
    p <- params_ready()
    msgs <- character(0)
    warn <- character(0)
    info <- character(0)
    if (!nz_str(p$sif)) msgs <- c(msgs, "✗ 未选择 sif 镜像")
    else if (!file.exists(p$sif)) msgs <- c(msgs, sprintf("✗ sif 镜像不存在: %s", p$sif))
    th <- suppressWarnings(as.integer(p$threads))
    if (length(p$threads) != 1 || is.na(th) || th < 1 || th > 1024) {
      msgs <- c(msgs, "✗ 线程数无效 (需 1–1024 的整数): Slurm --cpus-per-task 与 DIA-NN --threads 均使用该值")
    }
    if (!is.null(input$time_h) && !is.na(input$time_h) && input$time_h < 1) {
      info <- c(info, "ℹ 时限填了小于 1 的小时数, 将按不限时提交")
    }
    has_raws <- length(p$raws) > 0 || (identical(p$raw_mode, "dir") && nz_str(p$raw_dir))
    # 预测库独立生成模式 (--gen-spec-lib) 不需要 RAW 文件
    if (!has_raws && !isTRUE(p$gen_spec_lib)) msgs <- c(msgs, "✗ 未选择 RAW 文件/目录")
    if (!nz_str(p$out_dir)) msgs <- c(msgs, "✗ 未选择输出目录")
    else if (dir.exists(p$out_dir) && file.access(p$out_dir, 2) != 0) {
      msgs <- c(msgs, sprintf(paste0("✗ 输出目录对 GUI 运行身份 (%s) 不可写, 将无法保存脚本/结果: %s",
                                     " — 请改用输出工作区目录 (如 project/), 或请目录属主为 GUI 账户授权 (setfacl -m u:%s:rwx 或 chgrp+2770)"),
                              Sys.info()[["user"]], p$out_dir, Sys.info()[["user"]]))
    }
    if (nz_str(p$notify_email)) {
      if (grepl("^[^@,\\s]+@[^@,\\s]+\\.[^@,\\s]+(\\s*,\\s*[^@,\\s]+@[^@,\\s]+\\.[^@,\\s]+)*$", p$notify_email)) {
        if (!file.exists(MAIL_CONF)) {
          warn <- c(warn, sprintf("ℹ 已填写邮箱, 但未找到邮件配置 %s, 将不会发送通知邮件 (参考 mail_config.example.txt)", MAIL_CONF))
        }
      } else {
        msgs <- c(msgs, "✗ 邮箱通知格式不正确 (多个邮箱用英文逗号分隔)")
      }
    }
    if (isTRUE(p$convert_only)) {
      warn <- c(warn, "ℹ 转换模式: 命令仅包含文件与 --convert, .dia 文件将保存在 RAW 文件所在目录")
    } else {
      if (!nz_str(p$out_file)) msgs <- c(msgs, "✗ 主报告文件名不能为空")
      if (nz_str(p$lib)) {
        # 光谱库模式: FASTA 可选 (注释/重注释), 无需 --fasta-search
      } else if (!length(p$fastas)) {
        msgs <- c(msgs, "✗ 光谱库与 FASTA 至少需提供一个")
      } else if (!isTRUE(p$fasta_search) && !isTRUE(p$gen_spec_lib)) {
        msgs <- c(msgs, "✗ 无光谱库时必须勾选 --fasta-search (无库搜索) 或 --gen-spec-lib (生成预测库)")
      }
    }
    # --gen-spec-lib 双语义: 无光谱库 = FASTA 预测建库; 有光谱库 = 经验谱库工作流 (搜库+精修输出库, DIA-NN 推荐做法, 不告警)
    if (isTRUE(p$gen_spec_lib)) {
      if (!length(p$fastas) && !nz_str(p$lib)) {
        msgs <- c(msgs, "✗ 生成预测库必须提供 FASTA (或选择光谱库以生成经验谱库)")
      } else if (has_raws && !nz_str(p$lib)) {
        warn <- c(warn, "ℹ FASTA 预测建库与搜库将同场执行 (组合模式); DIA-NN 建议先不选 RAW 独立生成预测库, 再用该库搜库 (库可复用, 结果更稳)")
      } else if (has_raws) {
        info <- c(info, "ℹ 经验谱库工作流: 以光谱库搜库, 并用本次鉴定精修输出谱库 (--out-lib); 该库可用于全部样本的后续搜索")
      }
    }
    if (isTRUE(p$cont_exclude) && isTRUE(p$gen_spec_lib)) {
      info <- c(info, "ℹ 污染物 cRAP 将编入输出谱库, 便于后续搜库时鉴定并经 --cont-quant-exclude 从定量矩阵扣除")
    }
    if (nz_str(p$lib) && length(p$fastas)) {
      info <- c(info, "ℹ 已同时选择光谱库与 FASTA: FASTA 预测前体将并入搜索空间 (可扩充库覆盖; 若 FASTA 与库内容相同则为重复预测, 清除 FASTA 可提速)")
    }
    if (isTRUE(p$cont_exclude) && nz_str(CON_FASTA) && !file.exists(CON_FASTA)) {
      msgs <- c(msgs, sprintf("✗ 污染物 FASTA 不存在: %s", CON_FASTA))
    }
    for (m in p$var_mod_rows) {
      if (any(nz_str(m)) && !all(nz_str(m))) msgs <- c(msgs, sprintf("✗ 可变修饰行不完整: %s (需 名称,质量,位点)", paste(m, collapse = ",")))
    }
    for (m in p$fixed_mod_rows) {
      if (any(nz_str(m)) && !all(nz_str(m))) msgs <- c(msgs, sprintf("✗ 固定修饰行不完整: %s", paste(m, collapse = ",")))
    }
    if (isTRUE(p$gen_spec_lib) && nz_str(p$out_lib)) {
      if (!startsWith(p$out_lib, "/")) {
        msgs <- c(msgs, "✗ 谱库输出路径必须是服务器绝对路径 (以 / 开头)")
      } else if (!dir.exists(dirname(p$out_lib))) {
        msgs <- c(msgs, sprintf("✗ 谱库输出路径的父目录不存在: %s", dirname(p$out_lib)))
      }
    }
    if (nz_str(p$out_lib) && grepl("^[A-Za-z]:[\\\\/]", p$out_lib)) {
      msgs <- c(msgs, "✗ --out-lib 是 Windows 盘符路径 (如 I:\\...), 服务器上不可用, 请清空或改为服务器路径")
    }
    # 额外参数中的裸旗标 (手输或历史残留) 会让 diann-linux 直接报错
    toks <- strsplit(trimws(p$extra), "[[:space:]]+")[[1]]
    toks <- toks[nzchar(toks)]
    vflags <- PATH_VALUE_FLAGS
    bare <- character(0)
    if (length(toks)) for (i in seq_along(toks)) {
      if (toks[i] %in% vflags && (i == length(toks) || grepl("^--", toks[i + 1]))) bare <- c(bare, toks[i])
    }
    if (length(bare)) msgs <- c(msgs, sprintf(
      "✗ 额外参数中 %s 缺少取值 (通常是命令导入时 Windows 路径被丢弃残留), 请清理「额外参数」",
      paste(unique(bare), collapse = " ")))
    list(block = msgs, warn = warn, info = info)
  })

  output$validation_msgs <- renderUI({
    v <- validation_msgs()
    tags$div(
      if (length(v$block)) tags$p(class = "msg-err", HTML(paste(v$block, collapse = "<br>"))),
      if (length(v$warn)) tags$p(style = "color:#b8860b;", HTML(paste(v$warn, collapse = "<br>"))),
      if (length(v$info)) tags$p(style = "color:#5a7ca6;", HTML(paste(v$info, collapse = "<br>"))),
      if (!length(v$block) && !length(v$warn) && !length(v$info)) tags$p(style = "color:#27ae60;", "✔ 校验通过, 可提交")
    )
  })

  # ---------- 预览 ----------
  output$preview <- renderText({
    make_slurm_script(params_ready())
  })

  # ---------- 预设模板 ----------
  observeEvent(input$preset_lib, {
    updateCheckboxInput(session, "convert_only", value = FALSE)
    updateCheckboxInput(session, "fasta_search", value = TRUE)
    updateCheckboxInput(session, "gen_spec_lib", value = TRUE)
    updateCheckboxInput(session, "predictor", value = TRUE)
    showNotification("已应用预测库模板: 请选择 FASTA 与输出目录; --out-lib 留空时自动存为 <输出目录>/library.speclib (生成 library.predicted.speclib)",
                     type = "message", duration = 12)
  })
  observeEvent(input$preset_convert, {
    updateCheckboxInput(session, "convert_only", value = TRUE)
    showNotification("已切换为 RAW→DIA 转换模式: 只需选择 RAW 文件与输出目录, 其余分析参数将被忽略",
                     type = "message", duration = 12)
  })

  # ---------- 命令导入 ----------
  # 导入前的分析参数重置 (限定范围): 清掉上一次导入/手填的残留, 保证导入结果只反映粘贴的命令。
  # 不动: sif 镜像、Slurm 分区/内存/时限、邮箱、项目简介、RAW 文件选择器与 raw_mode。
  # threads 兼具资源属性, 采取 sticky 策略——仅当导入命令含 --threads 时才改写。
  reset_import_state <- function() {
    for (ctrl in unname(BOOL_FLAG_MAP)) updateCheckboxInput(session, ctrl, value = FALSE)
    for (ctrl in c("use_cut", "cont_exclude")) updateCheckboxInput(session, ctrl, value = FALSE)
    for (ctrl in c("qvalue", "mass_acc", "mass_acc_ms1", "window", "min_peak", "rt_window",
                   "im_window", "quant_qvalue", "protein_quant_qvalue", "matrix_qvalue",
                   "missed_cleavages", "min_pep_len", "max_pep_len", "min_pr_mz", "max_pr_mz",
                   "min_pr_charge", "max_pr_charge", "min_fr_mz", "max_fr_mz",
                   "out_lib_qvalue", "xic", "min_corr")) {
      updateNumericInput(session, ctrl, value = NA)
    }
    updateSelectInput(session, "verbose", selected = "1")
    updateTextInput(session, "cut", value = "K*,R*,!*P")
    updateTextInput(session, "out_lib", value = "")
    updateTextInput(session, "cont_tag", value = "cRAP-")
    updateTextInput(session, "report_name", value = "report")
    updateTextAreaInput(session, "extra_args", value = "")
    for (i in 1:6) {
      updateTextInput(session, paste0("vm_name_", i), value = vm_default(i, 1))
      updateTextInput(session, paste0("vm_mass_", i), value = if (i <= 2) vm_default(i, 2) else "")
      updateTextInput(session, paste0("vm_sites_", i), value = if (i <= 2) vm_default(i, 3) else "")
    }
    for (i in 1:3) {
      updateTextInput(session, paste0("fm_name_", i), value = "")
      updateTextInput(session, paste0("fm_mass_", i), value = "")
      updateTextInput(session, paste0("fm_sites_", i), value = "")
    }
    updateNumericInput(session, "var_mods_max", value = 1)
    ov$raws <- character(0); ov$fastas <- character(0)
    ov$lib <- ""; ov$ref <- ""; ov$temp <- ""; ov$out_dir <- ""
    for (ctrl in c("use_imported_raws", "use_imported_lib", "use_imported_fasta",
                   "use_imported_ref", "use_imported_out", "use_imported_temp")) {
      updateCheckboxInput(session, ctrl, value = FALSE)
    }
  }

  observeEvent(input$import_btn, {
    txt <- input$import_cmd
    if (!nz_str(txt)) {
      showNotification("请先在文本框中粘贴 DIA-NN 命令", type = "error")
      return()
    }
    pr <- parse_diann_command(txt)
    reset_import_state()

    for (flag in pr$bool) updateCheckboxInput(session, unname(BOOL_FLAG_MAP[[flag]]), value = TRUE)
    for (flag in names(pr$num)) {
      if (flag == "--verbose") {
        updateSelectInput(session, "verbose", selected = as.character(as.integer(pr$num[[flag]])))
      } else {
        updateNumericInput(session, unname(NUM_FLAG_MAP[[flag]]), value = pr$num[[flag]])
      }
    }
    if (!is.null(pr$text[["--cut"]])) {
      updateTextInput(session, "cut", value = pr$text[["--cut"]])
      updateCheckboxInput(session, "use_cut", value = TRUE)
    }
    ol <- pr$text[["--out-lib"]]
    if (!is.null(ol) && !is_win_path(ol)) updateTextInput(session, "out_lib", value = ol)
    if (!is.null(pr$text[["--cont-quant-exclude"]])) {
      updateTextInput(session, "cont_tag", value = pr$text[["--cont-quant-exclude"]])
      updateCheckboxInput(session, "cont_exclude", value = TRUE)
    }
    if (isTRUE(pr$cont_fasta)) updateCheckboxInput(session, "cont_exclude", value = TRUE)

    if (length(pr$var_mods)) {
      for (i in seq_len(min(length(pr$var_mods), 6))) {
        updateTextInput(session, paste0("vm_name_", i), value = pr$var_mods[[i]][1])
        updateTextInput(session, paste0("vm_mass_", i), value = pr$var_mods[[i]][2])
        updateTextInput(session, paste0("vm_sites_", i), value = pr$var_mods[[i]][3])
      }
    }
    # var_mods_max: 显式 --var-mods 优先, 修饰行数仅兜底; 不回读 input (shiny 批量更新下读到的是旧值)
    vmm <- imported_var_mods_max(pr)
    if (!is.null(vmm)) updateNumericInput(session, "var_mods_max", value = vmm)
    if (length(pr$fixed_mods)) {
      for (i in seq_len(min(length(pr$fixed_mods), 3))) {
        updateTextInput(session, paste0("fm_name_", i), value = pr$fixed_mods[[i]][1])
        updateTextInput(session, paste0("fm_mass_", i), value = pr$fixed_mods[[i]][2])
        updateTextInput(session, paste0("fm_sites_", i), value = pr$fixed_mods[[i]][3])
      }
    }

    # 文件路径写入覆盖层 (shinyFiles 无法编程填充); 超出 BASE_VOLUMES 范围的路径拒绝导入
    f <- pr$files
    rejected <- character(0)
    scope_keep <- function(x, label) {
      if (!length(x) || (length(x) == 1 && !nzchar(x))) return(x)
      ok <- path_in_scope(x)
      bad <- x[!ok]
      if (length(bad)) rejected <<- c(rejected, sprintf("  %s: %s", label, paste(bad, collapse = ", ")))
      if (length(x) == 1) (if (ok) x else "") else x[ok]
    }
    f$raws <- scope_keep(f$raws, "RAW")
    f$fastas <- scope_keep(f$fastas, "FASTA")
    f$lib <- scope_keep(f$lib, "光谱库")
    f$ref <- scope_keep(f$ref, "校准库")
    f$temp <- scope_keep(f$temp, "临时目录")
    f$out_dir <- scope_keep(f$out_dir, "输出目录")
    if (length(f$raws) || length(f$fastas) || nz_str(f$lib) || nz_str(f$ref) || nz_str(f$temp) || nz_str(f$out_dir)) {
      ov$raws <- f$raws; ov$fastas <- f$fastas
      ov$lib <- f$lib; ov$ref <- f$ref; ov$temp <- f$temp; ov$out_dir <- f$out_dir
      # 按类自动勾选覆盖 (该类解析出路径才勾)
      if (length(f$raws))    updateCheckboxInput(session, "use_imported_raws", value = TRUE)
      if (length(f$fastas))  updateCheckboxInput(session, "use_imported_fasta", value = TRUE)
      if (nz_str(f$lib))     updateCheckboxInput(session, "use_imported_lib", value = TRUE)
      if (nz_str(f$ref))     updateCheckboxInput(session, "use_imported_ref", value = TRUE)
      if (nz_str(f$out_dir)) updateCheckboxInput(session, "use_imported_out", value = TRUE)
      if (nz_str(f$temp))    updateCheckboxInput(session, "use_imported_temp", value = TRUE)
    }
    if (nz_str(pr$report_name)) updateTextInput(session, "report_name", value = pr$report_name)

    if (length(pr$unknown)) {
      updateTextAreaInput(session, "extra_args",
                          value = trimws(paste(pr$unknown, collapse = " ")))
    }

    info <- c(sprintf("✔ 已重置旧分析参数并填充: %d 个布尔旗标 | %d 个数值参数 | %d 行可变修饰 | %d 行固定修饰",
                      length(pr$bool), length(pr$num), length(pr$var_mods), length(pr$fixed_mods)))
    if (length(pr$var_mods) > 6) info <- c(info, sprintf("⚠ 可变修饰超过 6 行, 仅导入前 6 行 (丢弃 %d 行)", length(pr$var_mods) - 6L))
    if (length(pr$fixed_mods) > 3) info <- c(info, sprintf("⚠ 固定修饰超过 3 行, 仅导入前 3 行 (丢弃 %d 行)", length(pr$fixed_mods) - 3L))
    if (length(pr$bool)) info <- c(info, paste0("布尔旗标: ", paste(pr$bool, collapse = " ")))
    if (length(pr$num)) info <- c(info, paste0("数值: ", paste(sprintf("%s = %s", names(pr$num), unlist(pr$num)), collapse = "; ")))
    if (length(f$raws)) info <- c(info, sprintf("RAW 文件 ×%d (已写入导入覆盖层)", length(f$raws)))
    if (length(f$fastas)) info <- c(info, sprintf("FASTA ×%d (已写入导入覆盖层)", length(f$fastas)))
    if (nz_str(f$lib)) info <- c(info, paste0("光谱库: ", f$lib))
    if (nz_str(f$out_dir)) info <- c(info, paste0("输出目录: ", f$out_dir))
    if (length(rejected)) info <- c(info,
      c(sprintf("⚠ 以下路径超出允许的数据范围 (%s), 已拒绝导入:",
                paste(unname(BASE_VOLUMES), collapse = ", ")), rejected))
    if (isTRUE(pr$cont_fasta)) info <- c(info, "检测到内置污染物库 --fasta, 已自动转换为启用污染物扣除")
    if (length(pr$windows_paths)) info <- c(info, c("⚠ 以下为 Windows 路径, 服务器上不可用, 已跳过:", paste0("  ", pr$windows_paths)))
    if (isTRUE(pr$bare_lib) && "--gen-spec-lib" %in% pr$bool) {
      info <- c(info, "检测到裸 --lib 且命令无 RAW 文件 (Windows 预测库生成命令): 已自动勾选「生成谱图库」, 谱库默认存为 <输出目录>/library.speclib")
      others <- setdiff(pr$bare, "--lib")
      if (length(others)) info <- c(info, sprintf("以下无取值旗标已忽略: %s", paste(others, collapse = " ")))
    } else if (length(pr$bare)) {
      info <- c(info, sprintf("以下旗标无取值 (Windows GUI 路径留空时导出), 已忽略: %s", paste(pr$bare, collapse = " ")))
    }
    if (length(pr$unknown)) info <- c(info, c("以下未知旗标已追加到「额外参数」:", paste0("  ", pr$unknown)))
    import_txt$txt <- paste(info, collapse = "\n")
    showNotification("命令解析完成, 参数已填充", type = "message", duration = 6)
  })
  output$import_result <- renderText(import_txt$txt)

  # ---------- 集群节点资源 ----------
  sinfo_df <- reactive({
    if (isTRUE(input$auto_refresh)) invalidateLater(10000)
    input$refresh_q
    out <- suppressWarnings(system("sinfo -N -h --states=all -o '%N|%P|%C|%t|%m|%e|%O'", intern = TRUE))
    if (!length(out)) return(NULL)
    rows <- lapply(out, function(l) {
      f <- strsplit(l, "|", fixed = TRUE)[[1]]
      if (length(f) < 7) return(NULL)
      cpu <- strsplit(f[3], "/", fixed = TRUE)[[1]]
      cpu_str <- if (length(cpu) >= 4) sprintf("%s / %s / %s", cpu[1], cpu[2], cpu[4]) else f[3]
      data.frame(节点 = f[1], 分区 = f[2], `CPU(分配/空闲/总)` = cpu_str, 状态 = f[4],
                 `总内存(GB)` = round(suppressWarnings(as.numeric(f[5])) / 1024, 1),
                 `空闲内存(GB)` = round(suppressWarnings(as.numeric(f[6])) / 1024, 1),
                 CPU负载 = suppressWarnings(as.numeric(f[7])),
                 stringsAsFactors = FALSE, check.names = FALSE)
    })
    rows <- Filter(Negate(is.null), rows)
    if (!length(rows)) NULL else do.call(rbind, rows)
  })
  output$sinfo_table <- renderTable({
    d <- sinfo_df()
    if (is.null(d)) data.frame(信息 = "(sinfo 无输出——无法获取集群节点信息)", stringsAsFactors = FALSE) else d
  }, striped = TRUE, bordered = TRUE, na = "-")

  # ---------- 提交 ----------
  observeEvent(input$submit_job, {
    v <- validation_msgs()
    if (length(v$block)) {
      showNotification(HTML(paste(v$block, collapse = "<br>")), type = "error", duration = NULL)
      return()
    }
    p <- params_ready()
    script_dir <- file.path(p$out_dir, "diann_gui_scripts")
    if (!dir.create(script_dir, recursive = TRUE, showWarnings = FALSE) && !dir.exists(script_dir)) {
      showNotification(paste("无法创建脚本目录:", script_dir,
                             "(GUI 运行身份对输出目录无写权限 — 请改用输出工作区目录, 或请目录属主为该身份授权)"),
                       type = "error", duration = NULL)
      return()
    }
    # dir.create 陷阱的补救: out_dir 祖先链每一层(含新建的中间父目录)恢复
    # 组diann + 组可写 + setgid, 否则 mass 在中间层就被挡住, 作业也无法写结果
    fix_shared_dirs(unique(c(p$out_dir, script_dir)))
    # 遗留产物归档: 旧 report/矩阵改名为 *.pre_<时间戳>.tsv, 防止其掩盖本次运行的状态判定
    archived <- character(0)
    if (nz_str(p$out_file) && dir.exists(p$out_dir)) {
      rep_base <- tools::file_path_sans_ext(basename(p$out_file))
      olds <- list.files(p$out_dir, pattern = paste0("^", rep_base, "(.*matrix.*)?\\.tsv$"), full.names = TRUE)
      olds <- olds[file.exists(olds) & file.info(olds)$size > 0]
      if (length(olds)) {
        stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
        for (f in olds) {
          tgt <- sprintf("%s.pre_%s.tsv", file.path(p$out_dir, tools::file_path_sans_ext(basename(f))), stamp)
          if (file.rename(f, tgt) || (file.copy(f, tgt, overwrite = TRUE) && file.remove(f))) {
            archived <- c(archived, sprintf("%s → %s", basename(f), basename(tgt)))
          }
        }
      }
    }
    sh_path <- file.path(script_dir, sprintf("diann_%s_%s.sh", format(Sys.time(), "%Y%m%d_%H%M%S"), p$job_name))
    desc_path <- if (nz_str(p$project_desc)) sub("\\.sh$", "_desc.txt", sh_path) else ""
    if (nz_str(desc_path)) writeLines(p$project_desc, desc_path)
    pp <- p; pp$script_path <- sh_path; pp$desc_file <- desc_path
    writeLines(make_slurm_script(pp), sh_path)
    res <- suppressWarnings(system2("sbatch", shQuote(sh_path), stdout = TRUE, stderr = TRUE))
    res_txt <- paste(res, collapse = " ")
    if (grepl("Submitted batch job [0-9]+", res_txt)) {
      jid <- sub(".*Submitted batch job ([0-9]+).*", "\\1", res_txt)
      jobs$jobs <- rbind(jobs$jobs, data.frame(
        jobid = jid, 任务名 = p$job_name, 版本 = p$ver,
        输出目录 = p$out_dir, 提交时间 = format(Sys.time(), "%H:%M:%S"),
        邮箱 = if (nz_str(p$notify_email)) p$notify_email else "",
        stringsAsFactors = FALSE
      ))
      updateNumericInput(session, "log_id", value = suppressWarnings(as.integer(jid)))
      try(jobs_registry_add(jid, p$job_name, p$out_dir), silent = TRUE)
      if (nz_str(p$notify_email)) {
        try(diann_notify_add(list(jobid = jid, to = p$notify_email, task = p$job_name,
                                   out_dir = p$out_dir, out_file = p$out_file, sif = p$sif,
                                   script_path = sh_path, desc_file = desc_path)), silent = TRUE)
        try(ensure_diann_watcher(), silent = TRUE)
      }
      showNotification(sprintf("✔ 提交成功, JobID: %s\n脚本: %s", jid, sh_path),
                       type = "message", duration = 10)
      if (length(archived)) {
        showNotification(HTML(paste0("已归档上次运行的遗留产物 (防掩盖本次状态):<br>",
                                     paste(archived, collapse = "<br>"))),
                         type = "warning", duration = 12)
      }
    } else {
      showNotification(HTML(paste0("✗ 提交失败:<br>", html_unescape(paste(res, collapse = "<br>")))),
                       type = "error", duration = NULL)
    }
  })

  # ---------- 任务队列 ----------
  output$squeue_output <- renderText({
    if (isTRUE(input$auto_refresh)) invalidateLater(10000)
    input$refresh_q
    out <- suppressWarnings(system(
      sprintf("squeue -u %s -o '%%.10i %%.24j %%.8u %%.8T %%.10M %%.6D %%R'", user),
      intern = TRUE))
    if (!length(out)) "(squeue 无输出)" else paste(out, collapse = "\n")
  })
  # sacct 状态码 → 中文 (20.11 的 CANCELLED 可能带 "by <uid>" 尾巴, 用前缀匹配)
  sacct_state_cn <- function(s) {
    map <- c(COMPLETED = "已完成", RUNNING = "运行中", PENDING = "排队中", COMPLETING = "收尾中",
             CONFIGURING = "配置中", FAILED = "失败", TIMEOUT = "超时", OUT_OF_MEMORY = "内存超限",
             NODE_FAIL = "节点故障", PREEMPTED = "被抢占", SUSPENDED = "挂起", BOOT_FAIL = "启动失败",
             DEADLINE = "到期终止", REQUEUED = "重新排队", CANCELLED = "已取消")
    out <- character(length(s))
    for (i in seq_along(s)) {
      x <- toupper(trimws(s[i]))
      if (!nzchar(x)) { out[i] <- x; next }
      hit <- names(map)[x == names(map)]
      if (!length(hit)) {
        pfx <- names(map)[startsWith(x, names(map))]
        if (length(pfx)) hit <- pfx[which.max(nchar(pfx))]
      }
      out[i] <- if (length(hit)) unname(map[hit[1]]) else s[i]
    }
    out
  }
  output$sacct_table <- renderTable({
    if (isTRUE(input$auto_refresh)) invalidateLater(10000)
    input$refresh_q
    since <- format(Sys.Date() - 1, "%Y-%m-%d")
    out <- suppressWarnings(system(
      sprintf("sacct -u %s -S %s -X -n --parsable2 -o jobid,jobname,state,elapsed,end", user, since),
      intern = TRUE))
    if (!length(out)) {
      return(data.frame(信息 = "(sacct 无输出——本集群未开启作业记账 (accounting), 无法显示历史)",
                        stringsAsFactors = FALSE))
    }
    rows <- strsplit(out, "|", fixed = TRUE)
    rows <- rows[vapply(rows, function(x) length(x) >= 5, logical(1))]
    if (!length(rows)) {
      return(data.frame(信息 = "(sacct 输出为空: 最近一天没有作业记录)", stringsAsFactors = FALSE))
    }
    d <- data.frame(
      作业ID = vapply(rows, function(x) trimws(x[1]), ""),
      作业名 = vapply(rows, function(x) trimws(x[2]), ""),
      状态 = sacct_state_cn(vapply(rows, function(x) trimws(x[3]), "")),
      运行时长 = vapply(rows, function(x) trimws(x[4]), ""),
      结束时间 = vapply(rows, function(x) trimws(x[5]), ""),
      stringsAsFactors = FALSE
    )
    d$运行时长[!nzchar(d$运行时长) | grepl("^Unknown$", d$运行时长, ignore.case = TRUE)] <- "-"
    d$结束时间[!nzchar(d$结束时间) | grepl("^Unknown$", d$结束时间, ignore.case = TRUE)] <- "-"
    d
  }, striped = TRUE, bordered = TRUE, na = "-")
  output$jobs_table <- renderTable(jobs$jobs, striped = TRUE, bordered = TRUE)
  output$notify_status <- renderText({
    if (isTRUE(input$auto_refresh)) invalidateLater(15000)
    try(ensure_diann_watcher(), silent = TRUE)  # 页面打开期间 watcher 失联的自愈
    state <- diann_notify_load()
    recs <- state$recs
    if (!length(recs)) return("")
    lines <- c("—— 提交记录与邮件通知 (最近 100 条) ——")
    live_budget <- 10L  # 未处理记录的实时状态合成上限, 防止 sacct 查询风暴
    for (r in recs) {
      lr <- if (length(r$last_result) && nzchar(r$last_result)) r$last_result else ""
      lab <- ""
      if (!isTRUE(r$done)) {
        if (live_budget > 0) {
          live_budget <- live_budget - 1L
          st <- tryCatch(
            diann_job_status(r$jobid, r$out_dir, r$out_file,
                             script_path = r$script_path, submitted = r$submitted),
            error = function(e) NULL)
          if (!is.null(st)) lab <- sprintf("[%s] %s ", st$label, st$reason)
        }
      } else if (!is.null(r$status_label) && nzchar(r$status_label)) {
        rs <- if (!is.null(r$status_reason) && nzchar(r$status_reason)) paste0(" (", r$status_reason, ")") else ""
        lab <- paste0("[", r$status_label, "]", rs, " ")
      }
      lines <- c(lines, sprintf("Job %s → %s [%s] %s%s",
                                r$jobid, r$to, if (isTRUE(r$done)) "已处理" else "等待完成…", lab, lr))
    }
    paste(lines, collapse = "\n")
  })

  # 取消作业 (弹窗确认)
  observeEvent(input$cancel_btn, {
    jid <- input$cancel_id
    if (is.null(jid) || is.na(jid)) {
      showNotification("请先输入要取消的作业 ID", type = "error")
      return()
    }
    showModal(modalDialog(
      title = "确认取消作业",
      sprintf("确认取消作业 %d 吗? 该操作不可撤销。", as.integer(jid)),
      footer = tagList(
        modalButton("返回"),
        actionButton("cancel_confirm", "确认取消", class = "btn-danger")
      )
    ))
  })
  observeEvent(input$cancel_confirm, {
    removeModal()
    jid <- as.integer(input$cancel_id)
    res <- suppressWarnings(system2("scancel", as.character(jid), stdout = TRUE, stderr = TRUE))
    if (is.null(res) || !length(res)) {
      showNotification(sprintf("已发送 scancel %d", jid), type = "message")
    } else {
      showNotification(paste("scancel 返回:", paste(res, collapse = " ")), type = "warning")
    }
  })

  # 日志查看: 按 JobID 自动定位 (手动目录 → 本会话提交记录 → GUI 持久注册表 → scontrol → sacct 工作目录)
  # 注: 本集群 Slurm 20.11 的 sacct 不支持 stdout 字段, 早已结束且非本 GUI 提交的作业 Slurm 侧无路径可查
  locate_job_log <- function(jid_int) {
    fname <- sprintf("slurm-%d.out", jid_int)
    dirs <- unique(c(if (length(selected_log_dir())) selected_log_dir() else character(0),
                     jobs$jobs[["输出目录"]]))
    for (d in dirs) {
      cand <- file.path(d, fname)
      if (file.exists(cand)) return(list(path = cand, src = if (identical(d, selected_log_dir()[1])) "手动指定目录" else "本会话提交记录"))
    }
    reg <- jobs_registry_load()
    hit <- reg[reg$jobid == as.character(jid_int), , drop = FALSE]
    if (nrow(hit) && file.exists(hit$日志[nrow(hit)])) {
      return(list(path = hit$日志[nrow(hit)], src = "GUI 提交注册表"))
    }
    sc <- suppressWarnings(system2("scontrol", c("show", "job", as.character(jid_int)),
                                   stdout = TRUE, stderr = TRUE))
    mo <- regmatches(paste(sc, collapse = " "), regexpr("StdOut=\\S+", paste(sc, collapse = " ")))
    if (length(mo)) {
      cand <- sub("^StdOut=", "", mo)
      if (file.exists(cand)) return(list(path = cand, src = "scontrol (Slurm 实时信息)"))
    }
    sw <- suppressWarnings(system(sprintf("sacct -j %d -X -n -o workdir%%250 2>/dev/null", jid_int), intern = TRUE))
    if (length(sw) && nzchar(trimws(sw[1]))) {
      cand <- file.path(trimws(sw[1]), fname)
      if (file.exists(cand)) return(list(path = cand, src = "sacct 工作目录"))
    }
    NULL
  }
  log_text <- eventReactive(input$view_log, {
    jid <- input$log_id
    if (is.null(jid) || is.na(jid)) return("请先输入作业 ID")
    jid_int <- suppressWarnings(as.integer(jid))
    hit <- locate_job_log(jid_int)
    if (is.null(hit)) {
      dmsg <- if (length(selected_log_dir())) sprintf("手动目录: %s", selected_log_dir()) else "未手动指定日志目录"
      return(paste0(
        sprintf("未能自动定位 slurm-%d.out。\n", jid_int),
        "已依次尝试: 手动目录 → 本会话提交记录 → GUI 提交注册表 → scontrol (Slurm) → sacct 工作目录。\n",
        dmsg, "\n",
        "说明: 运行中/排队中/刚结束的作业可经 scontrol 定位; 本 GUI 提交的作业永久记录在注册表;\n",
        "早已结束且非本 GUI 提交的作业, Slurm 记账库不保存日志路径 (20.11), 请手动指定日志目录。"))
    }
    txt <- suppressWarnings(system2("tail", c("-n", "120", shQuote(hit$path)), stdout = TRUE, stderr = TRUE))
    header <- sprintf("=== %s (尾部 %d 行, 来源: %s) ===\n", hit$path, length(txt), hit$src)
    err_part <- ""
    errf <- sub("\\.out$", ".err", hit$path)
    if (file.exists(errf)) {
      etxt <- suppressWarnings(system2("tail", c("-n", "30", shQuote(errf)), stdout = TRUE, stderr = TRUE))
      etxt <- etxt[nzchar(trimws(etxt))]
      if (length(etxt)) err_part <- sprintf("\n\n=== %s (尾部 %d 行, 程序报错通常在这里) ===\n%s",
                                            errf, length(etxt), paste(etxt, collapse = "\n"))
    }
    paste0(header, paste(txt, collapse = "\n"), err_part)
  })
  output$log_output <- renderText(log_text())

  # ---------- 参数速查 ----------
  output$doc_path_display <- renderText({
    if (!is.null(param_ref)) {
      sprintf("来源: %s (共 %d 个参数)\n官方文档: https://github.com/vdemichev/DiaNN", PARAM_DOC, nrow(param_ref))
    } else "未找到参数说明文档 (DIANN参数说明.md)"
  })
  output$param_ref <- renderUI({
    if (is.null(param_ref)) return(NULL)
    tags$ul(lapply(seq_len(nrow(param_ref)), function(i) {
      tags$li(tags$strong(param_ref$flag[i]), " — ", param_ref$desc[i])
    }))
  })

  # ---------- 更新说明 ----------
  output$version_notes <- renderUI({
    if (!nrow(sif_df)) return(tags$p("未扫描到 sif 镜像, 请检查 config.R 中的 SIF_DIRS"))
    tags$div(
      tags$p(style = "color:#27ae60;",
             "✔ 以下版本均已通过 GUI 三种模式实测 (RAW→DIA 转换 / 直接搜库+MBR+污染物扣除 / FASTA 生成预测库), 全部命令行参数兼容。"),
      tags$ul(lapply(seq_len(nrow(sif_df)), function(i) {
        note <- DIANN_VERSION_NOTES[[sif_df$ver[i]]] %||% "暂无实测说明。"
        tags$li(tags$strong(sprintf("DIA-NN %s", sif_df$ver[i])), " — ", note, tags$br(), tags$code(sif_df$path[i]))
      }))
    )
  })
  output$diann_release_notes <- renderUI({
    tags$div(lapply(DIANN_RELEASE_NOTES, function(e) {
      tags$div(
        h5(tags$strong(sprintf("DIA-NN %s", e$ver)),
           tags$small(sprintf("  (%s · %s)", e$date, e$channel))),
        if (length(e$notes)) tags$ul(style = "color:#8a6d3b; margin-top:2px;",
                                     lapply(e$notes, tags$li)),
        tags$ul(lapply(e$items, tags$li))
      )
    }))
  })
  output$sif_table <- renderTable({
    if (!nrow(sif_df)) return(data.frame(提示 = "未扫描到 sif 镜像", stringsAsFactors = FALSE))
    fi <- file.info(sif_df$path)
    data.frame(版本 = sif_df$ver, sif路径 = sif_df$path,
               `大小(GB)` = round(fi$size / 1024^3, 2),
               修改日期 = format(fi$mtime, "%Y-%m-%d"),
               stringsAsFactors = FALSE, check.names = FALSE)
  }, striped = TRUE, bordered = TRUE)
  output$gui_changelog <- renderUI({
    tags$div(lapply(CHANGELOG, function(e) {
      tags$div(
        h5(tags$strong(e$ver), tags$small(sprintf("  (%s)", e$date))),
        tags$ul(lapply(e$items, tags$li))
      )
    }))
  })
}

shinyApp(ui, server)
