\name{set_core_const}
\alias{set_core_const}
\title{写入配置值 (注入接口)}
\usage{
set_core_const(key, value)
}
\arguments{
\item{key}{配置键}
\item{value}{配置值}
}
\description{向包配置环境写入配置值。主要供测试与站点注入使用;
调用后无需重新加载即可被各模块读到。}
