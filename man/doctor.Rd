\name{doctor}
\alias{doctor}
\title{运行环境自检}
\usage{
doctor(apptainer_cands = NULL, partitions = NULL, slurm_cmds = NULL,
       sif_dirs = NULL, sif_probe = NULL, mail_conf = NULL, state_dir = NULL,
       deps = c("shiny", "shinydashboard", "shinyFiles", "htmltools"),
       backend = NULL, local_cmds = NULL)
}
\arguments{
\item{apptainer_cands}{apptainer 候选 data.frame (默认调用 apptainer_candidates())}
\item{partitions}{Slurm 分区 (默认 sinfo 探测; 本地模式合并为一行 na)}
\item{slurm_cmds}{命名字符向量: 命令名 -> 路径 (默认 Sys.which)}
\item{sif_dirs}{SIF 目录 (默认自动探测; 计入全部 *.sif, 文件名无关)}
\item{sif_probe}{SIF 版本识别缓存 (默认 sif_probe_load(); 只读, 不跑容器)}
\item{mail_conf}{邮件配置文件路径 (默认 cfg_get("MAIL_CONF"))}
\item{state_dir}{状态目录 (默认 dirname(cfg_get("NOTIFY_STATE")))}
\item{deps}{需要检查的依赖包}
\item{backend}{执行后端 \code{"slurm"} 或 \code{"local"}; \code{NULL} = 用配置解析结果
(默认 slurm)。}
\item{local_cmds}{命名字符向量: 本地原语命令名 -> 路径 (默认 Sys.which;
仅本地模式展示)}
}
\description{按重要性分组检查并打印: [0] 执行后端、[1] R 环境、[2] 依赖包
(本地模式追加 setsid/nohup/timeout/bash 与 /proc)、[3] apptainer 依赖、
[4] SIF 镜像 (目录/数量/容器识别状态, 只读缓存)、[5] 其他环境 (DATA_HOME/
数据根/配置/邮件/状态目录/运行身份/本地作业状态文件)、[6] Slurm 依赖
(最后; 本地模式合并为一行不适用)。输出带组标题、状态符号 (✓/⚠/✗/–) 与汇总。}
\details{只读操作, 不修改用户的任何数据/状态文件 (apptainer 候选探测可能刷新其自身的版本缓存)。status 取值: ok / warn / fail / na
(na = 当前执行后端不需要该项)。}
\value{data.frame(group, check, status, detail) (invisible)}
\examples{
\dontrun{
diann.gui::doctor()
diann.gui::doctor(backend = "local")
}
}
