# ============================================================
# shared-dirs.R — 输出目录组修复 (legacy 共享部署变体)
# 自托管单人模式: SHARED_GROUP 为空, 本函数直接返回 (无操作)。
# 仅供"多账户共读同一输出目录"的历史 shiny-server 部署使用; 文档已标 legacy。
# ============================================================

fix_shared_dirs <- function(leafs) {
  group <- cfg_get("SHARED_GROUP") %||% ""
  if (!nzchar(group)) return(invisible(NULL))
  data_home <- cfg_get("DATA_HOME") %||% ""
  if (!nzchar(data_home)) {
    warning("SHARED_GROUP 已设置但 DATA_HOME 为空: 跳过组修复 (避免改动 DATA_HOME 之上的目录)")
    return(invisible(NULL))
  }
  dh <- normalizePath(data_home, mustWork = FALSE)
  for (leaf in leafs) {
    d <- normalizePath(leaf, mustWork = FALSE)
    while (nzchar(d) && !identical(d, "/")) {
      # 只修 DATA_HOME 的后代; 到达 DATA_HOME 本身或越界即停止 (旧实现会一路修到 /)
      if (identical(d, dh)) break
      if (!startsWith(d, paste0(dh, "/"))) {
        warning(sprintf("路径不在 DATA_HOME (%s) 之下, 跳过: %s", dh, d))
        break
      }
      try(Sys.chmod(d, "2770"), silent = TRUE)
      try(suppressWarnings(system2("chgrp", c(group, d), stderr = FALSE)), silent = TRUE)
      p <- dirname(d)
      if (identical(p, d)) break
      d <- p
    }
  }
  invisible(NULL)
}
