# ============================================================
# diann_gui 用户设置模板 (自托管模式)
#
# 生成/启用方式 (任选其一; R 包与依赖在安装期自动处理, 无需 EXTRA_LIB):
#   bin/diann-gui --init          # 复制本模板到 ~/.diann_gui/config.R
#   或手动: mkdir -p ~/.diann_gui && cp config.example.R ~/.diann_gui/config.R
#
# 配置发现顺序 (app.R / notify_watch.R): 环境变量 DIANN_GUI_CONFIG 指定的文件
# → ~/.diann_gui/config.R → 与 app.R 同目录的 config.R (中央部署变体)。
#
# 默认即"用户家目录模式", 零配置可用: 数据/输出根 = 你的家目录,
# 作业以当前用户提交, 文件权限与你自己跑命令行完全一致。
# 下面各项全部注释着——取消注释并修改才生效; 未定义的项用 app.R 内置默认。
# 模板中的 DIANN_GUI_USER_HOME 令牌会被 bin/diann-gui --init 替换为你的家目录。
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

# ---- Apptainer / Singularity ----------------------------------------------

# 生成的 sbatch 脚本中查找 apptainer 可执行文件的目录 (存在 <目录>/apptainer
# 则加入 PATH)。按你集群的实际安装位置填写。
# APPTAINER_PATHS <- c("/share/app/conda/conda24/envs/apptainer/bin")

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
# → 与 app.R 同目录的 mail_config.txt (模板见 mail_config.example.txt)。
# 三处都不存在时邮件功能整体停用 (不影响其他功能)。
# MAIL_PYTHON <- "/usr/bin/python3"
