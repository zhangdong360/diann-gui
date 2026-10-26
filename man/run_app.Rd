\name{run_app}
\alias{run_app}
\title{启动 DIA-NN GUI}
\usage{
run_app(port = NULL, host = "127.0.0.1",
        launch.browser = getOption("shiny.launch.browser", interactive()),
        config_file = NULL, app_only = FALSE)
}
\arguments{
\item{port}{端口; NULL = 自动选择空闲端口 (30000--39999)}
\item{host}{监听地址, 默认仅本机 (远程经 SSH 隧道 / RStudio 代理访问)}
\item{launch.browser}{是否自动打开浏览器}
\item{config_file}{显式指定配置文件; NULL = 自动发现}
\item{app_only}{TRUE = 只构建并返回 shiny.app 对象, 不启动服务}
}
\description{构建并运行 DIA-NN GUI 的 Shiny 应用。默认直接启动服务并打印
访问地址 (SSH 会话下附隧道命令); 需要 app 对象做嵌入或历史 shiny-server
入口时使用 \code{app_only = TRUE}。}

\details{配置按 DIANN_GUI_CONFIG 环境变量 → ~/.diann_gui/config.R →
<工作目录>/diann_gui_config.R → (仅有 app.R 标记时) <工作目录>/config.R
的顺序发现; 均不存在时使用"用户家目录模式"默认值。

\strong{从 1.10 升级}: \code{run_app()} 以前在 \code{port = NULL} 时返回 app
对象 (依赖控制台 auto-print 才启动); 1.11 起直接启动。嵌入用法改为
\code{run_app(app_only = TRUE)}。}
\examples{
\dontrun{
run_app()                     # 随机端口启动
run_app(port = 3838)          # 固定端口
app <- run_app(app_only = TRUE)
}
}
