\name{watch_daemon}
\alias{watch_daemon}
\title{邮件通知守护进程}
\usage{
watch_daemon(state = NULL, pidfile = NULL, interval = 60,
             idle_exit_sec = 86400, once = FALSE)
}
\arguments{
\item{state}{通知状态文件路径 (默认取包配置)}
\item{pidfile}{pid 文件路径 (默认取包配置)}
\item{interval}{轮询间隔秒 (下限 5)}
\item{idle_exit_sec}{空闲自退秒数}
\item{once}{TRUE = 只执行一轮检查即返回}
}
\description{轮询状态文件中的待通知作业, 作业离队后发送完成邮件。
通常由应用自动以 nohup 派生, 无需手动调用。}
