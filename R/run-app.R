# ============================================================
# run-app.R — 应用入口
# ============================================================
#' 启动 DIA-NN GUI
#'
#' @param port 端口; NULL = 返回 app 对象 (RStudio 中直接弹出/`shiny::runApp` 可用)
#' @param host 监听地址, 默认仅本机 (远程经 SSH 隧道访问)
#' @param launch.browser 是否自动打开浏览器
#' @param config_file 显式指定配置文件; NULL = 自动发现 (resolve_user_config)
#' @examples
#' \dontrun{
#' run_app(port = 3838)          # 本机/隧道访问
#' app <- run_app()              # 返回 shiny.app 对象
#' }
#' @export
run_app <- function(port = NULL, host = "127.0.0.1",
                    launch.browser = getOption("shiny.launch.browser", interactive()),
                    config_file = NULL) {
  diann_load_config(config_file)

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
  .cfg$param_ref <- if (nzchar(pd)) parse_param_doc(pd) else NULL

  try(ensure_diann_watcher(), silent = TRUE)

  app <- shinyApp(app_ui(), app_server())
  if (is.null(port)) return(app)
  shiny::runApp(app, port = port, host = host, launch.browser = launch.browser)
}
