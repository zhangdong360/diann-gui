#!/usr/bin/env Rscript
# ============================================================
# usage_report.R — DIA-NN GUI 平台使用统计 (月度)
#
# 数据源 = GUI 提交注册表 (diann_gui_jobs_registry.rds, 含每次提交的输出目录),
# 按提交时间过滤月份; 每个作业用 notify_common.R 的 diann_job_status 四层模型
# 合成状态标签, 输出 markdown 报告: 提交数 / 状态分布 / 耗时统计 / 失败与待核实明细。
#
# 用法:
#   Rscript usage_report.R [--month 2026-10] [--out DIR] [--registry FILE] [--state FILE]
#   --month    统计月份 (默认当月)
#   --out      报告输出目录 (默认当前目录, 文件名 usage_report_<月份>.md)
#   --registry/--state  显式指定注册表/通知状态 RDS (默认按 $HOME 推导, 与 GUI 一致;
#              仅用于补充邮箱, 读取失败不影响报告)
#
# 局限与说明:
# - 运行身份必须能读注册表与各作业输出目录: 通常即 GUI worker 的运行用户 (shiny-server
#   run_as 用户, 其 HOME 下存放注册表) —— 例如放在该用户的 crontab 里, 或放宽 HOME 权限
# - 注册表滚动保留最近 300 条: 更早月份的作业不在统计内 (sacct 可查但缺输出目录, 无法定
#   位产物与 rc 文件); 部署满 300 条前建议按月归档注册表
# - Slurm workdir 恒为 shiny-server staging 目录 (作业由 worker 进程提交), 故不能从
#   sacct 反查输出目录 —— 必须以注册表为准
# - 只读脚本, 不写任何 GUI 状态文件
# - 建议每月初统计上月: crontab 示例
#     0 9 1 * *  Rscript /path/to/usage_report.R --month $(date -d 'last month' +\%Y-\%m) --out /path/to/reports
# ============================================================

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = "") {
  i <- match(flag, args)
  if (!is.na(i) && length(args) >= i + 1) args[i + 1] else default
}
month <- get_arg("--month", format(Sys.Date(), "%Y-%m"))
out_dir <- get_arg("--out", ".")
reg_override <- get_arg("--registry", "")
state_override <- get_arg("--state", "")

if (!grepl("^\\d{4}-\\d{2}$", month)) {
  stop("--month 需要 YYYY-MM 格式, 例如 2026-10")
}

# ---- 推导脚本自身目录 (与 app.R 同手法, 支持符号链接部署) ----
app_dir <- local({
  a <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", a[grepl("^--file=", a)])
  if (length(f)) dirname(normalizePath(f[1], mustWork = FALSE)) else getwd()
})
source(file.path(app_dir, "notify_common.R"))
if (!exists("diann_job_status")) stop("notify_common.R 加载失败")

# ---- 注册表 (作业清单主源) / 通知状态 (仅补邮箱, 尽力读取) ----
read_rds_opt <- function(path) {
  if (!nzchar(path) || !file.exists(path)) return(NULL)
  tryCatch(readRDS(path), error = function(e) NULL)
}
home <- Sys.getenv("HOME", unset = "/tmp")
registry <- read_rds_opt(if (nzchar(reg_override)) reg_override else file.path(home, "diann_gui_jobs_registry.rds"))
nstate <- read_rds_opt(if (nzchar(state_override)) state_override else file.path(home, "diann_gui_notify_state.rds"))
if (is.null(registry) || !nrow(registry)) {
  cat("注册表为空或不可读 (", file.path(home, "diann_gui_jobs_registry.rds"),
      "): 无统计数据, 退出。可用 --registry 指定路径。\n", sep = "")
  quit(status = 1)
}
recs <- if (!is.null(nstate)) nstate$recs else list()
rec_by_id <- setNames(recs, vapply(recs, function(r) as.character(r$jobid), ""))

gui <- registry[substr(as.character(registry$提交时间), 1, 7) == month, , drop = FALSE]
if (!nrow(gui)) {
  cat(sprintf("注册表中 %s 无提交记录 (注册表覆盖 %s ~ %s), 退出。\n", month,
              min(as.character(registry$提交时间)), max(as.character(registry$提交时间))))
  quit(status = 0)
}

