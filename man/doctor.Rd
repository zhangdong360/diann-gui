\name{doctor}
\alias{doctor}
\title{运行环境自检}
\usage{
doctor(apptainer_cands = NULL, partitions = NULL, slurm_cmds = NULL,
       sif_dirs = NULL, mail_conf = NULL, state_dir = NULL,
       deps = c("shiny", "shinydashboard", "shinyFiles", "htmltools"))
}
\arguments{
\item{apptainer_cands}{apptainer 候选 data.frame (默认调用 apptainer_candidates())}
\item{partitions}{Slurm 分区 (默认 sinfo 探测)}
\item{slurm_cmds}{命名字符向量: 命令名 -> 路径 (默认 Sys.which)}
\item{sif_dirs}{SIF 目录 (默认自动探测)}
\item{mail_conf}{邮件配置文件路径 (默认 cfg_get("MAIL_CONF"))}
\item{state_dir}{状态目录 (默认 dirname(cfg_get("NOTIFY_STATE")))}
\item{deps}{需要检查的依赖包}
}
\description{检查 R 版本、依赖包、Slurm 命令、分区、apptainer 候选、SIF
目录、配置/邮件配置/状态目录与运行身份, 打印检查表供用户或管理员定位问题。}
\details{只读操作, 不修改任何文件。}
\value{data.frame(check, status, detail) (invisible)}
\examples{
\dontrun{
diann.gui::doctor()
}
}
