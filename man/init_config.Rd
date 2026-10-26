\name{init_config}
\alias{init_config}
\title{生成每用户配置文件}
\usage{
init_config(path = file.path(path.expand("~"), ".diann_gui", "config.R"),
            overwrite = FALSE, auto = interactive(),
            partitions = NULL, apptainer_dirs = NULL,
            default_apptainer = NULL, sif_dirs = NULL)
}
\arguments{
\item{path}{目标文件 (默认 \code{~/.diann_gui/config.R})}
\item{overwrite}{已存在时是否覆盖 (默认 FALSE, 只提示)}
\item{auto}{是否自动探测并写入 Slurm 分区 / apptainer 路径 / SIF 目录}
\item{partitions}{显式注入的分区 (测试用)}
\item{apptainer_dirs}{显式注入的 apptainer 目录 (测试用)}
\item{default_apptainer}{显式注入的默认 apptainer 路径 (测试用)}
\item{sif_dirs}{显式注入的 SIF 目录 (测试用)}
}
\description{把包内模板 \code{inst/config/config.example.R} 复制到用户目录,
并把家目录占位符替换为真实路径。}
\details{文件权限设为 0600。已存在且 \code{overwrite = FALSE} 时不改动,
避免覆盖用户手改过的站点配置。}
\value{配置文件路径 (invisible)}
\examples{
\dontrun{
diann.gui::init_config()
diann.gui::run_app()
}
}