# ---- 每作业状态合成 ----
# 主报告文件名: 优先取输出目录里最新的非矩阵 tsv (report 名用户可自定义, 注册表未存)
report_of <- function(out_d) {
  cand <- list.files(out_d, pattern = "\\.tsv$", full.names = TRUE)
  cand <- cand[!grepl("matrix|\\.pre_|slurm-", basename(cand))]
  if (!length(cand)) "" else cand[which.max(file.info(cand)$mtime)]
}
script_of <- function(out_d, jid) {
  sd <- file.path(out_d, "diann_gui_scripts")
  shs <- list.files(sd, pattern = "\\.sh$", full.names = TRUE)
  if (!length(shs)) return("")
  hit <- shs[file.exists(sub("\\.sh$", ".rc", shs))]  # 有 rcfile 的 = v1.8+ 模板
  pool <- if (length(hit)) hit else shs
  # 同目录可能有多作业脚本, 与本 jobid 的日志配对优先 (日志名 slurm-<id>.out 同目录)
  pool
}
email_of <- function(jid) {
  r <- rec_by_id[[as.character(jid)]]
  if (is.null(r)) "" else paste(as.character(r$to), collapse = ",")
}
gui$report <- vapply(gui$输出目录, report_of, "")
gui$email <- vapply(as.character(gui$jobid), email_of, "")
gui$label <- ""
gui$reason <- ""
gui$elapsed_s <- NA_integer_
for (i in seq_len(nrow(gui))) {
  wd <- as.character(gui$输出目录[i])
  jid <- as.integer(gui$jobid[i])
  logf <- file.path(wd, sprintf("slurm-%d.out", jid))
  es_i <- if (file.exists(logf)) suppressWarnings(diann_notify_elapsed(logf, jid)) else NA_integer_
  gui$elapsed_s[i] <- if (length(es_i) == 1L && !is.null(es_i)) es_i else NA_integer_
  st <- tryCatch(
    diann_job_status(jid, wd, gui$report[i],
                     script_path = if (length(script_of(wd, jid))) script_of(wd, jid)[1] else ""),
    error = function(e) NULL)
  gui$label[i] <- if (is.null(st)) "未知" else st$label
  gui$reason[i] <- if (is.null(st)) "状态合成异常" else st$reason
}

# ---- 汇总与输出 ----
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
rep_path <- file.path(out_dir, sprintf("usage_report_%s.md", month))
fmt_elapsed <- function(s) {
  ok <- !is.na(s)
  out <- rep("-", length(s))
  h <- s[ok] %/% 3600; m <- (s[ok] %% 3600) %/% 60; sec <- s[ok] %% 60
  out[ok] <- ifelse(h > 0, sprintf("%d时%02d分%02d秒", h, m, sec), sprintf("%d分%02d秒", m, sec))
  out
}
tab <- data.frame(
  JobID = as.character(gui$jobid), 任务名 = as.character(gui$任务名), 状态 = gui$label,
  耗时 = fmt_elapsed(gui$elapsed_s), 提交时间 = as.character(gui$提交时间),
  邮箱 = ifelse(nzchar(gui$email), gui$email, "-"), stringsAsFactors = FALSE)
cnt <- table(factor(gui$label, levels = c("成功", "失败", "待核实", "超时", "已取消", "未知")))
es <- gui$elapsed_s[!is.na(gui$elapsed_s)]
prob <- gui[!gui$label %in% c("成功", "已取消"), ]

con <- file(rep_path, open = "wt", encoding = "UTF-8")
wl <- function(...) writeLines(as.character(unlist(list(...), use.names = FALSE)), con = con)
wl(sprintf("# DIA-NN GUI 使用统计 — %s", month), "",
   sprintf("- GUI 提交作业数: **%d**", nrow(gui)),
   sprintf("- 数据源: 提交注册表 (%s ~ %s)",
           min(as.character(registry$提交时间)), max(as.character(registry$提交时间))), "",
   "## 状态分布", "",
   "| 状态 | 数量 |", "|---|---|",
   sprintf("| %s | %d |", names(cnt), as.integer(cnt)), "",
   if (length(es)) sprintf(
     "耗时: 平均 **%.0f 分钟**, 中位 **%.0f 分钟**, 最长 %s (JobID %s)",
     mean(es) / 60, median(es) / 60,
     fmt_elapsed(max(es))[1], as.character(gui$jobid)[which.max(gui$elapsed_s)]) else "耗时: 无数据", "",
   if (nrow(prob)) c("## 失败 / 待核实明细", "",
                     "| JobID | 任务名 | 状态 | 原因 |", "|---|---|---|---|",
                     sprintf("| %s | %s | %s | %s |",
                             prob$jobid, prob$任务名, prob$label, prob$reason)) else
     c("## 失败 / 待核实明细", "", "本月无失败或待核实作业。"), "",
   "## 逐作业明细", "",
   paste0("| ", paste(names(tab), collapse = " | "), " |"),
   paste0("|", paste(rep("---", ncol(tab)), collapse = "|"), "|"),
   apply(tab, 1, function(r) paste0("| ", paste(r, collapse = " | "), " |")), "",
   sprintf("> 生成时间: %s; 状态由四层模型合成 (Slurm 终态 → 程序退出码 → 产物验证 → 展示合成)",
           format(Sys.time(), "%Y-%m-%d %H:%M:%S")))
close(con)
cat(sprintf("报告已写入: %s (GUI 作业 %d, 成功 %d, 失败 %d, 待核实 %d)\n",
            rep_path, nrow(gui), cnt[["成功"]], cnt[["失败"]], cnt[["待核实"]]))
