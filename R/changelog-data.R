# ============================================================
# changelog_data.R — 版本更新说明 (纯数据)
# 环境契约: 由 app.R 以 local=TRUE source 进应用环境 (2026-10-09 事故防线:
# 缺省 source 进 globalenv, app 环境里的引用取不到这些对象)。
# 顺序: 必须在 ui 构造之前。
# ============================================================

# GUI 更新日志 (新的在前)
CHANGELOG <- list(
  list(ver = "v1.14.1", date = "2026-10-28", items = c(
    "修复: 「⑤ 功能富集」页在差异分析成功后必然渲染 Shiny 错误面板 (renderUI 引用了从未赋值的 en, v1.14 回归; e2e 未覆盖该页签所以全绿测试未拦截)——现在正常显示富集结果或依赖缺失提示",
    "修复: 邮件通知停用时不再静默——新增 mail_gate_info() 单一门控: run_app() 启动控制台打印停用原因与配置命令, 提交时填了邮箱弹 ⚠ 通知 (20s), 提交校验面板与 doctor() 同步提示; 补上「有 mail_config.txt 但缺 python3」的提示盲区 (WSL2 实测场景); README/技术手册写明配置在 ~/.diann_gui/mail_config.txt (不在 config.R) 且需 python3",
    "修复: 本地 KEGG ORA 补传 universe (与 GO/在线 KEGG 同用检出蛋白背景)——此前用 KEGG.db 全库做背景, 同一数据在本地/在线开关下 p 值不同且本地偏显著",
    "修复: SIF 版本探测「超时但已产出部分输出」被误归为 no_version 并永久落失败缓存 (不再自动重试)——改为无条件读取 system2 超时状态; 探测缓存写入加锁 (多会话识别不再互相丢条目)",
    "修复: 本地作业状态文件损坏且 rename 失败时, copy 兜底后删除原件——此前每次 10s 轮询都会再备一份 .corrupt-<ts>, 无上限累积; 序列号自愈计入注册表 local 记录, 状态文件全丢后不再从 1000001 重新发号撞历史作业",
    "改进: 「识别所有未识别镜像」由同步 for 循环改为每拍处理一个镜像的队列——此前单进程 Shiny 的所有会话会冻结 N×75s; 现在镜像之间事件循环可运行, 新增「取消识别」按钮与实时进度, 批量识别单镜像限时 20s",
    "改进: 完成邮件「DIA-NN 版本」显示容器实测值 (--diann-ver, 未识别回退文件名); 月度统计逐作业明细新增「版本」列——兑现 v1.13 changelog (当时仅注册表落了实测值, 措辞已更正)",
    "改进: 全缺失样本列 (零检出) 预处理硬阻断并点名样本, 不再产生 NaN 插补带病进入 limma; 退化数据 (<3 完整蛋白) 报告的 PCA/相关性关键数占位「未生成」; QC 直方图分箱数 (cv_bins) 真正接入直方图并如实标注 (此前是死控件); 移除无功能的「缺失机制诊断图」按钮; impute 包缺失回退行中位数时如实标注; 多基因 ID (\"A;B\") 截断显式告警",
    "测试: ComBat 数值回归 (批次效应去除且组间差异保留); e2e 覆盖 ② 预处理与 ⑤ 功能富集页签 (en-bug 回归守卫); wsl_smoke.sh 修正 (testthat 补装/相对路径/端口可换)"
  )),
  list(ver = "v1.14", date = "2026-10-27", items = c(
    "新增: 「结果分析」页 (下游分析模块, 整合 ProteoDIA Studio)——对 DIA-NN --matrices 导出的蛋白矩阵 (pg_matrix) 做预处理 (污染/反库剔除、低检出过滤、log2、LoD/KNN/seqKNN 插补、样本中位数归一化、可选 ComBat 去批次)、9 张 QC 图 (检出数/缺失率/PCA/相关性热图/层次聚类/CV 分布/CV 箱线/归一化前后/缺失机制诊断)、limma 差异分析 (2 组单对比; ≥3 组全局 F + 全部两两对比)、GO/KEGG 富集与一键 HTML 报告 (report.html + 图形/结果表/analysis_params.json, 浏览器打包 zip 下载)",
    "新增: 独立启动模式 run_app(analysis_only = TRUE)——只加载结果分析页, 不初始化 Slurm/apptainer/SIF; 适合无容器环境或只做矩阵分析的机器",
    "新增: 闭环——任务队列页新增「结果分析入口」: 从提交记录选定已完成作业, 自动发现其输出目录内的 *matrix*.tsv (pg_matrix 优先), 一键带入结果分析页并填好路径",
    "设计: 结果分析依赖全部可选 (ggplot2/limma/clusterProfiler 等放 Suggests + 运行时检查)——不装也能正常提交/监控作业, 进入分析页时给可复制的安装命令; doctor() 新增「结果分析依赖」体检组 (缺包 warn + 安装命令)",
    "设计: KEGG 数据源可切换——默认本地 KEGG.db (与 CLI 版一致; 该包已被 Bioconductor 移除, 缺失时降级为仅 GO 并提示), 可选在线 enrichKEGG (需联网, 支持斑马鱼等更多物种); 报告附录注明所用数据源",
    "设计: 图形预览与报告落盘走同一 svglite 绘制路径 (所见即报告所得); 报告模板资产 (样式/交互脚本/logo) 随包内置于 inst/analysis/assets, 全部为本项目生成",
    "测试: 合成 pg_matrix 夹具 (MNAR 缺失) 矩阵化验证预处理数值/DE 回收/报告目录契约/矩阵发现; doctor 分组契约更新 (结果分析依赖在 Slurm 之前)"
  )),
  list(ver = "v1.13", date = "2026-10-27", items = c(
    "新增: SIF 镜像下拉扫描 SIF_DIRS 下全部 *.sif (文件名无关)——image.sif / diann_latest.sif 等不再不可见；版本不再取自文件名，改为选中镜像后在容器内实测 (apptainer exec <sif> diann-linux --version)，结果按 size+mtime 缓存到 ~/.diann_gui/sif_probe.rds，文件变化自动失效",
    "新增: 「识别所有未识别镜像」按钮 (带进度逐个识别) 与选中未识别镜像自动识别；「识别版本并深度验证」成功后同样写缓存并刷新下拉；启动不跑容器 (HPC 登录节点安全)；版本未识别不阻断提交 (GUI 节点无 apptainer 时提示而不报错)",
    "变更: 已识别镜像按数值版本降序 (2.10.0 在 2.9.1 之前)、未识别排后；默认选中 DEFAULT_SIF → 已识别最高版本 → 首个路径；注册表的版本列为容器实测值 (未识别记\"未识别\"; v1.14.1 起完成邮件与月度统计同步显示实测值)",
    "新增: 提交页/任务队列页常驻模式提示条与标题栏彩色徽标——本地单机 (绿)/Slurm 集群 (蓝)，日志命名、排队语义、并发上限一目了然",
    "新增: 本地并发 LOCAL_MAX_JOBS 达上限时给出预计可提交时间 (按运行中作业时限取最早；全无时限时明示未知)；未达上限的提示也显示预计释放时间",
    "新增: 本地作业状态文件损坏自愈——RDS 解析失败自动备份 .corrupt-<时间戳>、写状态日志、界面黄色告警一次性提示 (含 ps -ef | grep local_runner 指引)；序列文件损坏/落后自愈为 max(jobid)+1 防撞号；doctor() 新增只读检查项",
    "改进: doctor() 按重要性重排分组——[0]执行后端 → [1]R → [2]依赖包 (本地模式含执行原语) → [3]apptainer → [4]SIF 镜像 (含识别状态) → [5]其他环境 → [6]Slurm 依赖 (最后)；输出带组标题/状态符号/汇总；返回表新增 group 列 (check/status/detail 不变)",
    "文档: README 中英新增「构建 DIA-NN 容器镜像 (.sif)」指引章节——只给官方渠道指针 (官方仓库 README 与 release 附带构建脚本、issue #1202), 不提供构建脚本/Dockerfile, 构建完全由用户自行完成；写明本项目对镜像的硬性要求 (容器内 PATH 含 diann-linux、构建后自验 --version、放入 SIF_DIRS 文件名任意)；GUI 不分发 DIA-NN 二进制/镜像，每人自行构建",
    "变更: DIA-NN 参数文档快照不再随包分发 (版权归 DIA-NN 作者、条款不允许再分发)——需要应用内参数速查时自行从官方仓库获取, 存为工作目录下的 DIANN_param_reference.md 即可被 GUI 读取；新手指南新增两张本地模式截图 (图 3-2/3-3)",
    "删除: legacy 中央 shiny-server 共享账号部署——SHARED_GROUP/组修复、LOCAL_ALLOW_SHARED、工作目录 config.R 与 mail_config.txt 回退、docs/legacy 全部移除；历史实现保留在 central-shiny-server 分支；共享读取请用标准 Unix 组/ACL",
    "测试: SIF 扫描/识别/缓存/数值排序矩阵 (含 2.10.0>2.9.1 与默认选中回归)、本地 ETA/损坏恢复、doctor 分组顺序、UI 契约 (banner/新 id) 全部离线可跑"
  )),
  list(ver = "v1.12", date = "2026-10-26", items = c(
    "新增: 执行后端可选——EXEC_BACKEND = auto|slurm|local (默认 auto); 环境变量 DIANN_GUI_EXEC_BACKEND 覆盖。auto 在 PATH 上有 sbatch 时用 Slurm 集群 (与 v1.11 行为一致), 没有则自动在本机执行。",
    "新增: 本地执行模式——在 GUI 所在 Linux 主机直接运行 DIA-NN, 仍用 apptainer/singularity + 同一个 diann*.sif 镜像与同一套命令构建 (与 Slurm 模式共享 job_body); setsid+nohup 派生进程脱离浏览器会话, 关闭页面不影响作业; 本地 JobID 从 1000001 起递增; 日志固定 local-<作业ID>.out/.err; 脚本仍保存到 输出目录/diann_gui_scripts/。",
    "新增: 安全阀——auto 模式检测到 Slurm 痕迹 (squeue/sacct/scontrol/sinfo 或 /etc/slurm) 但 PATH 上没有 sbatch 时, 拒绝静默回退本地执行并给出可操作报错 (LOCAL_REQUIRE_EXCLUSIVE_HOST, 防 HPC 登录节点误跑); legacy 中央 shiny-server 部署 (站点 app.R+config.R 或配置了 SHARED_GROUP) 默认拒绝本地执行, 需显式 LOCAL_ALLOW_SHARED=TRUE。",
    "新增: 本地模式配置 LOCAL_NICE(10) / LOCAL_TIMEOUT_GRACE(30) / LOCAL_MAX_JOBS(0=不限, >0 达上限阻断提交) / LOCAL_MEM_ADVISORY(TRUE, 提交前按 /proc/meminfo 比对仅警告); 原有 SLURM_* 键保留且仅在 Slurm 模式使用。",
    "新增: 本地作业状态/取消/时限——/proc starttime + cmdline 防 PID 复用; 取消 = 落 .cancelled 标记 + 进程组 TERM→(约 5s)→KILL, 仅允许同 UID 取消; 时限由 timeout 强制 (rc=124 映射超时), 内存不可强制、只做建议检查; 无排队 (LOCAL_MAX_JOBS 提供简单并发上限)。",
    "改进: 四层状态合成 / 完成邮件 / 月度统计对两种后端共用同一语义——本地事实合成 RUNNING/PENDING/COMPLETED/FAILED/CANCELLED/TIMEOUT 同名调度终态, 面板与邮件标签一致; watcher 按每条记录的 backend 惰性取状态与日志。",
    "改进: 提交注册表 schema v3 追加 backend/pid 列, 日志列改由唯一日志契约 backend_log_paths() 生成 (slurm-<id>.out / local-<id>.out); 旧 v1/v2 记录按列名补 NA 自动兼容, 缺 backend 按 slurm 解释; 月度统计逐作业新增「后端」列。",
    "改进: UI 按解析到的后端条件渲染——本地模式标题栏显示「执行后端: 本地单机」, 资源盒改「6. 运行资源 (本地)」并隐藏分区, 提交按钮改「提交本地任务」, 监控页隐藏 sinfo 盒、标题改「本地运行任务 / 近期历史 (本地作业)」、日志标题改「运行日志查看 (local-<ID>.out 尾部)」; Slurm 模式界面与 v1.11 基本一致 (现有截图仍有效)。",
    "改进: doctor() / init_config() 分后端——本地模式下 Slurm 命令与分区检查降级为不适用 (na), 改为检查 setsid/nohup/timeout/bash 与 /proc; init_config(auto) 把探测到的后端写回 EXEC_BACKEND, 生成后提示当前执行后端。",
    "修复: 无 Slurm 主机点提交导致 Shiny 会话永久断连且无失败提示 (v1.11 实测: system2('sbatch') 未捕获错误); v1.12 提交路径整体后端化并 tryCatch, 失败转为错误通知, 不再断连。",
    "测试: 新增离线后端测试 (假 apptainer + 假 DIA-NN 负载, 不依赖真实 Slurm/容器/RAW 数据): 后端解析矩阵、日志命名契约、两后端共用脚本程序体、本地提交→成功/失败/超时/取消、PID 复用防护、sbatch 缺失不抛错; CI 在无 Slurm runner 上执行本地提交路径。",
    "文档: README 双语 / 技术手册 / 新手指南同步「Slurm 可选 + 本地单机模式」——架构、配置键、模式差异、日志命名、无 Slurm 排错; 明确本版不做原生二进制/云/Windows/PBS。"
  )),
  list(ver = "v1.11", date = "2026-10-20", items = c(
    "新增: 明确运行时版本要求——SIF 镜像需 apptainer ≥ 1.0 或 singularity ≥ 3.0 (SIF 自 Singularity 3.0 起; 2.x 只能读 squashfs/ext3 的 .simg)。候选下拉/自检面板/当前生效回显/「识别并验证」/快速与深度验证/提交前校验/doctor 统一标注「⚠ 不支持 SIF」; 选中 2.x 时直接给出结论与升级路径, 不再只显示 \"Unknown image format/type\" 裸报错 (同时剥掉 2.x stderr 的 ANSI 颜色码与 \\r 拼接)",
    "改进: 默认 apptainer 优先选「可执行且支持 SIF」的候选——避免下拉默认值是个能跑 --version 却读不了 .sif 的 singularity 2.x",
    "新增: 「1. apptainer 运行环境」面板——自动识别 apptainer/singularity (PATH / APPTAINER_PATHS / 常见安装位置 / conda 环境), 逐个解析版本后像 DIA-NN 版本下拉一样列入候选; 识别不到时自动展开手动路径输入并可「识别并验证」; 选定路径写入作业脚本作为首选, 计算节点不可见时按 APPTAINER_PATHS → PATH → module → singularity 回退",
    "新增: diann.gui::init_config() 在 R 内生成 ~/.diann_gui/config.R (可自动探测 Slurm 分区 / apptainer / SIF 目录); diann.gui::doctor() 一次性自检 R 版本/依赖/Slurm 命令/分区/apptainer/SIF/配置/邮件/状态目录",
    "改进: 交付方式回归 R 包自托管——install.packages() → library(diann.gui) → run_app() 即可, 每用户在自己的库与账号下运行; 删除 bin/diann-gui 启动器与根 app.R, 中央 shiny-server 降为 legacy 文档附录",
    "变更: run_app() 现在直接启动服务并打印访问地址与 SSH 隧道提示 (以前 port=NULL 只返回 app 对象, 依赖控制台 auto-print); 嵌入/legacy 用法改为 run_app(app_only = TRUE)",
    "修复: 提交注册表保留最近 300 条时误用 head(), 满 300 条后新记录被静默丢弃 (月报/日志定位看不到新作业)",
    "修复: 归档遗留产物时把用户报告名拼进正则——报告名含 [ ( 等字符时提交直接报错, 报告名为 \".\" 时会把目录内全部 tsv 批量改名",
    "修复: dir 模式下导入的 RAW 文件被忽略 (生成命令没有任何输入); --dir/--dir-all 命令导入后不再作为未知旗标, 目录写入覆盖层并切换输入方式",
    "修复: 时限只按整小时截断 (1.9h → 1h), 且 <1h 被当成不限时; 现按分钟提交 (-t 114)",
    "修复: SIF 版本按字符串排序, 2.10.0 会排在 2.9.1 之后导致默认镜像选错; 改为数值版本排序",
    "修复: 完成邮件的结果简介硬编码 report.tsv, 自定义报告名时没有识别数; --out-file 现在生效; STARTTLS 失败不再静默降级为明文发送凭据",
    "修复: 月度统计脚本错配——同目录多次提交时把别的作业 .rc 当成当前作业; 注册表 schema v2 记录 script_path/out_file/sif/apptainer/版本, 旧注册表仍可读",
    "修复: 邮件 watcher 把 sacct 记账滞后导致的\"未知\"当成最终结果并置 done; 现在先等最多 3 轮再退化",
    "修复: HOME 不可写时状态文件回退到固定 /tmp 文件名 (多用户互相覆盖/可被预置符号链接); 改为 per-user 目录 (0700)",
    "修复: 任务名未校验 (含 / 时脚本文件名构造失败) 与报告名含 / 导致写到不存在子目录; 均增加提交前校验",
    "改进: 镜像验证拆为「快速」(本地静态检查) 与「深度」(apptainer inspect + 容器内启动, 超时收紧), 减少单进程 Shiny 的阻塞",
    "改进: Slurm 查询收敛——squeue/sacct 合并为一次快照 (20s 缓存), 任务面板/通知面板/watcher 共用, 不再为每条记录各起子进程",
    "新增: SLURM_EXTRA_ARGS (--account/--qos 等额外 #SBATCH 选项)、RETENTION_DAYS 输出目录保留策略、BIND_PATHS 容器可见性提交前警告、可变修饰行数 > --var-mods 的警告",
    "改进: 锁竞争失败时通知记录落 sidecar 目录, 下一轮 watcher 补写, 不再静默丢邮件; 配置发现不再无条件下读取工作目录 config.R (仅 legacy app.R 标记时)"
  )),
  list(ver = "v1.10", date = "2026-10-15", items = c(
    "修复: 含字母 s 的邮箱 (如 ihcams.ac.cn) 被误判格式不正确——R 默认 POSIX 正则引擎不识别字符类内的 \\s, [^@,\\s] 被当作排除字母 s; 校验改用 perl 正则",
    "新增: 「DIA-NN 版本」页镜像浏览选择按钮——自定义镜像可在数据卷内点选, 路径自动回填 (仍可手动输入数据卷之外的路径)",
    "新增: 「验证镜像可用性」按钮——逐项检查 镜像存在/大小 → GUI 身份可读 → SIF 魔数 → apptainer inspect 元数据 → 容器内启动 diann-linux 并回显实际版本 (与文件名版本对照); 提交前校验同步增加可读性与 SIF 魔数拦截",
    "新增: 「运行环境自检」面板——启动时探测 apptainer 可执行 (进程 PATH + config.R 的 APPTAINER_PATHS + module 回退试载) 并显示版本/来源/失效配置项; PATH 上命中的目录自动并入作业脚本候选, 探测失败不阻断提交"
  )),
  list(ver = "v1.9", date = "2026-10-12", items = c(
    "修复: 导入命令时「每肽段最大可变修饰数」被修饰行数覆盖——命令显式给出 --var-mods 时以显式值优先 (此前粘贴含 --var-mods 5 + 2 行修饰的命令, 导入后被写成 2, 集群按 --var-mods 2 重建库致前体数少 12 万); 仅当命令未给出 --var-mods 时才按修饰行数兜底",
    "修复: 导入 Windows GUI 预测库命令不再卡死——路径留空时官方命令导出裸 --lib/--out, 此前被当作未知旗标塞进「额外参数」且「生成谱图库」未勾选, 校验同时报 RAW 缺失与裸旗标缺取值; 现裸 --lib 且无 RAW 文件时自动勾选 --gen-spec-lib, 其余裸路径旗标识别并忽略",
    "修复: 导入本页预览的 Slurm 脚本在 rc=$? 行截断——此前脚本尾部行被继续扫描, 旧格式尾部裸 --out 会把 rc=$? 吞成取值, 使主报告文件名变成 \"rc=$?\"; 并从 #SBATCH -o/-e 回填输出目录 (预测库脚本无 --out 时输出目录不再为空)",
    "改进: 提交前预检输出目录可写性——输出目录对 GUI 运行身份只读 (如 shiny 无 data/ 写权限) 时直接阻断并给出授权建议, 不再等到 sbatch 阶段报「无法创建脚本目录」",
    "重构: 「分析参数」布局对齐 DIA-NN Windows 界面——肽段长度/前体 m/z/前体电荷/碎片 m/z 改为最小-最大成组输入 (留空即默认, 输入框内灰字提示默认值); 全部参数标签改为「中文 (English)」, 命令行旗标移至灰色帮助行"
  )),
  list(ver = "v1.8", date = "2026-10-08", items = c(
    "重构: 作业状态判定升级为四层模型 (Slurm 终态 → 程序退出码 → 产物验证 → 展示合成), 任务队列页与完成邮件显示 成功/失败/待核实/未知 标签及原因",
    "修复: 作业退出码如实透传——删除「report.tsv 非空即视为成功」的静默覆盖 (其本意规避容器卸载 SIGILL 假失败, 现由「待核实」状态显式吸收); 新增 .rc 文件记录程序层退出码, 不再依赖日志解析",
    "修复: 命令导入残留旧参数——导入前重置全部分析参数与修饰行/额外参数/导入路径覆盖 (sif、分区、资源、邮箱等站点设置不受影响); 此前导入命令 A 后再导入 B, A 独有的旗标会静默残留 (曾致 --gen-spec-lib 被意外勾回)",
    "修复: 提交时自动归档输出目录中的遗留 report/矩阵文件 (加 .pre_时间戳 后缀), 防止旧结果掩盖本次运行状态",
    "修复: Slurm 资源面板的 CPUs 输入框为无效摆设 (实际 --cpus-per-task 一直由「常规→线程数」决定), 予以移除并明示; 线程数增加服务器端校验",
    "修复: --out-lib 路径校验恒不生效; 时限填 0/负数时按不限时处理",
    "修复: 命令导入含真实服务器路径时会话断开——diann_core.R 的 source 缺少 local=TRUE, path_in_scope 从全局环境找不到 BASE_VOLUMES (v1.8 重构引入, 2026-10-09 实测复现并修复)",
    "新增: 真实粘贴回归夹具 (39/796 RAW 两份用户命令) + tests/e2e/run_e2e.sh 浏览器端到端验证——每次更新前后必须执行",
    "改进: 可变修饰超过 6 行/固定修饰超过 3 行的导入内容不再静默丢弃, 明确提示行数",
    "重构: 纯函数核心 (命令构建/解析/sbatch 模板/路径守卫) 提取至 diann_core.R, 与测试共用; app.R 由 1764 行减至约 1550 行",
    "新增: testthat 测试套件 (tests/testthat, 87 项断言: 命令解析/脚本模板不变量/四层状态合成/路径守卫/通知记录) + GitHub Actions CI",
    "新增: usage_report.R 月度使用统计——按注册表汇总逐作业状态/耗时/失败明细, 输出 Markdown 报告"
  )),
  list(ver = "v1.7", date = "2026-10-07", items = c(
    "改进: 站点配置外置——新增 config.R (模板见 config.example.R), 数据根目录 / SIF 扫描目录 / Slurm 分区 / apptainer 路径 / 容器绑定目录 / 共享组 / 内置污染物库等全部可配置, 便于跨集群部署",
    "改进: 邮件通知相关脚本路径随应用目录自动推导, 不再依赖绝对路径; 未配置 mail_config.txt 时邮件功能整体停用 (不入队 / 不拉起 watcher)",
    "改进: 共享输出目录修复 (setgid + chgrp) 改由 SHARED_GROUP 配置控制, 留空则完全关闭",
    "改进: 容器 --bind 目录列表化 (BIND_PATHS); apptainer 找不到且未配模块回退时不再生成 module load 行"
  )),
  list(ver = "v1.6", date = "2026-10-06", items = c(
    "修复: 校验警告误伤经验谱库工作流——「光谱库 + --gen-spec-lib + 搜库」是用本次鉴定精修输出谱库 (DIA-NN 推荐流程), 不再按组合模式告警; 组合模式警告仅在无光谱库时触发",
    "修复: 「生成预测库必须提供 FASTA」不再拦截「光谱库 + --gen-spec-lib」模式 (经验谱库无需 FASTA)",
    "改进: 校验信息分三级——✗ 阻断(红) / ⚠ 警告(金) / ℹ 说明(蓝); 污染物 cRAP 编入输出谱库改为说明性提示, 不再建议关闭污染物扣除",
    "新增: 运行日志按 JobID 自动定位——手动目录 → 本会话提交记录 → GUI 持久提交注册表 (新增, 跨会话) → scontrol (运行中/近期作业) → sacct 工作目录; 找不到时提示各来源状态; 日志尾部附带 .err 报错尾部",
    "改进: 默认 sif 版本改为 2.7.0 (Preview Release Channel 2026-09-16)",
    "新增: 版本说明页补充 DIA-NN 2.0 系列官方 Release Notes 原文 (2.3.0–2.7.0, 含已知问题与频道标注)"
  )),
  list(ver = "v1.5", date = "2026-10-03", items = c(
    "重构: 邮件通知由独立守护进程 notify_watch.R 代发 (worker 仅写状态文件), 修复「不打开网页就收不到完成邮件」"
  )),
  list(ver = "v1.4", date = "2026-09-20", items = c(
    "新增: 邮箱通知——提交时可选填写邮箱与项目简介, 作业结束时自动发送含结果简介的邮件 (需 mail_config.txt)",
    "修复: 容器内看不到 /share 导致 FASTA/RAW 全部无法读取——apptainer exec 加 --bind /share (job 17523 根因)",
    "修复: 作业退出码透传 + 主结果文件成功判定, diann 失败不再误报 COMPLETED",
    "修复: 完成邮件耗时恒为 0 秒——作业日志输出 epoch 时间戳, 记账库 Elapsed 兜底, 未知则省略耗时行"
  )),
  list(ver = "v1.3", date = "2026-09-17", items = c(
    "修复: apptainer 调用改为 conda PATH 链 (原 module load apptainer/1.4.5 在集群上不存在)",
    "修复: 转换模式不再使用 --out-dir (规避 DIA-NN 反斜杠拼接产生畸形文件名), .dia 输出到 RAW 文件所在目录",
    "修复: 集群资源表 sinfo 加 --states=all, 省电关机的计算节点也可见",
    "新增: RAW 目录 *.quant 缓存冲突提示; 预测库模式可独立生成 (无需 RAW) 并提示与搜库分步执行",
    "实测: 2.3.1/2.3.2/2.5.1/2.6.1 × 转换/搜库+MBR/FASTA 生成预测库 全部通过 (单细胞测试集)"
  )),
  list(ver = "v1.2", date = "2026-09-16", items = c(
    "新增: 命令导入——粘贴 Windows 端/脚本生成的 DIA-NN 命令自动识别并填充参数",
    "新增: 预设模板 (FASTA 生成预测库 / RAW→DIA 仅转换)",
    "新增: --fasta-search 独立开关 (FASTA 仅用于注释时无需勾选)",
    "新增: Contaminants 污染物扣除 (内置 cRAP 库 + --cont-quant-exclude)",
    "新增: 集群节点资源表 (CPU/内存/负载) 与 RAW 目录 .quant 缓存说明",
    "新增: FASTA搜索/库构建页参数默认值显示 (留空=默认 N)",
    "部署: 上线 shiny-server /diann_gui (以专用运行用户执行)"
  )),
  list(ver = "v1.1", date = "2026-09-15", items = c(
    "新增: 多版本 sif 镜像下拉 (自动扫描 diann*.sif, 支持自定义路径)",
    "新增: 全参数分组控件 80+ 项 (常规/质量与提取/修饰/FASTA搜索/高级/额外参数)",
    "新增: Slurm 脚本实时预览与提交校验; 脚本保存到输出目录 diann_gui_scripts/",
    "新增: 任务队列页 (自动刷新/scancel/作业日志查看); 参数速查页",
    "改进: Slurm 分区/内存/时限可调; 全部路径安全转义"
  )),
  list(ver = "v1.0", date = "2026-02-27", items = c(
    "初版: RAW/光谱库/FASTA 选择 + 线程/MBR/RT-profiling, sif 路径硬编码 2.3.2"
  ))
)

