# ============================================================
# run-app.R — 应用入口
# ============================================================
#' 启动 DIA-NN GUI
#'
#' 默认直接启动 Web 服务（未指定端口时自动选一个空闲端口），并在终端打印
#' 访问地址与 SSH 隧道提示。需要拿 app 对象做嵌入/自定义启动时用
#' `app_only = TRUE`。
#'
#' @param port 端口; NULL = 自动选择空闲端口 (30000–39999)
#' @param host 监听地址, 默认仅本机 (远程经 SSH 隧道 / RStudio 代理访问)
#' @param launch.browser 是否自动打开浏览器
#' @param config_file 显式指定配置文件; NULL = 自动发现 (resolve_user_config)
#' @param app_only TRUE = 只构建并返回 shiny.app 对象, 不启动服务
#' @return 启动时返回 `invisible(app)`; `app_only = TRUE` 时返回 shiny.app 对象
#' @examples
#' \dontrun{
#' run_app()                    # 启动 (随机端口)
#' run_app(port = 3838)         # 固定端口
#' app <- run_app(app_only = TRUE)
#' }
#' @export
run_app <- function(port = NULL, host = "127.0.0.1",
                    launch.browser = getOption("shiny.launch.browser", interactive()),
                    config_file = NULL, app_only = FALSE) {
  diann_load_config(config_file)

  # 执行后端 (v1.12): auto 检测 + 安全防护 (HPC 登录节点 / legacy 中央部署)。
  # error 时给出可操作报错并停止启动; warn 打印到控制台。
  backend_startup_check()
  binfo <- backend_info()

  # apptainer 运行环境: 启动时发现候选并解析版本 (带缓存; 登录节点没有 apptainer 也正常,
  # 只有"选择为空"才会在提交前被拦下)。结果供 UI 下拉/自检面板/提交前校验读取。
  .cfg$APPTAINER_CANDS <- tryCatch(apptainer_candidates(),
    error = function(e) data.frame(path = character(0), kind = character(0), source = character(0),
                                   version = character(0), ok = logical(0), checked_at = numeric(0),
                                   stringsAsFactors = FALSE))
  .cfg$APPTAINER_CHOICES <- apptainer_choices(cfg_get("APPTAINER_CANDS"))
  .cfg$APPTAINER_SELECTED <- apptainer_default(cfg_get("APPTAINER_CANDS"))
  .cfg$APPTAINER_MODULE <- tryCatch(apptainer_module_probe(), error = function(e) NULL)

  # 启动期状态: 镜像扫描 / 参数速查 (ui 与 server 经 cfg_get 读取)
  .cfg$sif_df <- scan_sif_images(cfg_get("SIF_DIRS"))
  .cfg$sif_choices <- if (nrow(.cfg$sif_df)) {
    labels <- sprintf("v%s · %s", .cfg$sif_df$ver, .cfg$sif_df$path)
    setNames(.cfg$sif_df$path, labels)
  } else character(0)
  .cfg$sif_selected <- if (cfg_get("DEFAULT_SIF") %in% .cfg$sif_df$path) {
    cfg_get("DEFAULT_SIF")
  } else if (nrow(.cfg$sif_df)) .cfg$sif_df$path[1] else NULL
  pd <- param_doc_path()
  .cfg$PARAM_DOC <- pd
  .cfg$param_ref <- if (nzchar(pd)) parse_param_doc(pd) else NULL

  try(ensure_diann_watcher(), silent = TRUE)

  app <- shinyApp(app_ui(), app_server())
  if (isTRUE(app_only)) return(app)

  if (is.null(port)) {
    port <- tryCatch(httpuv::randomPort(min = 30000L, max = 39999L), error = function(e) NULL)
  }
  who <- Sys.info()[["user"]]
  message(sprintf("DIA-NN GUI %s — 运行身份: %s (作业将以该身份执行)", GUI_VERSION, who))
  message(sprintf("执行后端: %s (%s)", backend_label(),
                  if (isTRUE(binfo$auto)) "自动检测" else "配置指定"))
  message(sprintf("配置文件: %s", if (nzchar(cfg_get("CONFIG_FILE") %||% "")) cfg_get("CONFIG_FILE") else "(内置默认)"))
  message(sprintf("访问地址: http://%s:%s/", host, if (is.null(port)) "(随机)" else port))
  if (!is.null(port) && nzchar(Sys.getenv("SSH_CONNECTION")) && identical(host, "127.0.0.1")) {
    message(sprintf("远程集群: 先建隧道 ssh -L %d:127.0.0.1:%d <用户>@<集群>", port, port))
  }
  message("停止: Ctrl+C")

  shiny::runApp(app, port = port, host = host, launch.browser = launch.browser)
  invisible(app)
}
