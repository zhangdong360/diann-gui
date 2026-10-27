# ============================================================
# analysis-deps.R — 结果分析·可选依赖的运行时检查
#
# 设计原则 (v1.14): 「提交 DIA-NN 作业」核心链保持轻量 (见 DESCRIPTION Imports),
# 下游分析的全部依赖放 Suggests / 运行时检查, 缺失时给出可操作的安装提示,
# 不做静默自动安装 (HPC 无网 / 无权限场景自动安装只会挂死或失败)。
# 注释库 (org.*.eg.db)、sva、impute、KEGG.db 体积大或已被 Bioconductor 移除,
# 不写入 DESCRIPTION, 仅在此提示。
# ============================================================

# 依赖分组: label 用于界面展示; bioc = TRUE 的包用 BiocManager 安装

# ---------- 软依赖解析 (R CMD check 合规的可选依赖间接层) ----------
# clusterProfiler/AnnotationDbi/impute/sva/KEGG.db 为重量级可选依赖 (KEGG.db 已被
# Bioconductor 移除, 无法声明进 Suggests): 有意不声明, 运行时按需解析、缺失时
# 优雅降级 (本文件的检查组 + doctor + UI 安装提示)。字面 `pkg::fun` /
# requireNamespace("pkg") 调用会被 R CMD check 判为未声明依赖 (WARNING), 故统一
# 经此间接层: 包名作变量传递, check 无法静态绑定 → 警告消除, 行为不变。
analysis_soft_has <- function(pkg) {
  requireNamespace(pkg, character.only = TRUE, quietly = TRUE)
}

analysis_soft_fun <- function(pkg, fun) {
  if (!analysis_soft_has(pkg)) return(NULL)
  utils::getFromNamespace(fun, pkg)
}

an_deps_groups <- function() {
  list(
    qc = list(
      label = "预处理与 QC 可视化",
      pkgs  = c(ggplot2 = FALSE, ggrepel = FALSE, gridExtra = FALSE,
                pheatmap = FALSE, scales = FALSE, svglite = FALSE,
                jsonlite = FALSE)),
    de = list(
      label = "差异分析 (limma)",
      pkgs  = c(limma = TRUE, openxlsx = FALSE)),
    enrich = list(
      label = "功能富集 (GO/KEGG)",
      pkgs  = c(clusterProfiler = TRUE, AnnotationDbi = TRUE)),
    report = list(
      label = "报告生成与打包下载",
      pkgs  = c(zip = FALSE))
  )
}

# 可选增强依赖 (缺失只降级功能, 不阻断)
an_deps_optional <- function() {
  c("sva" = "ComBat 去批次",
    "impute" = "kNN 缺失值插补 (缺失时退回行中位数)",
    "KEGG.db" = "本地 KEGG 通路库 (已被 Bioconductor 移除, 需从 archive 安装; 或改用在线 KEGG)",
    "org.Hs.eg.db" = "人注释库 (富集)",
    "org.Mm.eg.db" = "小鼠注释库 (富集)",
    "org.Rn.eg.db" = "大鼠注释库 (富集)",
    "org.Dr.eg.db" = "斑马鱼注释库 (富集)")
}

# 单包安装命令
an_deps_install_one <- function(pkg, bioc) {
  if (isTRUE(bioc)) sprintf("BiocManager::install(\"%s\")", pkg)
  else sprintf("install.packages(\"%s\")", pkg)
}

# 检查一组包: 返回 data.frame(pkg, bioc, installed, group)
an_deps_check <- function(groups = names(an_deps_groups())) {
  all <- an_deps_groups()
  rows <- list()
  for (g in intersect(groups, names(all))) {
    pkgs <- all[[g]]$pkgs
    for (i in seq_along(pkgs)) {
      rows[[length(rows) + 1L]] <- data.frame(
        pkg = names(pkgs)[i], bioc = as.logical(pkgs[i]),
        installed = requireNamespace(names(pkgs)[i], quietly = TRUE),
        group = all[[g]]$label, stringsAsFactors = FALSE)
    }
  }
  if (!length(rows)) {
    return(data.frame(pkg = character(0), bioc = logical(0),
                      installed = logical(0), group = character(0),
                      stringsAsFactors = FALSE))
  }
  do.call(rbind, rows)
}

# 缺失包的安装提示 (按 CRAN/Bioc 归并, 生成可复制的 R 命令)
an_deps_install_hint <- function(miss_pkg, miss_bioc) {
  if (!length(miss_pkg)) return(character(0))
  cran <- miss_pkg[!miss_bioc]
  bioc <- miss_pkg[miss_bioc]
  cmds <- character(0)
  if (length(cran)) cmds <- c(cmds, sprintf("install.packages(c(%s))",
                                            paste0("\"", cran, "\"", collapse = ", ")))
  if (length(bioc)) cmds <- c(cmds, sprintf("BiocManager::install(c(%s))",
                                            paste0("\"", bioc, "\"", collapse = ", ")))
  cmds
}

# 全部依赖状态汇总 (doctor / 模块引导页共用): list(ok, missing_pkgs, hints, df)
an_deps_status <- function() {
  df <- an_deps_check()
  miss <- df[!df$installed, , drop = FALSE]
  hints <- if (nrow(miss)) an_deps_install_hint(miss$pkg, miss$bioc) else character(0)
  list(ok = nrow(miss) == 0, missing_pkgs = miss$pkg, hints = hints, df = df)
}
