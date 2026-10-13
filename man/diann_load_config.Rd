\name{diann_load_config}
\alias{diann_load_config}
\title{加载配置到包内环境}
\usage{
diann_load_config(file = NULL, reset = FALSE)
}
\arguments{
\item{file}{配置文件路径; NULL = 自动发现 (resolve_user_config)}
\item{reset}{TRUE = 先清空包内已有配置再加载}
}
\description{
source 配置文件并把已知键 (DATA_HOME/BASE_VOLUMES/SIF_DIRS/CON_FASTA/
SLURM_*/APPTAINER_*/BIND_PATHS/MAIL_*/NOTIFY_STATE 等) 合并默认值后
装入包配置环境 .cfg; 幂等, reset = TRUE 可强制重新装载。
}
