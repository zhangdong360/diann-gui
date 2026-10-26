# ============================================================
# sif.R — DIA-NN 镜像扫描
# ============================================================
# 扫描 SIF_DIRS (递归) 并按版本去重; 由 run_app() 启动时调用。

scan_sif_images <- function(dirs) {
  dirs <- dirs[!is.na(dirs) & nzchar(dirs)]
  if (!length(dirs)) return(data.frame(ver = character(), path = character()))
  paths <- unlist(lapply(dirs, function(d) {
    if (dir.exists(d)) {
      list.files(d, pattern = "(?i)^diann.*\\.sif$", full.names = TRUE, recursive = TRUE)
    } else character(0)
  }), use.names = FALSE)
  paths <- unique(normalizePath(paths, mustWork = FALSE))
  if (!length(paths)) return(data.frame(ver = character(), path = character()))
  ver <- sub("(?i).*diann[-._ ]?([0-9]+(?:\\.[0-9]+)*).*", "\\1", basename(paths), perl = TRUE)
  df <- data.frame(path = paths, ver = ver, stringsAsFactors = FALSE)
  df <- df[df$ver != "", ]
  # 版本按数值排序: 字符串排序会把 2.10.0 排到 2.9.1 之后, 默认镜像选错版本
  nv <- suppressWarnings(as.numeric_version(df$ver))
  df <- df[order(nv, decreasing = TRUE, na.last = TRUE), , drop = FALSE]
  df[!duplicated(df$ver), , drop = FALSE]
}
