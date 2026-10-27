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
<dir>/diann_gui_config.R。均不存在返回 "" (内置默认 = 用户家目录模式)。
}
\details{
v1.13 起 <dir>/config.R 完全不再被读取 (legacy 中央 shiny-server 部署已删除):
用户在 R / RStudio 中运行 run_app() 时, 项目目录里同名的 config.R 不应劫持配置;
需要项目级配置请显式命名为 diann_gui_config.R。
}