# DIA-NN 版本说明 (实测结论; 未列出的版本显示通用文案)
DIANN_VERSION_NOTES <- list(
  "2.7.0" = "当前 GUI 默认。2026-09-16 Preview 频道新版: 异质性实验/低上样量/InfinDIA 性能改进, 蛋白鉴定数预计小幅提升; 新增 --fwhm (DDA 峰积分控制)。",
  "2.6.1" = "Main Release Channel 当前正式版。实测识别数最高 (单细胞测试集前体 6149/2389/2991), 求稳可选用。",
  "2.5.1" = "算法改进版。实测识别数较 2.3.x 提升约 8%~15%。",
  "2.3.2" = "早期生产主力版本。实测与 2.3.1 结果完全一致。",
  "2.3.1" = "稳定旧版 (2025-12 编译)。实测与 2.3.2 结果完全一致。"
)

# DIA-NN 2.0 系列官方 Release Notes 原文 (2026-10-06 自官方更新页整理; 新的在前)
DIANN_RELEASE_NOTES <- list(
  list(ver = "2.7.0", date = "2026-09-16", channel = "Preview Release Channel", notes = NULL, items = c(
    "Performance improvements, in particular on heterogeneous experiments, low sample amounts and in InfinDIA mode (expect several percent gain in protein numbers)",
    "Greater methods detail displayed for statistical analyses and visualisations",
    "Fixed rare integrity check being triggered by highly sparse MS1 spectra with certain acquisition schemes",
    "Fixed incorrect syntax emitted by GUI Wizard's plexDIA mode",
    "Fixed GUI error when switching to Precursor tab in protein detail view",
    "Imputation auto-triggered for CAMERA pathway analysis with empirical correlations",
    "Protein data completeness filter in pathway analysis",
    "The --fwhm option for better control of peak integration in DDA mode"
  )),
  list(ver = "2.6.1", date = "2026-06-30", channel = "Main Release Channel", notes = NULL, items = c(
    "Minor GUI fixes and interface improvements",
    "Fixed calibration library not being searched fully in some scenarious",
    "Fixed incorrect average MS1 accuracy printed when using --quick-mass-acc",
    "Warn in case of a mismatch between Thermo .raw resolution and set mass accuracies",
    "Minor algorithm improvements"
  )),
  list(ver = "2.6.0", date = "2026-06-10", channel = "Preview Release Channel", notes = NULL, items = c(
    "Major identification performance increase on some DDA data",
    "Major quantification improvement and quantitative quality controls on DDA data",
    "Retention time alignment and mass calibration improvements",
    "Minor improvements to PTM site localisation",
    "Minor improvements to channel-specific scoring in plexDIA",
    "InfinDIA performance improvements on some datasets",
    "Per-isotope MS1 quantity and quality score reporting",
    "More thorough error reporting, in particular when loading raw data",
    "Export statistical analyses and visualisations to HTML with interactive figures",
    "Fixed several issues with the headless/cli mode of the GUI",
    "Fixed incorrect view restoration when navigating back between visualisations in the GUI",
    "Fixed incomplete TSV export in the GUI",
    "QuantUMS quality distribution in QC Dashboard as an LC-MS performance metric",
    "Output matrices now uses 'Global' filters with MBR consistent with user guide recommendations",
    "Improved file open/save dialog",
    "Support for newer .NET runtimes",
    "Fixed PDF report label rendering",
    "Reduced RAM usage spikes in some scenarious"
  )),
  list(ver = "2.5.1", date = "2026-04-30", channel = "Preview Release Channel", notes = NULL, items = c(
    "Ability to add QC metrics as metadata (Experiment Design) in the GUI, to use for filtering and statistical analysis",
    "Minor GUI fixes: removed too strict analysis timeout, fixed plot re-render when navigating back to previous view",
    "Checkbox label font made crisper in the GUI",
    "Matrices are now generted without lib q-value filters when using MBR (as these are no longer recommended)",
    "DIA-NN checks for .NET Runtime instead of SDK for .raw analysis",
    "DIA-NN will aim to detect and report lack of installed VC++ redist"
  )),
  list(ver = "2.5.0", date = "2026-04-12", channel = "Preview Release Channel", notes = NULL, items = c(
    "Major increase in protein numbers: up to 70% for low sample amounts",
    "Enterprise edition: built-in 'Knowledge base' boosts identification performance",
    "New GUI for both Windows and Linux with major improvements while keeping familiar layout",
    "New GUI: advanced statistical analysis and biological interpretation",
    "New GUI: QC and interactive visualisation at all levels: gene sets -> proteins -> precursors & protein sequence map / PTM sites",
    "New GUI: configuration Wizard, acts as a set of interactive tutorials",
    "New GUI: command line mode for (i) running pipelines and (ii) QC, statistics and visualisation",
    "Enterprise edition: empirical quality metric for protein IDs combines LC-MS QC + peptide regulation concordance"
  )),
  list(ver = "2.3.2", date = "2026-01-21", channel = "Main Release Channel", notes = NULL, items = c(
    "Maximum number of distinct variable modifications scored increased to 9",
    "Major InfinDIA performance improvement (fold-change IDs boost) on some PASEF data",
    "More peptides used to train NNs in some scenarious, no performance change on most data, up to 10% improvement on some PASEF data",
    "Fixed 2.3.0/2.3.1 issue with Slice/diagonal-PASEF not recognised as such and thus processed suboptimally",
    "Fixed rare crash when loading .tsv/.csv libraries with NA values in integer columns",
    "Automatically trigger Peptidoforms mode in GUI when checking any of variable modifications"
  )),
  list(ver = "2.3.1", date = "2025-12-05", channel = "Preview Release Channel (Enterprise + Academia)", notes = c(
    "Note: this version does not correctly recognise Slice/diagonal PASEF methods instead processing them as dia-PASEF, resulting in lower IDs, this will be fixed in the next update, use 2.2.0 for these instead."
  ), items = c(
    "Major speed up and/or RAM usage reduction on some large raw data files, in particular some Slice-PASEF data",
    "Added --min-fr-aas option, filtering the library for fragments comprising at least a particular number of residues",
    "Fixed an issue with modification not being localised if the original name gets converted to unimod",
    "Fixed an issue with InfinDIA crashing if database contains invalid amino acid symbols",
    "Fixed incorrect N-terminal modification handling by InfinDIA",
    "Better compatibility with handling files with paths represented in UTF-8",
    "Minimal changes to algorithms",
    "Improved output on runs with low numbers of peptides detectable",
    "Elution profile shape metrics reporting (Enterprise version), to control peak sharpness / tailing",
    "Printing available RAM on startup (Windows)"
  )),
  list(ver = "2.3.0", date = "2025-09-26", channel = "Academia Preview", notes = c(
    "Note: this version does not correctly recognise Slice/diagonal PASEF methods instead processing them as dia-PASEF, resulting in lower IDs, this will be fixed in the next update, use 2.2.0 for these instead.",
    "Note: With 2.3.0 we introduce the Preview release channel. Preview versions incorporate cutting-edge developments and are likely, following feedback from the proteomics community, to either be updated quickly or moved to the general release channel. Each Preview version will at first be released for Academia only, with Enterprise version following shortly or after an update.",
    "Note: version 2.3.0 is compatible with .quant files generated by versions 2.0 - 2.2.0.",
    "Note: always use --no-refine-q when analysing multiplexed (plexDIA) data with this version.",
    "2025-09-27: DIA-NN-2.3.0-Academia-Preview.msi installer repackaged to address GUI scaling issue at FullHD."
  ), items = c(
    "InfinDIA (Infinite search space DIA analysis) ultra-fast module. Search tens of billions of precursors with speed up to 500 million targets / minute on a desktop.",
    "DDA data support (beta-stage). Starting with 2.3.0, DIA-NN is no longer a DIA-only tool.",
    "Slightly improved identification performance and data completeness, in particular on challenging data (e.g. single cell). Part of the gain is due to an experimental module that takes into account protein information when identifying precursors (can be turned off with --no-refine-q), ultimately gaining in protein quantification precision.",
    "Support for time-spaced parallel injections, e.g. SynchroSep-MS and timePlex.",
    "Option to use lightweight deep learning models for ~10x faster predicted library generation (--light-models).",
    "Pipeline format switched to .json (human readable & editable in Notepad), backward compatibility with old .pipeline format.",
    "Improved GUI look and functionality, while maintaining the familiar general layout. GUI now optimised for high-dpi displays (200% scaling in Windows). In the future, we plan to add a configuration 'Wizard' (setup assistant) that guides through configuring DIA-NN optimally, step-by-step, for a specific experiment."
  ))
)
