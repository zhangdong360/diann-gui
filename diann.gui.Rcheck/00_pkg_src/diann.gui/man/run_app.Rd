\name{run_app}
\alias{run_app}
\title{启动 DIA-NN GUI}
\usage{
run_app(port = NULL, host = "127.0.0.1",
        launch.browser = getOption("shiny.launch.browser", interactive()),
        config_file = NULL)
}
\arguments{
\item{port}{端口; NULL = 返回 app 对象 (RStudio 中直接弹出)}
\item{host}{监听地址, 默认仅本机 (远程经 SSH 隧道访问)}
\item{launch.browser}{是否自动打开浏览器}
\item{config_file}{显式指定配置文件; NULL = 自动发现}
}
\description{构建并运行 DIA-NN GUI 的 Shiny 应用。配置按
DIANN_GUI_CONFIG 环境变量 → ~/.diann_gui/config.R → 工作目录 config.R 的
顺序发现; 均不存在时使用"用户家目录模式"默认值。}
\examples{
\dontrun{run_app(port = 3838)}
}
