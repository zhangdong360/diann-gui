# ============================================================
# changelog_data.R — 版本更新说明 (纯数据)
# 环境契约: 由 app.R 以 local=TRUE source 进应用环境 (2026-10-09 事故防线:
# 缺省 source 进 globalenv, app 环境里的引用取不到这些对象)。
# 顺序: 必须在 ui 构造之前。
# ============================================================

# GUI 更新日志 (新的在前)
CHANGELOG <- list(
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
