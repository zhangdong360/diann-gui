\name{resolve_user_config}
\alias{resolve_user_config}
\title{解析配置文件路径}
\usage{
resolve_user_config(dir = getwd())
}
\arguments{
\item{dir}{工作目录 (中央部署时为应用目录)}
}
\description{
按顺序探测: 环境变量 DIANN_GUI_CONFIG → ~/.diann_gui/config.R →
<dir>/config.R。均不存在返回 "" (内置默认 = 用户家目录模式)。
}
