# i18n 术语表 (GLOSSARY)

翻译表 `translations.json` 的 key = 中文原文整句（sprintf 模板原样作 key，
`%s`/`%d` 占位符数量与顺序必须与英文译文一致）。本表约定高频术语的固定译法，
新译文必须遵守，避免同一概念多种译名。

| 中文 | English | 说明 |
|---|---|---|
| 作业 | job | Slurm / 本地通用 |
| 任务队列 | Job Queue | 监控页签 |
| 提交分析 | Submit Analysis | 页签名 |
| 结果分析 | Downstream Analysis | 页签/模块名 |
| 参数速查 | Parameter Reference | 页签名 |
| 更新说明 | Changelog | 页签名 |
| 执行后端 | execution backend | |
| 本地单机 | Local workstation | header 徽章/横幅 |
| Slurm 集群 | Slurm cluster | |
| 镜像 | image | .sif 容器镜像 |
| 已识别 | identified | 镜像版本已实测 |
| 未识别 | unidentified | |
| 分区 | partition | Slurm |
| 运行时 | runtime | apptainer/singularity |
| 自检 | self-check | doctor() |
| 数据根 | data root | DATA_HOME |
| 输出目录 | output directory | |
| 取消 | cancel | 作业取消 |
| 排队 | pending / queued (squeue 状态原样) | |
| 已取消 | cancelled | |
| 超时 | timeout | |
| 提交 | submit | |
| 必填 | required | |
| 邮件通知 | e-mail notification | |
| 监控 | monitor | |
| 日志 | log | |
| 线程 | thread(s) | |
| 污染物扣除 | contaminant removal | |
| 上限 | cap | LOCAL_MAX_JOBS 等 |
| 回退 | fall back / fallback | |
| 并发 | concurrency | |

## 规则

1. **整句作 key**：key 是完整中文句子/短语（含标点），不做词级拼接；
   英文整句翻译，允许语序调整，但 sprintf 占位符必须逐个对应。
2. **专有名词不改**：`diann-linux`、`apptainer`、`sbatch`、`LOCAL_MAX_JOBS`、
   `.sif`、`pg_matrix`、路径、命令等原样保留。
3. **标点跟随语言**：英文用半角标点；中文 key 本身带全角标点的，译文用半角。
4. **状态词与 squeue/sacct 原始状态**（RUNNING/PENDING/…）不在翻译范围。
5. 新增 key 忘写 en 列时, `tests/testthat/test-i18n.R` 会失败 —— 补上再提交。
