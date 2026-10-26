\name{doctor}
\alias{doctor}
\title{运行环境自检}
\usage{
doctor(apptainer_cands = NULL, partitions = NULL, slurm_cmds = NULL,
       sif_dirs = NULL, mail_conf = NULL, state_dir = NULL,
       deps = c("shiny", "shinydashboard", "shinyFiles", "htmltools"),
       backend = NULL, local_cmds = NULL)
}
\arguments{
\item{apptainer_cands}{apptainer 候选 data.frame (默认调用 apptainer_candidates())}
\item{partitions}{Slurm 分区 (默认 sinfo 探测; 本地模式不探测, 显示 na)}
\item{slurm_cmds}{命名字符向量: 命令名 -> 路径 (默认 Sys.which; 本地模式显示 na)}
\item{sif_dirs}{SIF 目录 (默认自动探测)}
\item{mail_conf}{邮件配置文件路径 (默认 cfg_get("MAIL_CONF"))}
\item{state_dir}{状态目录 (默认 dirname(cfg_get("NOTIFY_STATE")))}
\item{deps}{需要检查的依赖包}
\item{backend}{执行后端 \code{"slurm"} 或 \code{"local"}; \code{NULL} = 用配置解析结果
(默认 slurm)。Slurm 模式检查 Slurm 命令/分区, 本地模式这些项降级为 na,
改为检查 setsid/nohup/timeout/bash 与 /proc 可读性。}
\item{local_cmds}{命名字符向量: 本地原语命令名 -> 路径 (默认 Sys.which)}
}
\description{检查 R 版本、依赖包、执行后端、Slurm 命令/分区 (Slurm 模式)、
本地执行原语 setsid/nohup/timeout/bash 与 /proc (本地模式)、apptainer 候选、
SIF 目录、配置/邮件配置/状态目录与运行身份, 打印检查表供用户或管理员定位问题。}
\details{只读操作, 不修改任何文件。检查表 status 取值: ok / warn / fail / na
(na = 当前执行后端不需要该项); 末尾汇总各类数量。}
\value{data.frame(check, status, detail) (invisible)}
\examples{
\dontrun{
diann.gui::doctor()
diann.gui::doctor(backend = "local")
}
}
