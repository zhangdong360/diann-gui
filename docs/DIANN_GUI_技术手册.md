# DIA-NN GUI（DIA-NN 控制台）技术手册

| 项目 | 说明 |
|---|---|
| 适用版本 | GUI v1.13（2026-10-26）· DIA-NN 2.3.0–2.7.0（sif 容器镜像） |
| 执行后端 | Slurm 集群 或 本地单机（v1.12 起 Slurm 为可选后端，见 §1.1 / §1.2） |
| 面向读者 | 质谱平台工作人员、数据分析人员、集群管理员 |
| 配套文档 | 《DIANN_GUI_新手指南.html》（图文入门版）；GUI 内「参数速查」「更新说明」页 |
| 文档性质 | 技术参考手册——功能、参数、命令构建规则、工作流与故障排查的完整说明 |

> 新手请先阅读《DIANN_GUI_新手指南.html》，本手册供深入学习与查阅使用。

---

## 目录

1. [概述与运行架构](#1-概述与运行架构)
2. [快速上手](#2-快速上手)
3. [页面与控件详解](#3-页面与控件详解)
4. [命令构建与作业脚本规则](#4-命令构建与作业脚本规则)
5. [标准工作流详解](#5-标准工作流详解)
6. [邮件通知机制](#6-邮件通知机制)
7. [命令导入功能](#7-命令导入功能)
8. [提交校验规则对照表](#8-提交校验规则对照表)
9. [结果文件说明](#9-结果文件说明)
10. [常见问题与故障排查](#10-常见问题与故障排查)
11. [DIA-NN 版本说明](#11-diann-版本说明)
12. [附录：常用命令行参数速览](#12-附录常用命令行参数速览)

---

## 1. 概述与运行架构

DIA-NN GUI（页面标题「DIA-NN 控制台」）是一个部署在 Linux 主机（集群登录节点或单机服务器）上的 Shiny Web 应用，把 DIA-NN 命令行的常用参数做成图形界面，负责「选文件 → 配参数 → 预览命令 → 提交作业 → 监控/收邮件」的完整流程。它本身不执行数据分析，所有计算都在 Apptainer 容器内完成。

v1.12 起执行后端可选（`EXEC_BACKEND`）：默认 `auto` 在 PATH 上有 `sbatch` 时把作业提交到 Slurm 集群（与 v1.11 一致），没有 Slurm 时改为在 GUI 所在主机以本地进程执行（本地单机模式）。两种后端共用同一套命令构建、同一个 `.sif` 镜像，以及同一套四层状态/日志/邮件/月报语义，区别只在「作业由谁执行」。

### 1.1 调用链路

本应用以 **R 包**形式分发：每位用户把 `diann.gui` 装进自己的 R 库，在自己的 R 会话里
`diann.gui::run_app()` 启动。Shiny 进程就是该用户自己的进程，因此提交的作业、写出的
文件都归属于本人——用户之间天然隔离。

```
浏览器
  └─ run_app()（你的 R 会话, 127.0.0.1:<随机端口>）
       └─ 执行后端适配层（EXEC_BACKEND = auto|slurm|local；环境变量 DIANN_GUI_EXEC_BACKEND 覆盖）
            ├─ slurm 后端: 生成作业脚本 + sbatch 提交（以你本人身份）
            │    └─ Slurm 作业（compute 分区）
            │         └─ apptainer/singularity exec --bind ... <diann-x.y.z.sif> diann-linux <参数>
            │              └─ DIA-NN 分析，结果写入你指定的输出目录
            └─ local 后端: 在本机以 setsid+nohup 派生本地运行器（脱离浏览器会话）
                 └─ timeout/nice 包装同一个 job_body（同一个 .sif + 同一套 DIA-NN 命令）
                      └─ DIA-NN 分析，日志 local-<作业ID>.out/.err，结果写入输出目录
```

后端解析由 `detect_exec_backend()`（`R/backend.R`）完成：`auto` 在 PATH 上有 `sbatch`
时用 Slurm，否则用本地；安全阀见 §1.2。无论哪种后端，作业完成后由同一用户会话拉起的
守护进程 `diann.gui::watch_daemon()`（每 60 s）经 `mail_notify.py` 发送完成/失败邮件
（计算节点无出网，邮件由登录节点代发）。

### 1.2 关键配置（`~/.diann_gui/config.R`）

用 `diann.gui::init_config()` 生成（自动探测执行后端并写回 `EXEC_BACKEND`，同时探测
Slurm 分区、apptainer 候选与 SIF 目录），或手动编辑模板 `inst/config/config.example.R`。

| 常量 | 示例 | 说明 |
|---|---|---|
| `SIF_DIRS` | `/share/app/tools/diann` | 递归扫描**全部 `*.sif`（文件名无关，v1.13 起）**，按数值版本排序后生成下拉 |
| `DEFAULT_SIF` | `/share/app/tools/diann/diann-2.7.0.sif` | 默认镜像（不存在时取扫描到的最高版本） |
| `DATA_HOME` / `BASE_VOLUMES` | `~/data` | 文件浏览器根目录，也是导入路径的安全边界 |
| `SLURM_PARTITIONS` | `c("compute")` | 可选计算分区（第一个为默认） |
| `SLURM_EXTRA_ARGS` | `c("--account=lab")` | 额外 `#SBATCH` 选项（v1.11 起） |
| `APPTAINER_PATHS` | `c("/opt/apptainer/bin")` | 扫描 apptainer/singularity 的目录，同时作为作业脚本回退目录 |
| `DEFAULT_APPTAINER` | `/opt/apptainer/bin/apptainer` | apptainer 下拉的默认选中项 |
| `APPTAINER_STRICT_CHECK` | `FALSE` | TRUE = GUI 节点跑不动所选 apptainer 时阻断提交 |
| `APPTAINER_MODULE_FALLBACK` | `apptainer/1.4.5` | 脚本里 PATH 也找不到时的 module 回退 |
| `BIND_PATHS` | `c("/share")` | 绑定进容器的宿主路径（不配则容器内看不到 /share） |
| `CON_FASTA` | `.../cRAP_contaminants.fasta` | 内置 cRAP 污染物库 |
| `RETENTION_DAYS` | `90` | 输出目录脚本/旧归档的保留天数（0=不清理） |
| `EXEC_BACKEND` | `"auto"` | 执行后端：`"auto"` 自动检测 / `"slurm"` / `"local"`；环境变量 `DIANN_GUI_EXEC_BACKEND` 覆盖 |
| `LOCAL_REQUIRE_EXCLUSIVE_HOST` | `TRUE` | auto 安全阀：检测到 Slurm 痕迹但无 `sbatch` 时拒绝回退本地（防 HPC 登录节点误跑） |
| `LOCAL_NICE` | `10` | 本地进程 nice 值 |
| `LOCAL_TIMEOUT_GRACE` | `30` | 本地作业到时限后 SIGTERM→SIGKILL 等待秒数 |
| `LOCAL_MAX_JOBS` | `0` | 本地并发上限：0=不限，>0 达到即阻断提交（不排队） |
| `LOCAL_MEM_ADVISORY` | `TRUE` | 提交前按 `/proc/meminfo` 比对内存（仅警告，本地不可强制） |

配置发现顺序：`DIANN_GUI_CONFIG` 环境变量 → `~/.diann_gui/config.R` →
`<工作目录>/diann_gui_config.R`。**工作目录的 `config.R` 一律不读取**（v1.13 起，
legacy 中央部署删除后彻底移除），避免项目目录里的同名文件劫持配置。

`SLURM_*` 常量仅 slurm 后端使用，`LOCAL_*` 常量仅 local 后端使用；换机器时把
`EXEC_BACKEND` 改回 `"auto"` 即可重新自动检测。`run_app()` 启动时会打印当前执行
后端与判定来源（自动检测/配置指定）。

### 1.3 账号与权限模型

- **默认（推荐）：每用户自托管**。应用运行在你的账号下，Slurm 作业以你本人提交、
  本地模式的进程也以你本人身份运行，产物归你所有；配置、通知状态、注册表、watcher
  都在你自己的 `$HOME`。同事之间不需要共享组或 ACL。
- **（已移除）legacy 中央 shiny-server 部署**：v1.13 起删除——共享 `run_as` 账号
  破坏每用户隔离。历史实现保留在 `central-shiny-server` 分支；确需中央部署请用
  v1.12。共享读取产出用标准 Unix 组/ACL。

---

## 2. 快速上手

一次最小可用的搜库分析（默认参数、经验谱库模式）：

1. **选运行环境**：「1. apptainer 运行环境」默认已自动识别；未识别到时手动填路径并点「识别并验证」。
2. **选版本**：「2. DIA-NN 版本」下拉默认最高版本，一般不用改。
3. **选文件**：「3. 文件与数据库」中选 RAW 文件（可多选）或 RAW 目录；选光谱库（`.speclib` 等）；如无光谱库则改为选 FASTA 并勾选 `--fasta-search`。
4. **设输出**：「4. 输出设置」选输出目录；主报告文件名默认 `report`（自动加 `.tsv`）。
5. **参数**：「5. 分析参数」默认即可（MBR、RT-profiling、peptidoforms、matrices 默认开启）。
6. **资源**：「6. Slurm 资源」默认 16 CPU / 64 GB；大队列按第 5.4 节估算调整。本地模式下该盒标题为「6. 运行资源 (本地)」，无分区选择，内存仅作建议检查。
7. **提交**：「7. 命令预览与提交」中确认校验提示无红色 ✗ 项、预览脚本符合预期，点「提交 Slurm 任务」（本地模式为「提交本地任务」）。可选填邮箱接收完成通知。

提交后：作业脚本保存到 `<输出目录>/diann_gui_scripts/`；Slurm 模式日志为 `<输出目录>/slurm-<JobID>.out/.err`，本地模式为 `<输出目录>/local-<作业ID>.out/.err`；「任务队列」页监控进度、查看日志；填了邮箱则作业结束后自动收到邮件。

---

## 3. 页面与控件详解

左侧边栏四个页面：**提交分析**（主页面）、**任务队列**（监控）、**参数速查**（DIA-NN 全部 196 个命令行参数）、**更新说明**（版本实测结论 + 官方 Release Notes + GUI 更新日志）。

### 3.1 「1. apptainer 运行环境」

| 控件 | 默认 | 说明 |
|---|---|---|
| 候选下拉 `apptainer_version` | 自动识别 | 扫描 PATH、`APPTAINER_PATHS`、`/usr/bin`、`/usr/local/bin`、`/opt/apptainer/bin`、conda 环境；每个候选解析 `--version`，标签形如 `apptainer 1.4.5 · /opt/.../apptainer`；读不了 SIF 的旧版本（singularity 2.x）追加 `⚠ 不支持 SIF`；多版本按版本降序 |
| 重新扫描 `refresh_apptainer` | — | 强制重新探测（绕过 24 h 缓存） |
| 手动指定 `use_custom_apptainer`/`custom_apptainer` | 否 | 识别不到时自动展开；可填文件或目录（目录会尝试 `apptainer`/`singularity`） |
| 识别并验证 `verify_apptainer` | — | 真实执行 `--version`，显示 ✓ 版本或 ✗ 原因 |
| 当前生效 `apptainer_display` | — | 回显最终使用路径与版本 |

- 选定路径写入作业脚本 `APPTAINER_BIN=` 作为首选；计算节点不可见时按
  `APPTAINER_PATHS` → `PATH` → `module load` → `singularity` 回退，日志里会打印
  `DIANN_GUI_APPTAINER <实际使用的二进制>`。
- **版本要求**：SIF 镜像需要 **apptainer ≥ 1.0 或 singularity ≥ 3.0**（SIF 自
  Singularity 3.0 起）。`singularity 2.x`（含 conda-forge 的 2.4.6）能正常执行
  `--version`，但只认 squashfs/ext3 的 `.simg`，对 `.sif` 会报
  `Unknown image format/type` / `ABORT : Retval = 255`。GUI 的候选下拉、自检面板、
  当前生效回显、「识别并验证」、快速/深度验证与提交前校验都会标注
  **⚠ 不支持 SIF** 并给出该版本要求；提交时直接阻断（不受 `APPTAINER_STRICT_CHECK`
  影响，因为 2.x 读 SIF 是必然失败而非节点差异）。
- GUI 节点没有 apptainer（例如本集群登录节点）是正常情况：提交只警告不阻断
  （`APPTAINER_STRICT_CHECK=TRUE` 才阻断）。
- 自检面板同时显示运行身份、配置文件、每个候选的来源/版本、module 回退状态与状态目录。

### 3.2 「2. DIA-NN 版本 (sif 镜像)」

| 控件 | 默认 | 说明 / 对应命令行 |
|---|---|---|
| 版本下拉 `sif_version` | v2.7.0 | 自动扫描 SIF_DIRS 下**全部 `*.sif`（文件名无关）**；已识别选项格式 `v{版本} · {路径}`，未识别为 `未识别 · {路径}` |
| 使用自定义镜像路径 `use_custom_sif`/`custom_sif` | 否 | 勾选后手填 sif 完整路径（仍在 /share 下可用） |
| 版本信息 `sif_version_info` | — | 回显「已识别（缓存）/ 未识别」及上次失败原因 |
| 当前生效镜像 `sif_display` | — | 回显最终使用的 sif 路径（带已识别版本） |
| 识别所有未识别镜像 `sif_identify_all` | — | 逐个在容器内跑 `diann-linux --version`（带进度），结果落缓存 |

**镜像来源/命名/识别（v1.13）**：GUI 不分发 DIA-NN 二进制或镜像——每人用官方
release 自行构建 `.sif`（流程与许可说明见 README「构建 DIA-NN 容器镜像」章节）。
文件名**任意**：版本不来自文件名，而是在切换选择或点「识别所有未识别镜像」后在容器内实测（页面加载不跑容器）（`apptainer/singularity
exec <sif> diann-linux --version`），结果按 size+mtime 缓存到
`~/.diann_gui/sif_probe.rds`（文件变化自动失效；「识别版本并深度验证」成功后同样
写缓存）。启动不跑容器（HPC 登录节点常无 apptainer）；「版本未识别」不阻断提交。
默认选中：`DEFAULT_SIF` 命中优先 → 已识别的最高数值版本 → 首个路径。

本地单机模式的界面实例（含本面板的识别回显）见 `docs/img/local_mode_submit.png`
（提交页）与 `docs/img/local_mode_monitor.png`（任务队列页），新版手指南同图内嵌
（图 3-2/3-3）。页面加载不识别（不跑容器）；切换镜像或点「识别所有未识别镜像」
时才在容器内实测。

### 3.3 「3. 文件与数据库」

| 控件 | 默认 | 说明 / 对应命令行 |
|---|---|---|
| RAW 输入方式 `raw_mode` | 选择文件 | 「选择文件」= 多个 `--f`；「扫描目录」= `--dir-all`（递归扫描子目录） |
| 选择 RAW 文件 `raw_files` | — | 支持 `.raw/.mzML/.dia/.wiff`，可多选 |
| 选择 RAW 目录 `raw_dir_btn` | — | 目录递归扫描；注意 `*.raw.quant` 缓存问题（见 10.2） |
| 选择光谱库 `lib_file` | — | `.speclib/.parquet/.tsv/.msp/.sptxt` → `--lib`；与 FASTA 至少提供一个 |
| 选择 FASTA `fasta_file` | — | 可多选 → 多个 `--fasta`（UniProt proteome 完全支持） |
| 启用污染物扣除 (cRAP) `cont_exclude` | 否 | 勾选后自动附加内置 cRAP FASTA 并加 `--cont-quant-exclude '<tag>'` |
| 排除标签 `cont_tag` | `cRAP-` | 配合上一项；从归一化与定量矩阵中排除 cRAP 蛋白 |
| 选择校准库 `ref_file` | — | 可选，专用校准小谱库 → `--ref` |

### 3.4 「4. 输出设置」

| 控件 | 默认 | 说明 / 对应命令行 |
|---|---|---|
| 选择输出目录 `out_dir` | — | 结果全部写入该目录；Slurm 日志 `-o/-e` 与本地日志 `local-<ID>.out/.err` 也在此目录 |
| 主报告文件名 `report_name` | `report` | → `--out <输出目录>/report.tsv`（自动补 `.tsv`） |
| 选择临时目录 `temp_dir` | — | 可选 → `--temp` |
| 仅执行 RAW→DIA 转换 `convert_only` | 否 | 勾选后忽略全部分析参数，命令仅含文件 + `--convert`（见 5.1） |

### 3.5 「5. 分析参数」（六个子标签）

**预设按钮**：「预设: FASTA 生成预测库」一键勾选 `--fasta-search`、`--predictor`、`--gen-spec-lib`；「预设: RAW 转 DIA (仅转换)」一键勾选「仅执行转换」。预设只切换常用开关组合，其余参数仍可手动调整。

#### 「常规」标签

| 控件 | 默认 | 命令行 |
|---|---|---|
| 线程数 `threads` | 16 | `--threads`（Slurm 模式同时决定 `--cpus-per-task`；本地模式超过本机核数时会警告） |
| 前体 q-value 阈值 `qvalue` | 0.01 | `--qvalue` |
| 日志详细度 `verbose` | 1 | `--verbose`（0–4） |
| MBR 跨 run 匹配 `mbr` | ✔ | `--reanalyse` |
| IDs/RT/IM profiling `rt_prof` | ✔ | `--rt-profiling` |
| peptidoform 置信评分 `peptidoforms` | ✔ | `--peptidoforms` |
| proteoform 置信评分 `proteoforms` | ✘ | `--proteoforms` |
| 输出定量矩阵 `matrices` | ✔ | `--matrices` |
| 每个 run 单独报告 `indiv_reports` | ✘ | `--individual-reports` |
| UniMod:4 固定修饰处理 `unimod4` | ✔ | `--unimod4` |

#### 「质量与提取」标签（全部留空 = DIA-NN 自动，不写入命令行）

| 控件 | 命令行 | 官方说明摘要 |
|---|---|---|
| MS2 质量精度 ppm `mass_acc` | `--mass-acc` | MS2 质量精度（ppm） |
| MS1 质量精度 ppm `mass_acc_ms1` | `--mass-acc-ms1` | MS1 质量精度（ppm） |
| 扫描窗口半径 `window` | `--window` | 理想值≈平均每窗口前体数 |
| 最小峰高 `min_peak` | `--min-peak` | 最小峰高，须 ≥0.01 |
| RT 提取窗口下限(秒) `rt_window` | `--rt-window` | RT 提取窗口下限 |
| IM 提取窗口下限 `im_window` | `--im-window` | IM 提取窗口下限 |
| 定量 q-value `quant_qvalue` | `--quant-qvalue` | 相对定量优先使用的 q-value 阈值 |
| 蛋白定量 q-value `protein_quant_qvalue` | `--protein-quant-qvalue` | 蛋白定量优先 q-value |
| 矩阵过滤 q-value `matrix_qvalue` | `--matrix-qvalue` | 输出矩阵过滤 q-value |

#### 「修饰」标签

| 控件 | 默认 | 命令行 |
|---|---|---|
| 每个肽段最大可变修饰数 `var_mods_max` | 1（0–10） | `--var-mods` |
| N 端甲硫氨酸切除 `met_excision` | ✘ | `--met-excision` |
| 用 FASTA 重注释谱库 `reannotate` | ✘ | `--reannotate` |
| 可变修饰 6 行（名称/质量/位点） | 前 2 行预填 `UniMod:35,15.994915,M`（氧化 M）与 `UniMod:1,42.010565,*n`（蛋白 N 端乙酰） | `--var-mod '名,质量,位点'` |
| 固定修饰 3 行 | 空（如氨基甲甲基化可填 `UniMod:4,57.021464,C`） | `--fixed-mod '名,质量,位点'` |

修饰行整行留空忽略；填了一部分会触发 ✗ 校验。

#### 「FASTA搜索/库构建」标签

| 控件 | 默认 | 命令行 | 说明 |
|---|---|---|---|
| 执行 FASTA 酶切搜索 `fasta_search` | ✘ | `--fasta-search` | 无库（FASTA）分析必勾；仅用 FASTA 注释谱库时不勾 |
| 自定义酶切特异性 `use_cut`/`cut` | ✘ / `K*,R*,!*P` | `--cut` | 标准胰酶 `K*,R*,!*P`；Trypsin/P `K*,R*`；Lys-C `K*,!*P`；非特异 `**` |
| 最大漏切位点数 `missed_cleavages` | 空=默认 1 | `--missed-cleavages` | |
| 最短/最长肽段长度 | 空=7 / 空=30 | `--min-pep-len` / `--max-pep-len` | |
| 最短/最长前体 m/z | 空=300 / 空=1800 | `--min-pr-mz` / `--max-pr-mz` | |
| 最小/最大前体电荷 | 空=1 / 空=4 | `--min-pr-charge` / `--max-pr-charge` | |
| 最小/最大碎片 m/z | 空=200 / 空=1800 | `--min-fr-mz` / `--max-fr-mz` | |
| 深度学习预测谱图/RT/IM `predictor` | ✘ | `--predictor` | 预测库必勾 |
| 轻量预测模型 `light_models` | ✘ | `--light-models` | 预测快约 10 倍 |
| 生成谱图库 `gen_spec_lib` | ✘ | `--gen-spec-lib` | 双语义：无光谱库=FASTA 预测建库；有光谱库=经验谱库精修工作流 |
| 谱库输出路径 `out_lib` | 空=`<输出目录>/library.speclib` | `--out-lib` | 仅勾选 `--gen-spec-lib` 后显示；DIA-NN 实际生成 `library.predicted.speclib`（预测）或同名经验库 |
| 经验谱库 q-value 阈值 `out_lib_qvalue` | 空=默认 0.05 | `--out-lib-qvalue` | 经验库生成的前体 q-value 门槛 |

#### 「高级」标签（均默认 ✘/空）

`--export-quant`（fragment 定量导出）、`--report-decoys`（报告保留 decoy）、`--individual-windows`、`--individual-mass-acc`、`--global-norm`（简单全局归一化替代 RT 依赖归一化）、`--no-rt-norm`、`--no-prot-norm`、`--high-acc`（QuantUMS 最高精度，防 ratio compression）、`--no-skyline`（不生成 .skyline.speclib）、`--no-stats`、`--xic`（提取鉴定前体前后 X 秒色谱图，留空关闭）、`--min-corr`（峰组相关分数下限，留空自动）。

#### 「额外参数」标签

自由文本 `extra_args`，按空格压缩为单行后**原样追加到命令尾部**，用于覆盖 GUI 未提供的参数（如 `--cfg`、`--min-fr 3`、`--loc-factor 40`、`--fwhm` 等）。完整参数见「参数速查」页或本手册附录。

### 3.6 「命令导入」盒

粘贴 DIA-NN 命令（Windows GUI 生成的、本页预览的作业脚本——Slurm 或本地均可），点「解析并填充参数」。详见第 7 节。

### 3.7 「6. Slurm 资源」/「6. 运行资源 (本地)」

同一位置的功能盒按执行后端改名与裁剪（`R/ui.R` 条件渲染）：

**Slurm 模式（标题「6. Slurm 资源」）**

| 控件 | 默认 | 对应 sbatch 指令 |
|---|---|---|
| 任务名称 `job_name` | `DIANN_Task` | `#SBATCH -J` |
| 计算分区 `partition` | `compute` | `#SBATCH -p` |
| 内存 (GB) `mem_gb` | 64 | `#SBATCH --mem` |
| 时限(小时) `time_h` | 空=不限 | `#SBATCH -t <N>:00:00` |

CPU 核数不在本盒设置：Slurm 的 `--cpus-per-task` 与 DIA-NN 的 `--threads` 同源，
由「5. 分析参数 → 常规 → 线程数」决定。

**本地模式（标题「6. 运行资源 (本地)」）**

| 控件 | 默认 | 说明 |
|---|---|---|
| 任务名称 `job_name` | `DIANN_Task` | 显示在本地任务表与完成邮件里 |
| 内存建议 (GB) `mem_gb` | 64 | 仅提示：提交前与 `/proc/meminfo` 可用内存比对，不足只警告（`LOCAL_MEM_ADVISORY`），**不可强制** |
| 超时时限 (小时) `time_h` | 空=不限 | 到点由本地运行器的 `timeout` 强制终止（`rc=124` → 超时） |

本地模式没有分区、没有调度器记账；没有排队机制（`LOCAL_MAX_JOBS` 可做简单并发
上限，达到后直接阻断提交），同时跑多个 DIA-NN 会争抢本机 CPU/内存（线程数超过
本机核数时 GUI 会警告）。v1.13 起：达到并发上限的阻断消息会给出**预计可提交时间**
（按运行中作业的时限取最早；全部未设时限时明示"结束时间未知"），未达上限的提示
也显示预计释放时间。

### 3.8 「7. 命令预览与提交」

盒标题带模式后缀（「(本地执行)」/「(Slurm 提交)」）；提交页与任务队列页顶部各有一条
**常驻模式提示条**（v1.13：`backend_banner` / `backend_banner_monitor`），标题栏有彩色
徽标（本地单机 = 绿 / Slurm 集群 = 蓝），日志命名、排队语义与并发上限一目了然。

| 控件 | 说明 |
|---|---|
| 邮箱通知 `notify_email` | 可选；作业结束自动发邮件；多邮箱英文逗号分隔（格式错误会 ✗ 阻断） |
| 项目简介 `project_desc` | 可选；写入 `<脚本同名>_desc.txt` 随完成邮件发送 |
| 校验区 `validation_msgs` | 实时三级校验（✗ 红色阻断 / ⚠ 金色警告 / ℹ 蓝色说明），全空且无提示时显示「✔ 校验通过, 可提交」 |
| 命令预览 `preview` | 完整作业脚本实时预览：Slurm 模式为「`#SBATCH` 头 + 共享程序体」，本地模式为无 `#SBATCH` 头的本地执行脚本（程序体相同） |
| 提交按钮 `submit_job` | Slurm 模式「提交 Slurm 任务」→ `sbatch`；本地模式「提交本地任务」→ 派生本地进程。成功弹窗分别显示「✔ 提交成功, Slurm JobID: …」/「✔ 提交成功, 本地 JobID: …」 |

本地模式在提交前还会真实校验 apptainer 运行时（`--version`/SIF 能力），失败直接
阻断——因为作业就在本机跑；Slurm 模式仍保留「计算节点专用路径只警告」的策略。

### 3.9 「任务队列」页

区块按后端条件渲染（本地模式无 sinfo 盒）：

| 区块 | Slurm 模式 | 本地模式 |
|---|---|---|
| 集群节点资源 (sinfo) | 各节点 CPU 分配/空闲/总、状态、总/空闲内存、CPU 负载（含省电关机节点） | 不显示 |
| 运行队列 | 「运行队列 (squeue)」本人作业队列，10 秒自动刷新，可手动刷新 | 「本地运行任务」，10 秒自动刷新（读本地作业状态文件） |
| 近期历史 | 「近期历史 (sacct, 最近一天)」，状态中文映射（已完成/运行中/排队中/失败/超时/已取消等） | 「近期历史 (本地作业, 最近 300 条)」，状态同样中文映射 |
| 取消作业 | 输入作业 ID → `scancel`（弹窗二次确认） | 输入作业 ID → 终止本地进程组（弹窗二次确认，先 TERM 后 KILL） |
| 运行日志查看 | `slurm-<ID>.out` 尾部 120 行 + `.err` 尾部 30 行（程序报错通常在 .err）；可手动指定日志目录，否则自动定位（见 10.4） | 标题为「运行日志查看 (local-<ID>.out 尾部)」，读同一命名规则；自动定位链见 10.4 |
| 本会话提交记录 | 本次会话提交的作业（JobID/任务名/版本/输出目录/提交时间/邮箱/后端），及其下方的「邮件通知队列」状态面板（最近 100 条） | 同左（后端列为「本地」） |

### 3.10 「参数速查」「更新说明」页

- **参数速查**：运行时解析 `DIANN参数说明.md`，展示 DIA-NN 全部 196 个命令行参数的官方英文说明，附官方文档链接。
- **更新说明**：① 各 sif 版本实测结论（三种模式全部实测通过）；② DIA-NN 2.0 系列官方 Release Notes 原文（2.3.0–2.7.0）；③ GUI 更新日志。

---

## 4. 命令构建与作业脚本规则

### 4.1 命令组装顺序（`build_diann_chunks`）

```
[输入]  --f <raw>… | --dir-all <dir>
        --lib <speclib>
        --fasta <fa>…            （多选 + 启用污染物时自动附加内置 cRAP FASTA）
        --cont-quant-exclude 'cRAP-'   （仅勾选污染物扣除时）
        --ref <speclib>  --temp <dir>
[常规]  --threads N --verbose N --out <out.tsv> --qvalue X
        --reanalyse --rt-profiling --peptidoforms --proteoforms
        --matrices --individual-reports --unimod4     （按勾选）
[质量与提取]  --mass-acc --mass-acc-ms1 --window --min-peak --rt-window
        --im-window --quant-qvalue --protein-quant-qvalue --matrix-qvalue
        （NA/留空的项不写入命令行 = DIA-NN 自动）
[修饰]  --var-mods N
        --var-mod '名,质量,位点' ×N   --fixed-mod '名,质量,位点' ×N
        --met-excision --reannotate    （按勾选）
[FASTA搜索/库构建]  --fasta-search --cut '…' --missed-cleavages N
        --min-pep-len --max-pep-len --min-pr-mz --max-pr-mz
        --min-pr-charge --max-pr-charge --min-fr-mz --max-fr-mz
        --predictor --light-models --gen-spec-lib --out-lib --out-lib-qvalue
[高级]  --export-quant --report-decoys --individual-windows
        --individual-mass-acc --global-norm --no-rt-norm --no-prot-norm
        --high-acc --no-skyline --no-stats --xic N --min-corr X
[额外参数]  <自由文本，压缩为单行原样追加>
```

要点：

- **留空 = 自动**：「质量与提取」「FASTA搜索/库构建」中标注「留空=默认/自动」的数值控件，留空时不写入对应旗标，保持 DIA-NN 内建自动优化行为。
- **`--gen-spec-lib` 且 `--out-lib` 留空**：自动取 `<输出目录>/library.speclib`。
- **`--gen-spec-lib` 双语义**：不选光谱库 = FASTA 预测建库（可以不选 RAW 独立运行）；选了光谱库 = 经验谱库工作流（以本次鉴定精修输出谱库，DIA-NN 官方推荐做法）。
- 所有路径经 `shQuote` 安全转义；多文件 RAW 生成多个 `--f`。

### 4.2 仅转换模式

勾选「仅执行 RAW→DIA 转换」后命令最小化（忽略全部分析参数）：

```
diann-linux --f 'a.raw' --f 'b.raw' … --convert --threads 16 --verbose 1
# 目录模式: --dir-all '<目录>' --convert --threads 16 --verbose 1
```

**刻意不使用 `--out-dir`**（DIA-NN 存在以反斜杠拼接产生畸形文件名的 bug，v1.3 修复规避），`.dia` 文件保存在 RAW 文件所在目录。

### 4.3 生成的作业脚本（`make_job_script`：Slurm 头 + 共享程序体 / 本地脚本）

```bash
#!/bin/bash
#SBATCH -J <任务名称>
#SBATCH -p <分区>
#SBATCH --nodes=1
#SBATCH --cpus-per-task=<线程数>
#SBATCH --mem=<内存>G
#SBATCH -t <分钟>                 # 小时 × 60 向上取整; 留空则无此行
#SBATCH -o <输出目录>/slurm-%j.out
#SBATCH -e <输出目录>/slurm-%j.err
<SLURM_EXTRA_ARGS 逐行>

# apptainer 运行环境: GUI 选定路径优先, 不可见时回退
APPTAINER_BIN='<所选路径>'
if [ ! -x "$APPTAINER_BIN" ]; then
  for d in '<APPTAINER_PATHS 目录…>'; do
    for n in apptainer singularity; do
      if [ -x "$d/$n" ]; then APPTAINER_BIN="$d/$n"; break 2; fi
    done
  done
fi
if [ ! -x "$APPTAINER_BIN" ]; then
  APPTAINER_BIN=$(command -v apptainer 2>/dev/null || true)
fi
if [ ! -x "$APPTAINER_BIN" ]; then
  source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash 2>/dev/null
  module load apptainer/1.4.5 2>/dev/null
fi
export PATH="$(dirname "${APPTAINER_BIN:-apptainer}"):$PATH"
echo "DIANN_GUI_APPTAINER ${APPTAINER_BIN:-NOT-FOUND}"

echo "DIA-NN analysis start: $(date)"
echo "DIANN_GUI_START_EPOCH $(date +%s)"

"$APPTAINER_BIN" exec --bind /share <sif路径> diann-linux <全部参数(反斜杠续行)>
rc=$?
printf '%s' "$rc" > '<脚本路径>.rc'
echo "DIA-NN analysis done: $(date), exit code: $rc"
echo "DIANN_GUI_END_EPOCH $(date +%s)"

# 如实退出: 成败由 GUI 四层状态合成判定 (Slurm 终态 + 程序退出码 + 产物验证)
exit $rc
```

设计要点：

- **不再有 `final_rc`「报告非空即成功」覆盖**：v1.8 起改用四层状态合成
  （Slurm 终态 → `.rc` 程序退出码 → 产物验证 → 展示标签），容器卸载阶段偶发
  SIGILL 由「待核实」显式吸收，而不是伪造成功。
- 退出码写入 `<脚本>.rc`，watcher 优先读它，日志解析仅作兜底。
- `--bind` 来自 `BIND_PATHS`；GUI 提交前会警告不在 `$HOME` / 当前目录 /
  `BIND_PATHS` 内的输入/输出路径（v1.4 事故类别）。
- 时限按分钟提交：1.9 h → `-t 114`，0.5 h → `-t 30`（旧版会截成 1 h 或变成不限时）。
- 脚本保存到 `<输出目录>/diann_gui_scripts/diann_<时间戳>_<任务名>.sh`；任务名中的
  `/`、`\`、换行会被替换；填写了项目简介时另存 `<同名>_desc.txt`。

**两种后端共用同一段程序体。** `make_job_script(p, backend)` 按后端分派：
`backend = "slurm"` 时生成 `#SBATCH` 头 + `job_body(p, "slurm")`（即
`make_slurm_script`）；`backend = "local"` 时生成 `make_local_script`——去掉
`#SBATCH` 头与 `SLURM_EXTRA_ARGS`，其余 apptainer 回退链、`diann-linux` 参数、
`.rc` 落盘与 `DIANN_GUI_START/END_EPOCH` 标记与 Slurm 版逐字相同。stdout/stderr
重定向、`timeout`、`nice`、pidfile 以及 `.cancelled`/`.timeout` 标记由
`inst/scripts/local_runner.sh` 接管：

```bash
# diann.gui 本地执行脚本 (无 Slurm) — 由 inst/scripts/local_runner.sh 启动
# 程序退出码写入: <脚本路径>.rc; 日志由运行器重定向为 local-<作业ID>.out/.err
# 时限: <N> 分钟 (由运行器 timeout 强制执行)
APPTAINER_BIN='<所选路径>'
...（与 Slurm 模式完全相同的 apptainer 回退链与 job_body）...
echo "DIA-NN analysis start: $(date)"
echo "DIANN_GUI_START_EPOCH $(date +%s)"
"$APPTAINER_BIN" exec --bind /share <sif路径> diann-linux <全部参数>
rc=$?
printf '%s' "$rc" > '<脚本路径>.rc'
echo "DIA-NN analysis done: $(date), exit code: $rc"
echo "DIANN_GUI_END_EPOCH $(date +%s)"
exit $rc
```

本地脚本的头部注释按分钟展示时限（与 Slurm 的 `-t` 同源，1.9 h → 114 分钟），
但实际强制由运行器 `timeout` 完成，`time_h` 留空则不套 `timeout`。

### 4.4 提交流程

Slurm 与本地共用同一入口 `submit_job`，脚本生成后交给后端门面 `backend_submit()`：

1. 校验存在 ✗ 阻断项 → 弹错误通知，拒绝提交。
2. 创建 `<输出目录>/diann_gui_scripts/`；归档上次运行的遗留 report/矩阵文件，
   并按 `RETENTION_DAYS` 清理过期脚本/归档。
3. 按当前后端写入脚本（+ 可选 `_desc.txt`）。
4. **Slurm 后端**：`sbatch` 提交，解析 `Submitted batch job N`；失败信息原样返回
   （不抛错）。
5. **本地后端**（`local_submit()`）：分配持久化整数 JobID（从 `1000001` 起）→ 写
   本地作业记录 → `setsid+nohup` 派生 `local_runner.sh` → 最多等 3 秒拿到 pidfile
   （记录 `/proc` starttime 防 PID 复用）。运行器先写 pidfile，再用 `nice + timeout`
   运行作业体，日志写 `local-<ID>.out/.err`，退出码写 `<脚本>.rc`，结束清理 pidfile。
   状态目录不可写等失败会回滚记录并以错误通知返回，**不会让 Shiny 会话断连**
   （v1.11 无 Slurm 点提交断连事故的回归防护）。
6. 成功：JobID 写入本会话提交记录 + 持久注册表（跨会话，保留 300 条；v1.12
   schema v3 追加 `backend`/`pid` 列）；自动把「任务队列 → 运行日志查看」的作业 ID
   填为新 JobID；若填了邮箱则通知入队（记录含 `backend`）并确保 watcher 存活；
   弹「✔ 提交成功, <后端> JobID: …」。


---

## 5. 标准工作流详解

### 5.1 RAW → DIA 转换

**用途**：把 Thermo `.raw`（也支持 `.wiff/.mzML`）转成 DIA-NN 原生 `.dia` 格式。`.dia` 读取更快，且转换是一次性开销，适合大队列先转换再反复分析。

**操作**：勾选「4. 输出设置 → 仅执行 RAW→DIA 转换 (--convert)」，或点「5. 分析参数 → 预设: RAW 转 DIA (仅转换)」；选 RAW 文件或目录；提交。

**行为**：
- `.dia` 保存在 **RAW 文件所在目录**（不用 `--out-dir`，规避其畸形文件名 bug）。
- 转换比分析快得多，资源需求低（默认 16 线程即可，多文件大批量可加线程）。
- 同一目录后续用 `.dia` 搜库即可；`.raw.quant` 缓存注意见 10.2。

### 5.2 FASTA 生成预测库

**用途**：没有光谱库时，从蛋白序列数据库出发，酶切 + 深度学习预测谱图/RT/IM，生成理论光谱库（`.speclib`），供后续搜库。

**操作**：点「预设: FASTA 生成预测库」（自动勾选 `--fasta-search`、`--predictor`、`--gen-spec-lib`）；**不选 RAW**；选 FASTA；设输出目录；提交。

**关键参数**：
- 酶切：默认 `K*,R*,!*P`（标准胰酶，不切 P 后），漏切 1；改酶切需勾选「自定义酶切特异性」。
- 肽段长度 7–30、前体 m/z 300–1800、电荷 1–4、碎片 m/z 200–1800：一般默认即可，特殊仪器/方法才需要调整。
- `--light-models`：轻量模型，预测速度快约 10 倍，库质量略降；超大队列（几十万蛋白序列）建议勾选。
- `--out-lib` 留空 → `<输出目录>/library.speclib`；DIA-NN 实际生成 `library.predicted.speclib`。
- 启用污染物扣除时 cRAP 会编入预测库（说明性提示，属预期行为——后续搜库时以 `--cont-quant-exclude` 从定量扣除）。

**建议**：预测库与搜库**分两步**执行（GUI 校验会以蓝色 ℹ 提示）：先不选 RAW 独立生成预测库，库可复用、结果更稳；再进入 5.3/5.4 流程。

### 5.3 经验谱库工作流（推荐的标准三步法）

DIA-NN 官方推荐、也是本实验室的标准流程（v1.6 起校验按此分流，不再误报警告）：

```
① FASTA ──(预设: FASTA 生成预测库, 不选 RAW)──▶ 预测库 library.predicted.speclib
② 预测库 + 小队列 RAW ──(勾 --gen-spec-lib, --out-lib 留空)──▶ 搜库 + 经验谱库 library.speclib
③ 经验谱库 + 全部样本 RAW ──(正常搜库)──▶ 全队列定量结果
```

- 第②步即「光谱库 + `--gen-spec-lib` + RAW」合法模式：以预测库搜部分代表性样本，用本次鉴定精修出**经验谱库**（`--out-lib-qvalue` 默认 0.05 控制入库前体质量）。
- 第③步用经验谱库搜全部样本：库更贴近仪器实测，鉴定数与定量质量通常优于纯预测库；经验库可长期复用。
- 若同时选「光谱库 + FASTA」：FASTA 预测前体会并入搜索空间（可扩充库覆盖；内容相同时清除 FASTA 可提速）。

### 5.4 大队列搜库推荐操作

**输入方式**：
- 「扫描目录」模式（`--dir-all`）递归扫描整个目录，大队列首选——不用逐个勾文件，后续往目录里补文件也不影响。
- 「选择文件」模式适合抽样（如第②步的代表性子集）。

**资源估算**（DIA-NN 官方 Troubleshooting 建议）：
- 内存 ≈ **0.5 GB / 百万前体**（库规模决定），大队列 100–200 GB 起步常见；单 run 大文件建议 128 GB。
- 线程数 = Slurm CPUs；node1–node4 每节点 56 逻辑核，单作业 16–32 线程较均衡，过高会与同节点其他作业争抢。
- 可不设时限（默认不限）；保守起见可按预估时长 ×2 设置。

**分批与并行**：GUI 一次提交是一个作业（内含本次所选全部 RAW）。大队列可按批多次提交（如每批 20–50 个 run）：Slurm 模式下多作业在队列中自动排队/并行；本地模式没有排队，先提交的作业直接开始，后续作业会与本机其他任务争抢 CPU/内存（可用 `LOCAL_MAX_JOBS` 限制并发）。也可一整目录一次提交（内存够时 DIA-NN 内部按 run 串行处理）。

**本地单机的额外注意**：本机可用的核数与内存就是上限——GUI 在提交前会提示线程数超过本机核数、申请内存超过当前可用内存；内存不足时 Linux OOM killer 可能直接杀进程，建议按「内存 - 可用余量」保守估算。

**强烈建议**：大队列务必填**邮箱通知**——跑数小时至数天的作业结束后（或失败时）自动收邮件，含退出码、耗时、结果文件清单。

**辅助工具**：「任务队列 → 集群节点资源 (sinfo)」先看各节点空闲内存/CPU 再定资源；「运行队列 (squeue)」监控进度；作业完成后在邮件中核对 `report.tsv` 行数。

---

## 6. 邮件通知机制

### 6.1 架构

```
提交时(填了邮箱)
  ├─ worker 把 {jobid, backend, 邮箱, 任务, 输出目录, 脚本路径, 简介…} 写入状态文件
  │    $HOME/diann_gui_notify_state.rds（mkdir 互斥锁 + 临时文件原子写，保留 100 条）
  └─ worker 确保 nohup Rscript -e 'diann.gui::watch_daemon()' 守护进程存活（pidfile 去重）
       diann.gui::watch_daemon()（登录节点侧, 每 60s, 一次后端快照）
         └─ 按记录 backend 取状态: slurm → squeue/sacct; local → 本地作业状态文件
              └─ 作业结束 → 解析 slurm-<id>.out / local-<id>.out 的退出码与耗时（.rc 优先）
                   └─ python3 mail_notify.py --strict --to <邮箱> --rc N …
                        └─ SMTP 发信（失败重试 3 次: 5/10/15 分钟后）
```

- 计算节点无出网，邮件由 head-node 侧守护进程代发；watcher 脱离浏览器/worker 生命周期，**不打开网页也能收到邮件**（v1.5 重构）。
- v1.12 起状态与日志来源由每条记录的后端决定：日志文件名经唯一契约 `backend_log_paths()` 生成（`slurm-<id>.out` / `local-<id>.out`），同一个通知队列里可以同时有 Slurm 与本地作业；四层状态合成语义不变。
- watcher 空闲 24 小时自动退出；页面打开/提交成功时会自动按 pidfile 对账重拉。
- 「任务队列 → 本会话提交记录」下方实时显示通知队列状态（已处理/等待完成/失败原因）。

### 6.2 邮件内容

主题「【DIA-NN GUI】<任务名> (Job <id>) 分析完成/失败」；正文含：✅/❌ 状态、JobID、退出码、耗时、DIA-NN 版本（取 sif 文件名）、输入文件列表（从提交脚本反提）、项目简介、结果简介（输出目录文件数与总大小、文件清单前 25 项、`report.tsv` 数据行数、matrix 行数）。**结果文件需登录集群在输出目录查看/下载**，邮件不携带附件。

### 6.3 配置（管理员）

`~/.diann_gui/mail_config.txt`（每用户；模板 `inst/config/mail_config.example.txt`）：

```
smtp_host = smtp.126.com
smtp_port = 465
smtp_user = xxx@126.com
smtp_pass = <SMTP 授权码，不是邮箱登录密码>
mail_from = xxx@126.com        # 可选，默认同 smtp_user
```

- 465 端口走 SMTP_SSL；587 走 STARTTLS。
- 建议 `chmod 600`（文件里是 SMTP 凭据）；**必须使用 SMTP 授权码**，切勿填邮箱主密码。
- STARTTLS 失败会直接报错，不会回退明文发送凭据（v1.11 起）。
- 自测：`python3 mail_notify.py --check`（只测 SMTP 连通）；`--self-test`（发测试邮件）；`Rscript -e 'diann.gui::watch_daemon(once = TRUE)'`（手动补发一轮）。
- 缺少 `mail_config.txt` 时 GUI 会以金色 ⚠ 提示「已填写邮箱, 但未找到邮件配置」，作业照常提交只是不发邮件。

---

## 7. 命令导入功能

「命令导入」盒把现成的 DIA-NN 命令行反向解析回 GUI 控件，便于把 Windows 端 GUI/Wizard 生成的命令搬到集群执行。

**识别能力**：
- 识别 `diann-linux` / `diann.exe` / `diann` 起始的命令；支持反斜杠续行与引号分词。
- 布尔旗标（24 个：`--reanalyse`、`--rt-profiling`、`--matrices`、`--predictor`、`--gen-spec-lib`、`--fasta-search`、`--convert` 等）→ 对应复选框。
- 数值旗标（25 个：`--qvalue`、`--threads`、`--mass-acc`、`--cut` 以外的全部数值参数等）→ 数值输入框。
- 文本旗标 `--cut` / `--out-lib` / `--cont-quant-exclude` → 文本框。
- `--var-mod`/`--fixed-mod` → 修饰行；`--f`/`--fasta`/`--lib`/`--ref`/`--temp`/`--out`/`--out-dir` → 文件路径（勾选相应「覆盖 ×××（用导入路径）」后生效）。
- `--dir` / `--dir-all` → RAW 目录覆盖层，并自动把「RAW 输入方式」切到目录模式（v1.11 起；此前会作为未知旗标导致无法提交）。
- 内置 cRAP FASTA 路径自动转为「启用污染物扣除」开关；未知旗标自动收进「额外参数」。

**自动保护**：
- Windows 路径（`C:\` 或含 `\`）的取值被识别并**丢弃**（记录在导入结果里），不会污染服务器路径。
- `--out-lib` 为 Windows 盘符路径会在提交校验时 ✗ 拦截。

**已知陷阱（务必了解）**：
1. **导入只置 TRUE、从不清除布尔旗标**：粘贴的命令里出现的每个布尔旗标都会被勾上；若之后在同页面上改做别的分析（例如拿旧建库命令导入后改为普通搜库），`--gen-spec-lib` 等开关会**静默保持勾选**。导入后请逐标签检查开关状态。
2. `--fasta-search` 与 `--gen-spec-lib` 是两个独立开关，前者并不 gate 后者。
3. 导入不改动「6. Slurm 资源 / 运行资源 (本地)」（任务名/分区/内存等仍需自行确认）。

---

## 8. 提交校验规则对照表

校验实时显示在「7. 命令预览与提交」中，三级分流：

### ✗ 阻断（红色，必须解决才能提交）

| 触发条件 | 提示 |
|---|---|
| 未选 sif / sif 不存在 | ✗ 未选择 sif 镜像 / ✗ sif 镜像不存在: … |
| sif 不可读 / 魔数校验失败 | ✗ GUI 运行身份无权读取该镜像 / ✗ 该文件不是有效的 SIF 镜像 … |
| 未选择 apptainer（未自动识别到且未手填） | ✗ 未选择 apptainer 运行环境 (未自动识别到, 请手动指定路径) |
| apptainer 路径非绝对 | ✗ apptainer 路径必须是服务器绝对路径 (以 / 开头) |
| 任务名为空 / 含 `/`、`\`、换行 / 超 64 字符 | ✗ 任务名不能为空 / 不能包含 … / 长度不能超过 64 |
| 线程数不在 1–1024 | ✗ 线程数无效 … |
| 输出目录对当前身份不可写 | ✗ 输出目录对 GUI 运行身份不可写 … |
| 主报告文件名含 `/` | ✗ 主报告文件名不能包含 / … |
| 时限 < 1 分钟 | ✗ 时限至少 1 分钟 |
| 无 RAW（且未勾 `--gen-spec-lib` 独立建库） | ✗ 未选择 RAW 文件/目录 |
| 未选输出目录 | ✗ 未选择输出目录 |
| 邮箱格式错误 | ✗ 邮箱通知格式不正确 (多个邮箱用英文逗号分隔) |
| 非转换模式下主报告文件名为空 | ✗ 主报告文件名不能为空 |
| 无光谱库且无 FASTA | ✗ 光谱库与 FASTA 至少需提供一个 |
| 无光谱库且未勾 `--fasta-search`/`--gen-spec-lib` | ✗ 无光谱库时必须勾选 --fasta-search (无库搜索) 或 --gen-spec-lib (生成预测库) |
| 勾了 `--gen-spec-lib` 但既无 FASTA 也无光谱库 | ✗ 生成预测库必须提供 FASTA (或选择光谱库以生成经验谱库) |
| 启用污染物扣除但内置 cRAP FASTA 丢失 | ✗ 污染物 FASTA 不存在: … |
| 可变/固定修饰行填了一部分 | ✗ 可变修饰行不完整: … (需 名称,质量,位点) |
| `--out-lib` 为 Windows 盘符路径 | ✗ --out-lib 是 Windows 盘符路径 (如 I:\…), 服务器上不可用, 请清空或改为服务器路径 |
| 「额外参数」含缺取值的文件类旗标 | ✗ 额外参数中 --f/--fasta/… 缺少取值 (通常是命令导入时 Windows 路径被丢弃残留), 请清理「额外参数」 |
| 本地并发已达 `LOCAL_MAX_JOBS` 上限 | ✗ 本地并发已达上限 LOCAL_MAX_JOBS=N; 请等当前本地作业结束后再提交 |

### ⚠ 警告（金色，可提交但请注意）

| 触发条件 | 提示 |
|---|---|
| 勾选了仅转换模式 | ℹ 转换模式: 命令仅包含文件与 --convert, .dia 文件将保存在 RAW 文件所在目录 |
| FASTA 预测建库 + RAW 同场执行（无光谱库的组合模式） | ℹ FASTA 预测建库与搜库将同场执行 (组合模式); DIA-NN 建议先不选 RAW 独立生成预测库, 再用该库搜库 (库可复用, 结果更稳) |
| 填了邮箱但缺 `~/.diann_gui/mail_config.txt` | ⚠ 已填写邮箱, 但未找到邮件配置 …, 将不会发送通知邮件 |
| GUI 节点看不到/跑不动所选 apptainer | ⚠ GUI 节点看不到该 apptainer … / ⚠ apptainer 不可执行 …（`APPTAINER_STRICT_CHECK=TRUE` 时升级为 ✗） |
| 输入/输出路径不在 `$HOME`/当前目录/`BIND_PATHS` 内 | ⚠ 以下路径不在 … 容器里可能看不到（历史 v1.4 事故类别） |
| 可变修饰行数 > `--var-mods` | ⚠ 可变修饰填了 N 行, 但每肽段最大可变修饰数为 M … |
| 镜像文件 < 1 MB | ⚠ 镜像仅 … MB, 可疑 |
| 本地模式线程数超过本机 CPU 核数 | ⚠ 线程数 N 超过本机 CPU 核数 M; 本地模式没有排队机制, 可能拖慢整机 |
| 本地模式申请内存超过本机当前可用 | ⚠ 申请内存 N GB 超过本机当前可用 M GB; 本地模式只做建议检查, 不会强制限制 |

### ℹ 说明（蓝色，信息提示）

| 触发条件 | 提示 |
|---|---|
| 光谱库 + `--gen-spec-lib` + RAW（经验谱库工作流） | ℹ 经验谱库工作流: 以光谱库搜库, 并用本次鉴定精修输出谱库 (--out-lib); 该库可用于全部样本的后续搜索 |
| 启用污染物扣除且生成谱库 | ℹ 污染物 cRAP 将编入输出谱库, 便于后续搜库时鉴定并经 --cont-quant-exclude 从定量矩阵扣除 |
| 同时选光谱库与 FASTA | ℹ 已同时选择光谱库与 FASTA: FASTA 预测前体将并入搜索空间 (可扩充库覆盖; 若 FASTA 与库内容相同则为重复预测, 清除 FASTA 可提速) |
| 设置了时限（Slurm 模式） | ℹ 时限按 N 分钟提交 (Slurm -t N) |
| 设置了时限（本地模式） | ℹ 时限按 N 分钟执行 (本地模式到点由运行器终止) |
| 本地模式已有作业在运行 | ℹ 当前已有 N 个本地作业在运行; 单机同时跑多个 DIA-NN 会争抢 CPU/内存 |
| 填了 `--out-lib` 但未勾选「生成谱图库」 | ℹ 未勾选「生成谱图库」, --out-lib 不会写入命令 (填写值已忽略) |
| 选中 `singularity` 可执行文件 | ℹ 当前使用 singularity 命令 (与 apptainer 等价) |
| 可选镜像版本与文件名不一致（深度验证） | ℹ 容器内 DIA-NN 实际版本 … 注意: 文件名版本为 … |

> 全部为空时显示「✔ 校验通过, 可提交」。注意 ⚠/ℹ 项也可能出现在「✔ 校验通过」旁边，提交前请读完。

---

## 9. 结果文件说明

全部结果写入用户所选**输出目录**（GUI 无下载按钮，登录集群查看/下载）：

| 文件 | 来源 | 说明 |
|---|---|---|
| `report.tsv`（名称可改） | `--out` | 主报告（TSV 格式）：前体级别鉴定与定量，含 Run、Precursor.Id、Modified.Sequence、Protein.Group、Q.Value、RT、IM 等列（列含义见 GUI「参数速查」页 Main output reference 一节） |
| `report*_matrix*.csv/tsv` | `--matrices` | 蛋白/前体定量矩阵（默认开启） |
| `library.speclib` / `library.predicted.speclib` | `--gen-spec-lib --out-lib` | 生成的谱库（预测库/经验库） |
| `*.skyline.speclib` | 默认 | 供 Skyline 使用的谱库（`--no-skyline` 关闭） |
| `report.stats.tsv` 等 | 默认 | 统计文件（`--no-stats` 关闭） |
| `slurm-<JobID>.out / .err` | Slurm | Slurm 模式的 stdout / stderr 日志；**程序报错通常在 .err** |
| `local-<作业ID>.out / .err` | 本地运行器 | 本地模式的 stdout / stderr 日志；同样**先看 .err** |
| `diann_gui_scripts/diann_*.sh`、`*_desc.txt`、`*.rc` | GUI | 提交脚本、项目简介与程序退出码；本地模式的 `.cancelled`/`.timeout` 标记也在该目录 |
| `<RAW 同目录>/*.dia` | `--convert` | 转换产物（仅转换模式） |
| `<RAW 同目录>/*.raw.quant` | DIA-NN | RAW 分析缓存（注意 10.2） |

---

## 10. 常见问题与故障排查

### 10.1 作业显示 COMPLETED 但没有结果 / 疑似失败

- **先看 `.err` 再看 `.out`**：作业脚本没有 `set -e`，DIA-NN 秒退（如参数错误）时作业状态仍可能 COMPLETED；真实报错几乎总在 `slurm-<JobID>.err`（本地模式为 `local-<ID>.err`）。GUI「运行日志查看」已附带 .err 尾部 30 行。
- 反之，DIA-NN 实际成功但 apptainer 容器卸载阶段偶发 `Illegal instruction (core dumped)` 会造成**假失败**——v1.8 起由四层状态合成判为「待核实」（主报告为本次新写 + 退出码 ∈ {132,134,139}），不再伪造成功；看到「待核实」但 report.tsv 已生成且非空，通常结果可用。

### 10.2 library size mismatch / 混用版本后报错

DIA-NN 会在 RAW 目录生成 `*.raw.quant` 缓存并自动复用。同一目录的文件混用不同谱库/不同 DIA-NN 版本分析时可能报 `library size mismatch`——**删除对应 `*.raw.quant` 缓存文件后重跑**。

### 10.3 Cannot load FASTA / 容器内看不到文件

历史上（GUI v1.4 前）rootless apptainer 不绑定 /share，容器内看不到输入文件。现版本脚本按 `BIND_PATHS` 生成 `--bind`（例如 `BIND_PATHS <- c("/share")`）。若再次出现类似报错：确认提交脚本中的 `--bind` 与数据实际位置一致；GUI 会在提交前警告不在 `$HOME`/当前目录/`BIND_PATHS` 内的路径。

### 10.4 日志文件找不到（运行日志查看显示"未能自动定位"）

GUI 按链自动定位日志：Slurm 模式找 `slurm-<ID>.out`，本地模式找 `local-<ID>.out`
（文件名由 `backend_log_paths()` 按记录的后端生成）：

```
手动指定目录 → 本会话提交记录 → GUI 持久提交注册表（跨会话）
  → 本地作业记录（local 后端；注册表滚动淘汰时兜底）
  → [仅 Slurm] scontrol show job 的 StdOut=（运行中/排队中/刚结束的作业）→ sacct 工作目录
```

早已结束且**不是**本 GUI 提交的作业，Slurm 20.11 记账库不保存日志路径，只能手动指定日志目录。本 GUI 提交的作业永久记录在注册表（保留 300 条），一般都能自动找到。

### 10.5 没收到完成邮件

1. 「任务队列 → 本会话提交记录」下方通知队列面板：显示「等待完成…」= watcher 还没检测到离队（60s 轮询一次）；显示「已处理」= 已发送；显示失败原因 = 发送失败（重试至多 3 次，间隔 5/10/15 分钟）。
2. 检查邮箱地址拼写；多个邮箱用英文逗号。
3. 自测：`python3 mail_notify.py --check`（连通性）、`--self-test`（发测试邮件）、`Rscript -e 'diann.gui::watch_daemon(once = TRUE)'`（手动补发一轮）。
4. 提交时未填邮箱自然没有邮件（通知按作业记录，不支持事后补填——可让管理员用 `--once` 对指定记录补发）。

### 10.6 提交后立刻失败 / 参数报错

- 查看预览脚本（提交前就有）与 `.err` 日志。
- 「额外参数」中的裸旗标（如 `--f` 后没有取值）会让 DIA-NN 直接退出——多为命令导入残留，校验会 ✗ 提示。
- 版本行为差异见第 11 节；改用其他 sif 版本对比是快速定位手段。

### 10.7 apptainer 识别不到 / 版本不对

1. 先看「1. apptainer 运行环境 → 运行环境自检」：列出每个候选的来源、版本与 module 回退状态。
2. 登录节点没有 apptainer 是常见且可接受的：手动填写计算节点可见的路径（如
   `/opt/apptainer/bin/apptainer`），提交只警告不阻断；作业脚本里会打印
   `DIANN_GUI_APPTAINER` 实际使用的二进制。
3. 版本不对：`DEFAULT_APPTAINER` 指定固定路径，或把 `APPTAINER_PATHS` 指到目标目录后点「重新扫描」。
4. 「深度验证」报 `Unknown image format/type`：运行时的主版本不够——SIF 需要
   `apptainer ≥ 1.0` / `singularity ≥ 3.0`；2.x 只能读 `.simg`。改选 ≥3.0 的
   apptainer/singularity 路径（或升级该 conda 环境），再点「重新扫描」。
5. `apptainer --version` 能跑但容器起不来：用「深度验证」看 `inspect`/容器内启动的具体报错；
   也可在登录节点直接 `apptainer exec <sif> diann-linux --version` 复现。

### 10.8 无 Slurm 主机：单机模式（本地执行）

1. **`run_app()` 启动报错「检测到 Slurm 痕迹……但 PATH 上没有 sbatch」**：这是
   `auto` 的安全阀（`LOCAL_REQUIRE_EXCLUSIVE_HOST=TRUE`）——本机像 HPC 登录节点，
   应用拒绝静默本地跑计算任务。先加载 Slurm 模块/修正 `PATH` 后重启（推荐）；
   确认本机是真正的单机服务器后，在 config.R 设 `EXEC_BACKEND <- "local"`，或
   启动前 `export DIANN_GUI_EXEC_BACKEND=local`。
2. **怎么确认当前是哪个后端**：标题栏显示「执行后端: Slurm 集群」或「执行后端:
   本地单机」；`run_app()` 启动时打印 `执行后端: … (自动检测/配置指定)`；
   `doctor()` 第一行给出同样的结论。
3. **本地模式提交被拦：apptainer 未能验证**：本地作业在 GUI 主机上跑，所以
   apptainer 必须真的可用——提交前会做真实校验并阻断（不像 Slurm 模式允许
   计算节点专用路径）。到「1. apptainer 运行环境」选一个可执行的
   apptainer/singularity 并「识别并验证」，或改用 Slurm 集群。
4. **本地日志在哪**：`<输出目录>/local-<作业ID>.out/.err`（不是 `slurm-`），
   脚本/`.rc`/`_desc.txt` 在 `<输出目录>/diann_gui_scripts/`；本地作业 ID 从
   `1000001` 起。日志查看器按记录的后端自动选文件名。
5. **本地作业显示「超时」**：时限由 `timeout` 强制（`rc=124`）；`time_h` 太小时
   作业会在到点被杀。留空 = 不限，或调大；`LOCAL_TIMEOUT_GRACE` 控制 TERM→KILL
   的等待秒数。
6. **内存/并发**：本地模式内存只做建议检查（提交前比对 `/proc/meminfo`，仅警告），
   不做强制；没有排队机制，可用 `LOCAL_MAX_JOBS` 限制同时运行的本地作业数。
7. **同事读不了你的输出目录**：自托管产物属你本人；请用标准 Unix 组/ACL 授权
   （`chmod -R g+rX` 或 `setfacl`）——v1.13 起 GUI 不再代做组修复。

### 10.9 镜像构建 / 容器内无 diann-linux / 计算节点无 apptainer / 版本未识别

- **怎么构建 .sif**：按 DIA-NN 官方说明自行构建（官方仓库 README 与 release
  附带的构建脚本、issue #1202 社区 Dockerfile 讨论——本项目不提供构建脚本/
  Dockerfile）；构建后放入 SIF_DIRS（文件名任意），GUI 会自动识别版本。
- **识别报「容器内找不到 diann-linux」**：镜像没把 DIA-NN 二进制目录加进容器内
  `PATH`——重新构建镜像，把二进制目录加入 PATH。
- **计算节点看不到 apptainer**：作业脚本自带回退链 `APPTAINER_PATHS` → `PATH` →
  `module load` → `singularity`；把计算节点可见的运行时路径配进 `APPTAINER_PATHS`。
- **版本未识别（不影响提交）**：GUI 节点没有可用 apptainer 时无法在容器内实测
  版本；在「1. apptainer 运行环境」选好运行时后点「识别所有未识别镜像」，或换到
  有运行时的节点再识别。Slurm 计算节点能跑容器时作业不受影响。

### 10.10 每用户自托管：装包 / 运行 / 端口

1. 装包：`install.packages("diann.gui", repos = c(SITE = "<站点仓库>", getOption("repos")))`，
   无外网时 `install.packages("/path/diann.gui_1.13.0.tar.gz", repos = NULL, type = "source")`。
2. 自检：`diann.gui::doctor()` 一次列出缺依赖/执行后端与当前模式要求的命令（Slurm 命令或本地原语 setsid/nohup/timeout/bash 与 /proc）/找不到 apptainer/SIF_DIRS 未配/状态目录不可写；不适用项标记为 `na`。
3. 启动：`diann.gui::run_app()`（自动选空闲端口并打印 URL/隧道命令）；固定端口 `run_app(port = 3838)`。
4. 端口被占用：`run_app()` 会自动换端口；也可显式指定。
5. 找不到包（watcher 子进程）：watcher 启动命令显式传入当前 `.libPaths()` 与配置文件（v1.11 起）；
   仍有问题先跑 `doctor()`。

### 10.11 其他

- **分区选择（仅 Slurm 模式）**：`compute` 为主计算分区；`head-node` 仅用于小测试（与管理服务混部，勿跑大作业）。本地模式没有分区。
- **取消作业**：「任务队列 → 取消作业」输入 JobID 确认即取消：Slurm 模式 `scancel`，本地模式终止本地进程组（先 TERM、约 5 秒后 KILL）；排队中与运行中的作业都可取消。
- **时间戳/时限**：Slurm 模式 `#SBATCH -t` 留空为不限时，超时作业被 Slurm 杀掉（sacct 状态「超时」）；本地模式时限由运行器 `timeout` 强制，到点同样记为「超时」。

---

## 11. DIA-NN 版本说明

以下版本均已在集群以三种模式（RAW→DIA 转换 / 搜库+MBR+污染物扣除 / FASTA 生成预测库）实测通过（详见 GUI「更新说明」页）：

| 版本 | 渠道 | 实测结论 / 要点 |
|---|---|---|
| **2.7.0**（默认） | Preview（2026-09-16） | 当前 GUI 默认。异质性实验/低上样量/InfinDIA 性能改进，蛋白鉴定数预计小幅提升；新增 `--fwhm`（DDA 峰积分控制） |
| **2.6.1** | Main（2026-06-30） | **实测识别数最高**（单细胞测试集前体 6149/2389/2991），求稳可选用 |
| 2.5.1 | Preview（2026-04-30） | 实测识别数较 2.3.x 提升约 8%–15% |
| 2.3.2 | Main（2026-01-21） | 早期生产主力；与 2.3.1 结果完全一致 |
| 2.3.1 | Preview（2025-12-05） | 稳定旧版；与 2.3.2 结果完全一致 |

版本选择建议：默认 2.7.0；追求最高鉴定数用 2.6.1；复现历史结果用当初的版本。切换只需在「2. DIA-NN 版本」下拉中选择（或自定义 sif 路径）。

> 注意 2.3.0/2.3.1 不识别 Slice/diagonal PASEF（按 dia-PASEF 处理导致鉴定数偏低，2.3.2 修复）；timsTOF Slice 数据请用 ≥2.3.2。

---

## 12. 附录：常用命令行参数速览

以下为 GUI 直接覆盖或高频使用的参数中文速查（完整 196 项见 GUI「参数速查」页）。

### 输入与输出

| 参数 | 说明 |
|---|---|
| `--f <file>` | 指定一个待分析的 run；多个 run 用多个 `--f` |
| `--dir <folder>` | 指定包含原始文件的目录（`.raw/.wiff/.mzML/.dia`） |
| `--dir-all <folder>` | 同 `--dir`，但**递归**扫描子目录 |
| `--lib <file>` | 光谱库（可多 `--lib` 加载多个库，实验性） |
| `--fasta <file>` | 蛋白序列数据库（可多 `--fasta`；UniProt proteome 完全支持） |
| `--ref <file>` | 专用于校准的小型谱库 |
| `--out <file>` | 主报告文件名，其余输出文件名由它派生 |
| `--out-dir <folder>` | RAW→DIA 转换的输出目录（GUI 转换模式刻意不用） |
| `--temp <folder>` | 临时目录 |
| `--convert` | 把质谱文件转换为 .dia 格式（保存在原位置或 `--out-dir`） |

### 常规搜索

| 参数 | 说明 |
|---|---|
| `--threads [N]` | CPU 线程数 |
| `--verbose [N]` | 日志详细度（0–4） |
| `--qvalue [X]` | 主报告前体级 q-value 阈值（默认 0.01） |
| `--reanalyse` | 开启 MBR（match-between-runs） |
| `--rt-profiling` | 经验库生成模式：IDs/RT/IM profiling |
| `--peptidoforms` | peptidoform 置信评分 |
| `--proteoforms` | proteoform 置信评分 |
| `--matrices` | 输出定量矩阵 |
| `--individual-reports` | 每个 run 单独输出报告 |
| `--unimod4` | UniMod:4（半胱氨酸烷基化）固定修饰处理 |
| `--cfg <file>` | 从文件加载参数/命令 |

### 校准与提取

| 参数 | 说明 |
|---|---|
| `--mass-acc [N]` | MS2 质量精度（ppm），默认自动优化 |
| `--mass-acc-ms1 [N]` | MS1 质量精度（ppm） |
| `--window [N]` | 扫描窗口半径（理想值≈平均每窗口前体数） |
| `--min-peak [X]` | 最小峰高（≥0.01） |
| `--rt-window [X]` | RT 提取窗口下限（秒） |
| `--im-window [X]` | IM 提取窗口下限 |
| `--cal [N]` | 校准模式 0/1/3/5/7，默认 7 |
| `--individual-windows` / `--individual-mass-acc` | 各 run 独立确定窗口 / 质量精度 |

### 修饰

| 参数 | 说明 |
|---|---|
| `--var-mods [N]` | 每肽段最大可变修饰数 |
| `--var-mod <名,质量,位点>` | 声明并启用一个可变修饰（如 `UniMod:35,15.994915,M`） |
| `--fixed-mod <名,质量,位点>` | 声明并启用一个固定修饰（如 `UniMod:4,57.021464,C`） |
| `--met-excision` | 蛋白 N 端甲硫氨酸切除作为可变修饰 |
| `--reannotate` | 用 FASTA 按指定酶切规则重注释光谱库 |
| `--cut <特异性>` | 理论酶切特异性（如 `K*,R*,!*P`） |
| `--missed-cleavages [N]` | 最大漏切位点数（默认 1） |

### FASTA 搜索与谱库生成

| 参数 | 说明 |
|---|---|
| `--fasta-search` | 对序列数据库执行理论酶切（无库搜索/建库前提） |
| `--min-pep-len / --max-pep-len [N]` | 肽段长度范围（默认 7/30） |
| `--min-pr-mz / --max-pr-mz [N]` | 前体 m/z 范围（默认 300/1800） |
| `--min-pr-charge / --max-pr-charge [N]` | 前体电荷范围（默认 1/4） |
| `--min-fr-mz / --max-fr-mz [N]` | 碎片 m/z 范围（默认 200/1800） |
| `--predictor` | 深度学习预测谱图/RT/IM |
| `--light-models` | 内置轻量模型，预测快约 10 倍 |
| `--gen-spec-lib` | 生成光谱库（预测库或经验库） |
| `--out-lib <file>` | 输出谱库文件名 |
| `--out-lib-qvalue [X]` | 经验库生成的前体 q-value 门槛（默认 0.05） |
| `--no-skyline` | 不生成 .skyline.speclib |
| `--min-fr [N]` | 保存谱库时每前体最少碎片数 |
| `--min-fr-aas [N]` | 谱库过滤：碎片至少含 N 个残基（默认 3） |

### 定量与矩阵

| 参数 | 说明 |
|---|---|
| `--quant-qvalue [X]` | 相对定量优先使用的 q-value 阈值 |
| `--protein-quant-qvalue [X]` | 蛋白定量优先 q-value |
| `--matrix-qvalue [X]` | 输出矩阵过滤 q-value |
| `--high-acc` | QuantUMS 最高精度模式（最小化 ratio compression） |
| `--export-quant` | 导出 fragment 级定量与质量信息 |
| `--xic [X]` | 为鉴定前体提取前后 X 秒色谱图 |
| `--min-corr [X]` | 峰组相关分数下限 |
| `--global-norm` | 简单全局归一化（替代默认 RT 依赖归一化） |
| `--no-rt-norm` / `--no-prot-norm` | 关闭 RT 依赖归一化 / 蛋白级归一化 |
| `--cont-quant-exclude <tag>` | 从归一化/定量矩阵中排除带指定标签的蛋白（如 `cRAP-`） |
| `--report-decoys` | 主报告保留 decoy 条目 |
| `--no-stats` | 不生成 stats 文件 |

---

*手册基于 GUI v1.13 源码（R 包 diann.gui）、DIA-NN 官方文档与集群实测记录整理；2026-10-27。*
