# ============================================================
# artifacts.R — 输出目录遗留产物归档 (纯函数, 可离线测试)
#
# 提交前把上一次运行的「同名主报告」与「同名矩阵」改名为
# <名称>.pre_<时间戳>.tsv, 防止旧结果掩盖本次运行的状态判定
# (四层状态合成的产物层只看主报告是否存在且晚于本次开始)。
#
# 安全要点 (2026-10 审查):
#   用户输入的 report 名不得拼进正则 —— 此前 `pattern = paste0("^", base, ...)`
#   在 report 名含 `[`/`(` 时让 list.files 抛 "invalid 'pattern' regular expression",
#   名称为 "." 时更会匹配目录内全部 tsv 并批量改名。这里改为逐字面量比较。
# ============================================================

archive_stale_artifacts <- function(out_dir, out_file, now = Sys.time()) {
  empty <- data.frame(from = character(0), to = character(0), stringsAsFactors = FALSE)
  if (length(out_dir) != 1 || !nz_str(out_dir) || !dir.exists(out_dir)) return(empty)
  if (length(out_file) != 1 || !nz_str(out_file)) return(empty)
  base <- tools::file_path_sans_ext(basename(out_file))
  if (!nzchar(base)) return(empty)

  files <- list.files(out_dir, full.names = TRUE)
  if (!length(files)) return(empty)
  nm <- basename(files)
  # 主报告: 精确 <base>.tsv; 矩阵: 以 <base> 开头 + 含 "matrix" + .tsv 结尾
  is_main <- nm == paste0(base, ".tsv")
  is_matrix <- startsWith(nm, base) & grepl("matrix", nm, fixed = TRUE) & grepl("\\.tsv$", nm)
  keep <- (is_main | is_matrix) & !grepl(".pre_", nm, fixed = TRUE)
  keep <- keep & file.exists(files) & file.info(files)$size > 0
  olds <- files[keep]
  if (!length(olds)) return(empty)

  stamp <- format(now, "%Y%m%d_%H%M%S")
  rows <- list()
  for (f in olds) {
    tgt <- sprintf("%s.pre_%s.tsv", file.path(out_dir, tools::file_path_sans_ext(basename(f))), stamp)
    # rename 跨设备失败时退回 copy + remove (与旧实现一致)
    ok <- tryCatch(
      file.rename(f, tgt) || (file.copy(f, tgt, overwrite = TRUE) && file.remove(f)),
      error = function(e) FALSE)
    if (isTRUE(ok)) rows[[length(rows) + 1L]] <- c(basename(f), basename(tgt))
  }
  if (!length(rows)) return(empty)
  df <- as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
  names(df) <- c("from", "to")
  df
}

# 清理过期产物 (默认 90 天): 脚本/rc/项目简介与 *.pre_<时间戳>.tsv。
# 输出目录长期使用会无限增长; 保留策略按 mtime 判断, 返回删除数量。
cleanup_old_artifacts <- function(out_dir, days = 90, now = Sys.time()) {
  if (length(out_dir) != 1 || !nz_str(out_dir) || !dir.exists(out_dir)) return(0L)
  days <- suppressWarnings(as.numeric(days))
  if (is.na(days) || days <= 0) return(0L)
  cutoff <- as.numeric(now) - days * 86400
  script_dir <- file.path(out_dir, "diann_gui_scripts")
  cand <- character(0)
  if (dir.exists(script_dir)) {
    cand <- c(cand, list.files(script_dir, pattern = "\\.(sh|rc)$|_desc\\.txt$", full.names = TRUE))
  }
  cand <- c(cand, list.files(out_dir, pattern = "\\.pre_[0-9]{8}_[0-9]{6}\\.tsv$", full.names = TRUE))
  cand <- cand[file.exists(cand)]
  if (!length(cand)) return(0L)
  mt <- as.numeric(file.info(cand)$mtime)
  old <- cand[!is.na(mt) & mt < cutoff]
  if (!length(old)) return(0L)
  n <- 0L
  for (f in old) {
    if (isTRUE(tryCatch(unlink(f) == 0L, error = function(e) FALSE))) n <- n + 1L
  }
  n
}
