# ============================================================
# usage-report.R — 平台使用统计 (月度), 导出为 usage_report()
# 数据源 = GUI 提交注册表 (HOME 下 diann_gui_jobs_registry.rds), 按提交时间过滤;
# 每作业按记录的执行后端 (slurm/local, 旧记录缺省 slurm) 选日志与状态来源,
# 用 diann_job_status 四层模型合成状态, 输出 markdown 报告:
# 提交数 / 状态分布 / 耗时统计 / 失败与待核实明细, 逐作业明细含"后端"列。
# 注意: 注册表滚动保留最近 300 条, 更早月份不在统计内; 运行身份需能读注册表
# 与各作业输出目录 (自托管模式即用户本人, 天然满足)。
# ============================================================

#' 生成平台使用统计 (月度 markdown 报告)
#'
#' @param month 统计月份, "YYYY-MM" (默认当月)
#' @param out_dir 报告输出目录 (默认当前目录, 文件名 usage_report_<月份>.md)
#' @param registry 注册表 RDS 路径 (默认 HOME 下与 GUI 一致的位置)
#' @param state 通知状态 RDS 路径 (仅用于补充邮箱, 读取失败不影响报告)
#' @return 报告文件路径 (当月无记录时返回 NULL)
#' @export
usage_report <- function(month = format(Sys.Date(), "%Y-%m"),
                         out_dir = ".", registry = NULL, state = NULL) {
  if (!grepl("^\\d{4}-\\d{2}$", month)) stop("`month` 需要 YYYY-MM 格式, 例如 2026-10")

  read_rds_opt <- function(path) {
    if (is.null(path) || !nzchar(path) || !file.exists(path)) return(NULL)
    tryCatch(readRDS(path), error = function(e) NULL)
  }
  # 注册表默认位置与 GUI 完全一致 (jobs_registry_file 依赖 NOTIFY_STATE; 未加载配置时先加载)
  if (is.null(cfg_get("NOTIFY_STATE"))) try(diann_load_config(), silent = TRUE)
  def_registry <- if (nzchar(cfg_get("NOTIFY_STATE") %||% "")) jobs_registry_file() else
    file.path(Sys.getenv("HOME", unset = "/tmp"), "diann_gui_jobs_registry.rds")
  registry <- read_rds_opt(if (!is.null(registry) && nzchar(registry)) registry else def_registry)
  nstate <- read_rds_opt(if (!is.null(state) && nzchar(state)) state else
    file.path(dirname(def_registry), "diann_gui_notify_state.rds"))
  if (is.null(registry) || !nrow(registry)) {
    message("注册表为空或不可读 (", def_registry,
            "): 无统计数据。可用 registry 参数指定路径。")
    return(invisible(NULL))
  }
  recs <- if (!is.null(nstate)) nstate$recs else list()
  rec_by_id <- setNames(recs, vapply(recs, function(r) as.character(r$jobid), ""))

  gui <- registry[substr(as.character(registry$提交时间), 1, 7) == month, , drop = FALSE]
  if (!nrow(gui)) {
    message(sprintf("注册表中 %s 无提交记录 (注册表覆盖 %s ~ %s)。", month,
                    min(as.character(registry$提交时间)), max(as.character(registry$提交时间))))
    return(invisible(NULL))
  }

  # ---- 每作业状态合成 ----
  # 主报告/脚本优先用注册表 v2 记录 (script_path/out_file); 旧注册表没有这两列,
  # 才回退到"目录里最新非矩阵 tsv / 有 rcfile 的脚本"这种启发式 (同目录多作业会误配)。
  col_or_na <- function(df, nm) {
    if (nm %in% names(df)) as.character(df[[nm]]) else rep(NA_character_, nrow(df))
  }
  out_files <- col_or_na(gui, "out_file")
  scripts <- col_or_na(gui, "script_path")
  # v1.12: 按记录的后端分派; 旧 v2 注册表没有 backend 列 -> 缺省按 slurm 解释。
  backs <- col_or_na(gui, "backend")
  backs[is.na(backs) | !nzchar(backs)] <- "slurm"
  backs <- ifelse(backs %in% c("slurm", "local"), backs, "slurm")
  logs <- col_or_na(gui, "日志")
  # 状态函数按后端分组懒构建 (slurm: 一次快照注入; local: 本地作业状态文件),
  # 避免同一个月报里每条记录各起 squeue/sacct 子进程。
  fns_cache <- list()
  status_fns <- function(bk) {
    if (!is.null(fns_cache[[bk]])) return(fns_cache[[bk]])
    fns <- tryCatch(backend_status_fns(bk),
                    error = function(e) list(squeue_fn = NULL, sacct_fn = NULL))
    fns_cache[[bk]] <<- fns
    fns
  }
  report_of <- function(out_d, out_file = NA_character_) {
    if (length(out_file) == 1 && !is.na(out_file) && nzchar(out_file)) {
      if (file.exists(out_file)) return(out_file)
      # 记录的主报告可能已被下一次提交归档为 <base>.pre_<时间戳>.tsv; 取最新归档,
      # 否则历史作业在月报里会退化成"未知"。
      base <- tools::file_path_sans_ext(basename(out_file))
      nm <- list.files(out_d)
      arch <- nm[startsWith(nm, paste0(base, ".pre_")) & grepl("\\.tsv$", nm)]
      if (length(arch)) {
        full <- file.path(out_d, arch)
        return(full[which.max(file.info(full)$mtime)])
      }
      return(out_file)  # 确实没有产物: 让状态合成判为"无本次产物"
    }
    cand <- list.files(out_d, pattern = "\\.tsv$", full.names = TRUE)
    cand <- cand[!grepl("matrix|\\.pre_|slurm-", basename(cand))]
    if (!length(cand)) "" else cand[which.max(file.info(cand)$mtime)]
  }
  script_of <- function(out_d, jid, script_path = NA_character_) {
    if (length(script_path) == 1 && !is.na(script_path) && nzchar(script_path)) return(script_path)
    sd <- file.path(out_d, "diann_gui_scripts")
    shs <- list.files(sd, pattern = "\\.sh$", full.names = TRUE)
    if (!length(shs)) return("")
    hit <- shs[file.exists(sub("\\.sh$", ".rc", shs))]  # 有 rcfile 的 = v1.8+ 模板
    hit
  }
  email_of <- function(jid) {
    r <- rec_by_id[[as.character(jid)]]
    if (is.null(r)) "" else paste(as.character(r$to), collapse = ",")
  }
  gui$backend <- backs
  gui$report <- vapply(seq_len(nrow(gui)), function(i) {
    report_of(as.character(gui$输出目录[i]), out_files[i])
  }, "")
  gui$script <- vapply(seq_len(nrow(gui)), function(i) {
    script_of(as.character(gui$输出目录[i]), as.integer(gui$jobid[i]), scripts[i])[1]
  }, "")
  # 日志路径: 注册表"日志"列优先 (旧 v2 记录只有 slurm-<id>.out, 仍然正确);
  # 缺列/NA 时按后端契约生成 (local-<id>.out / slurm-<id>.out)。
  gui$log <- vapply(seq_len(nrow(gui)), function(i) {
    lv <- logs[i]
    if (!is.na(lv) && nzchar(lv)) return(lv)
    lp <- tryCatch(backend_log_paths(gui$jobid[i], as.character(gui$输出目录[i]),
                                     gui$backend[i], gui$script[i]), error = function(e) NULL)
    if (is.null(lp) || !length(lp$out)) "" else as.character(lp$out)[1]
  }, "")
  gui$email <- vapply(as.character(gui$jobid), email_of, "")
  gui$label <- ""
  gui$reason <- ""
  gui$elapsed_s <- NA_integer_
  for (i in seq_len(nrow(gui))) {
    wd <- as.character(gui$输出目录[i])
    jid <- as.integer(gui$jobid[i])
    bk <- as.character(gui$backend[i])
    logf <- gui$log[i]
    es_i <- tryCatch(backend_elapsed(jid, logf, bk, gui$script[i]),
                     error = function(e) NA_integer_)
    gui$elapsed_s[i] <- if (length(es_i) == 1L && !is.null(es_i) && !is.na(es_i)) {
      as.integer(es_i)
    } else NA_integer_
    fns <- status_fns(bk)
    st <- tryCatch(
      diann_job_status(jid, wd, gui$report[i], script_path = gui$script[i],
                       squeue_fn = fns$squeue_fn, sacct_fn = fns$sacct_fn,
                       log_path = logf),
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
  # v1.14.1: 逐作业表补「版本」列 (注册表 v2 起就记录容器实测版本, 月报此前一直没显示)
  ver_col <- col_or_na(gui, "版本")
  ver_col[is.na(ver_col) | !nzchar(ver_col)] <- "未识别"
  tab <- data.frame(
    JobID = as.character(gui$jobid), 任务名 = as.character(gui$任务名), 版本 = ver_col,
    状态 = gui$label,
    后端 = ifelse(gui$backend == "local", "本地", "Slurm"),
    耗时 = fmt_elapsed(gui$elapsed_s), 提交时间 = as.character(gui$提交时间),
    邮箱 = ifelse(nzchar(gui$email), gui$email, "-"), stringsAsFactors = FALSE)
  cnt <- table(factor(gui$label, levels = c("成功", "失败", "待核实", "超时", "已取消", "未知")))
  n_slurm <- sum(gui$backend == "slurm")
  n_local <- sum(gui$backend == "local")
  es <- gui$elapsed_s[!is.na(gui$elapsed_s)]
  prob <- gui[!gui$label %in% c("成功", "已取消"), ]

  con <- file(rep_path, open = "wt", encoding = "UTF-8")
  wl <- function(...) writeLines(as.character(unlist(list(...), use.names = FALSE)), con = con)
  wl(sprintf("# DIA-NN GUI 使用统计 — %s", month), "",
     sprintf("- GUI 提交作业数: **%d**", nrow(gui)),
     sprintf("- 执行后端: Slurm **%d** 条 / 本地 **%d** 条", n_slurm, n_local),
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
                       "| JobID | 任务名 | 后端 | 状态 | 原因 |", "|---|---|---|---|---|",
                       sprintf("| %s | %s | %s | %s | %s |",
                               prob$jobid, prob$任务名,
                               ifelse(prob$backend == "local", "本地", "Slurm"),
                               prob$label, prob$reason)) else
       c("## 失败 / 待核实明细", "", "本月无失败或待核实作业。"), "",
     "## 逐作业明细", "",
     paste0("| ", paste(names(tab), collapse = " | "), " |"),
     paste0("|", paste(rep("---", ncol(tab)), collapse = "|"), "|"),
     apply(tab, 1, function(r) paste0("| ", paste(r, collapse = " | "), " |")), "",
     sprintf("> 生成时间: %s; 状态由四层模型合成 (调度终态/本地进程态 → 程序退出码 → 产物验证 → 展示合成)",
             format(Sys.time(), "%Y-%m-%d %H:%M:%S")))
  close(con)
  cat(sprintf("报告已写入: %s (GUI 作业 %d [Slurm %d / 本地 %d], 成功 %d, 失败 %d, 待核实 %d)\n",
              rep_path, nrow(gui), n_slurm, n_local,
              cnt[["成功"]], cnt[["失败"]], cnt[["待核实"]]))
  invisible(rep_path)
}
