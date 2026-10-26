# ============================================================
# 仓库根入口（可选 shim，不是应用本体）
#
# 应用本体在 R 包 diann.gui 里。日常启动只需：
#   library(diann.gui); diann.gui::run_app()        # 自动选端口并打印 URL
#
# 这个文件只服务两种"需要 app 对象"的场景：
#   1. RStudio 的 "Run App" 按钮（对目录运行 shiny::runApp）
#   2. shiny::runApp("仓库目录")
# (v1.13: legacy 中央 shiny-server 部署已删除; 历史实现见 central-shiny-server 分支)
#
# app_only = TRUE 表示只构建并返回 shiny.app 对象，由调用方负责监听端口；
# 直接调用 run_app()（不加 app_only）才是"自己启动服务"的用法。
# ============================================================
diann.gui::run_app(app_only = TRUE)
