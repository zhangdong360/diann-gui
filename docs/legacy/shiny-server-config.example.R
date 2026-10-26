# ============================================================
# [legacy / 不推荐] 中央 shiny-server 部署站点配置示例 (已脱敏)
#
# 自托管 (默认) 不需要本文件: 每个用户在 R 里 install.packages() + run_app(),
# 作业以本人身份提交, 天然隔离。仅当无法避免"一个共享实例 + 共享运行身份"时
# 才使用本示例, 并自行承担 SHARED_GROUP / ACL 的权限模型。
#
# 用法: 复制到部署目录并改名 config.R (同目录需有 app.R 标记), 按站点修改。
# 本文件所有路径均为示例合成路径, 不是任何真实站点。
# ============================================================

SIF_DIRS <- c("/share/home/demo/tools/diann")
DEFAULT_SIF <- "/share/home/demo/tools/diann/diann-2.7.0.sif"
DATA_HOME <- "/share/home/demo"
BASE_VOLUMES <- c(Data = DATA_HOME)
SLURM_PARTITIONS <- c("compute", "mgt")
APPTAINER_PATHS <- c("/share/app/conda/conda24/envs/apptainer/bin")
APPTAINER_MODULE_FALLBACK <- "apptainer/1.4.5"
BIND_PATHS <- c("/share")
SHARED_GROUP <- "demo_group"
MAIL_PYTHON <- "/share/app/conda/conda24/bin/python3"
CON_FASTA <- "/share/home/demo/data/fasta/cRAP_contaminants.fasta"
