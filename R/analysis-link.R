# ============================================================
# analysis-link.R — 结果分析与任务队列的闭环 (v1.14)
#
# 作业完成后, 输出目录内通常同时有 主报告 (report.tsv, 前体级) 与
# 蛋白矩阵 (--matrices 导出, 如 report.pg_matrix.tsv)。下游分析模块吃后者;
# 这里复用 artifacts.R 的 "*matrix*.tsv" 识别约定, 从输出目录里发现矩阵:
# pg_matrix 优先, 其次按修改时间新→旧; 已归档 (.pre_) 与空文件排除。
# ============================================================

# 从 DIA-NN 输出目录发现蛋白定量矩阵; 返回 data.frame(path, size, mtime)
analysis_find_matrices <- function(out_dir) {
  empty <- data.frame(path = character(0), size = numeric(0), mtime = numeric(0),
                      stringsAsFactors = FALSE)
  if (length(out_dir) != 1 || is.na(out_dir) || !nzchar(out_dir) || !dir.exists(out_dir))
    return(empty)
  files <- list.files(out_dir, full.names = TRUE)
  if (!length(files)) return(empty)
  nm <- basename(files)
  hit <- grepl("matrix", nm, fixed = TRUE) &
         grepl("\\.tsv$", nm, ignore.case = TRUE) &
         !grepl(".pre_", nm, fixed = TRUE) &
         !dir.exists(files)
  files <- files[hit]
  if (!length(files)) return(empty)
  fi <- file.info(files)
  keep <- !is.na(fi$size) & fi$size > 0
  if (!any(keep)) return(empty)
  files <- files[keep]; mt <- as.numeric(fi$mtime[keep])
  # pg_matrix (蛋白级) 优先; 其余 (如 precursor_matrix) 靠后; 同优先级新→旧
  pri <- ifelse(grepl("pg_matrix", basename(files), ignore.case = TRUE), 0L, 1L)
  ord <- order(pri, -mt)
  data.frame(path = files[ord], size = as.numeric(fi$size[keep])[ord], mtime = mt[ord],
             stringsAsFactors = FALSE)
}
