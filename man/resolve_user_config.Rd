\name{resolve_user_config}
\alias{resolve_user_config}
\title{解析配置文件路径}
\usage{
resolve_user_config(dir = getwd())
}
\arguments{
\item{dir}{工作目录 (默认 getwd())}
}
\description{
按顺序探测: 环境变量 DIANN_GUI_CONFIG → ~/.diann_gui/config.R →
<dir>/diann_gui_config.R → 仅当 <dir>/app.R 存在 (历史 shiny-server 部署)
时的 <dir>/config.R。均不存在返回 "" (内置默认 = 用户家目录模式)。
}
\details{
不再无条件下读取工作目录的 config.R: 用户在 R / RStudio 中运行 run_app()
时, 项目目录里同名的 config.R 会静默劫持配置。
}
