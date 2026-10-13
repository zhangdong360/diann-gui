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
  df <- df[order(df$ver, decreasing = TRUE), ]
  df[!duplicated(df$ver), ]
}
