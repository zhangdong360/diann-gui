\name{run_app}
\alias{run_app}
\title{启动 DIA-NN GUI}
\usage{
run_app(port = NULL, host = "127.0.0.1",
        launch.browser = getOption("shiny.launch.browser", interactive()),
        config_file = NULL, app_only = FALSE, analysis_only = FALSE)
}
\arguments{
\item{port}{端口; NULL = 自动选择空闲端口 (30000–39999)}
\item{host}{监听地址, 默认仅本机 (远程经 SSH 隧道 / RStudio 代理访问)}
\item{launch.browser}{是否自动打开浏览器}
\item{config_file}{显式指定配置文件; NULL = 自动发现}
\item{app_only}{TRUE = 只构建并返回 shiny.app 对象, 不启动服务 (嵌入/自定义启动器)}
\item{analysis_only}{TRUE = 仅启动「结果分析」页 (v1.14): 蛋白矩阵 QC/差异分析/
富集/报告, 不初始化 Slurm/apptainer/SIF 运行环境}
}
\description{构建并运行 DIA-NN GUI 的 Shiny 应用。默认直接启动服务并打印
访问地址 (SSH 会话下附隧道命令) 与执行后端 (Slurm 集群 / 本地单机)。
需要 app 对象做嵌入或自定义启动器时使用 \code{app_only = TRUE}。
\code{analysis_only = TRUE} 进入独立结果分析模式 (v1.14): 适合在无容器
环境、或只想对已有 pg_matrix 做下游分析的机器上使用。}

\details{配置按 DIANN_GUI_CONFIG 环境变量 → ~/.diann_gui/config.R →
<工作目录>/diann_gui_config.R 的顺序发现; 均不存在时使用"用户家目录模式"
默认值 (v1.13 起不再读取工作目录的 config.R——legacy 中央 shiny-server
部署已删除)。独立结果分析模式同样读取该配置 (文件浏览器根目录 BASE_VOLUMES
等仍生效), 但跳过执行后端检测; 下游分析依赖 (ggplot2/limma 等) 为可选包,
缺失时页面内给出安装提示。

\strong{从 1.10 升级}: \code{run_app()} 以前在 \code{port = NULL} 时返回 app
对象 (依赖控制台 auto-print 才启动); 1.11 起直接启动。嵌入用法改为
\code{run_app(app_only = TRUE)}。}
\examples{
\dontrun{
run_app()                    # 启动 (随机端口)
run_app(port = 3838)         # 固定端口
run_app(analysis_only = TRUE)  # 仅结果分析页
app <- run_app(app_only = TRUE)
}
}
