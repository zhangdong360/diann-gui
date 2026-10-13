# ============================================================
# shared-dirs.R — 输出目录组修复 (中央/共享部署变体)
# 自托管单人模式: SHARED_GROUP 为空, 本函数直接返回 (无操作)。
# ============================================================

fix_shared_dirs <- function(leafs) {
  group <- cfg_get("SHARED_GROUP")
  data_home <- cfg_get("DATA_HOME")
  if (!nzchar(group)) return(invisible(NULL))
  for (leaf in leafs) {
    d <- normalizePath(leaf, mustWork = FALSE)
    while (nzchar(d) && d != "/" && d != data_home) {
      try(Sys.chmod(d, "2770"), silent = TRUE)
      try(suppressWarnings(system2("chgrp", c(group, d), stderr = FALSE)), silent = TRUE)
      p <- dirname(d)
      if (identical(p, d)) break
      d <- p
    }
  }
}
