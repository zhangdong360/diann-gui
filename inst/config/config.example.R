# ============================================================
# diann_gui 用户设置模板 (自托管模式)
#
# 生成/启用方式 (任选其一; R 包与依赖在安装期自动处理):
#   diann.gui::init_config()      # 在 R 内生成 ~/.diann_gui/config.R (可自动探测)
#   或手动: mkdir -p ~/.diann_gui && cp config.example.R ~/.diann_gui/config.R
#
# 配置发现顺序 (diann.gui::run_app()): 环境变量 DIANN_GUI_CONFIG 指定的文件
# → ~/.diann_gui/config.R → <工作目录>/diann_gui_config.R
# → (仅历史 shiny-server 部署, 工作目录有 app.R 时) <工作目录>/config.R。
#
# 默认即"用户家目录模式", 零配置可用: 数据/输出根 = 你的家目录,
# 作业以当前用户提交, 文件权限与你自己跑命令行完全一致。
# 下面各项全部注释着——取消注释并修改才生效; 未定义的项用内置默认。
# 模板中的 DIANN_GUI_USER_HOME 令牌会被 init_config() 替换为你的家目录。
# ============================================================

# ---- DIA-NN 容器镜像 ------------------------------------------------------

# 递归扫描 diann*.sif 的目录 (建议: 管理员把镜像统一放在 /share/app/tools/diann/
# 这类全员可读的共享位)。GUI 的版本下拉由扫描结果生成。
# SIF_DIRS <- c("/share/app/tools/diann")

# 默认选中的镜像。留空 = 扫描到的第一个。
# DEFAULT_SIF <- "/share/app/tools/diann/diann-2.7.0.sif"

# ---- 数据位置 -------------------------------------------------------------

# GUI 文件选择器的数据根 (RAW/FASTA/输出目录都应放在它下面)。
# 默认 = 你的家目录, 一般无需设置; 数据放 ~/data 下即可。
# DATA_HOME <- "DIANN_GUI_USER_HOME/data"

# 内置污染物 FASTA (cRAP), 勾选"启用污染物扣除"时附加到命令。
# 留空 = 无预选 (想要 cRAP 扣除时, 自行下载一份 cRAP FASTA 并在此指向它)。
# CON_FASTA <- "DIANN_GUI_USER_HOME/data/fasta/cRAP_contaminants.fasta"

# ---- Slurm ----------------------------------------------------------------

# 提交表单提供的分区; 第一个是默认值。
# SLURM_PARTITIONS <- c("compute")

# 额外写入作业脚本的 #SBATCH 选项 (如 --account=lab / --qos=normal / --reservation=r1),
# 每项一行, 原样追加为 "#SBATCH <选项>"。
# SLURM_EXTRA_ARGS <- c("--account=lab")

# 输出目录保留天数: 超过该天数的脚本/rc/项目简介/旧归档产物自动清理 (0 = 不清理)。
# RETENTION_DAYS <- 90

# ---- Apptainer / Singularity ----------------------------------------------

# 版本要求: SIF 镜像需要 apptainer ≥ 1.0 或 singularity ≥ 3.0 (SIF 自 Singularity 3.0 起)。
# singularity 2.x (含 conda-forge 的 2.4.6) 只能读 squashfs/ext3 的 .simg, 对 .sif 会报
# "Unknown image format/type"; GUI 候选会标「⚠ 不支持 SIF」, 并在提交前直接拦下。
# 运行时在「1. apptainer 运行环境」里选择 (自动识别 PATH 与下列目录, 解析版本后
# 列入候选; 识别不到时可手动输入路径并验证)。这里的目录同时作为作业脚本的
# 回退搜索目录 (存在 <目录>/apptainer 或 <目录>/singularity 即采用)。
# APPTAINER_PATHS <- c("/share/app/conda/conda24/envs/apptainer/bin")

# 预选的 apptainer 路径 (候选里存在时默认选中它, 否则选版本最高的可用项)。
# DEFAULT_APPTAINER <- "/share/app/conda/conda24/envs/apptainer/bin/apptainer"

# GUI 节点看不到/跑不动所选 apptainer 时: FALSE (默认) 只警告并继续, 作业按
# 回退链查找; TRUE 则直接阻断提交 (适合 GUI 与计算节点环境一致的集群)。
# APPTAINER_STRICT_CHECK <- FALSE

# PATH 上找不到 apptainer 时的环境模块兜底。留空 = 关闭模块兜底。
# APPTAINER_MODULE_FALLBACK <- "apptainer/1.4.5"

# 额外绑定进容器的宿主路径 (apptainer --bind)。apptainer 默认只绑 $HOME 与
# 工作目录——数据在别处 (如共享盘 /share) 时需要加。
# BIND_PATHS <- c("/share")

# ---- 共享输出目录 (仅多账户共读同一目录时需要) -------------------------------

# GUI 创建的输出目录逐层 chmod 2770 + chgrp 到该组 (自上而下修到 DATA_HOME)。
# 单人自托管: 保持为空即可 (完全关闭组修复)。仅当同事要用**另一个账号**读你的
# 输出目录时才设置, 并确保双方共享该 Unix 组。
# SHARED_GROUP <- ""

# ---- 邮件通知 (可选) -------------------------------------------------------

# 发送完成邮件用的 python3。留空 = 自动探测 PATH 上的 python3。
# 凭据文件搜索链: 环境变量 DIANN_GUI_MAIL_CONF → ~/.diann_gui/mail_config.txt
# (历史 shiny-server 部署目录有 app.R 时才会读同目录 mail_config.txt;
#  模板见 inst/config/mail_config.example.txt)。
# 都不存在时邮件功能整体停用 (不影响其他功能)。
# MAIL_PYTHON <- "/usr/bin/python3"
