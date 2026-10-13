\name{usage_report}
\alias{usage_report}
\title{生成平台使用统计 (月度报告)}
\usage{
usage_report(month = format(Sys.Date(), "\%Y-\%m"), out_dir = ".",
             registry = NULL, state = NULL)
}
\arguments{
\item{month}{统计月份, "YYYY-MM" (默认当月)}
\item{out_dir}{报告输出目录}
\item{registry}{注册表 RDS 路径 (默认 HOME 下与 GUI 一致)}
\item{state}{通知状态 RDS 路径 (仅补邮箱)}
}
\description{汇总 GUI 提交注册表, 按四层状态模型合成逐作业状态,
输出 markdown 使用统计报告。}
