# ============================================================
# analysis-enrich.R — 结果分析·GO/KEGG 富集核心 (移植自 mass_analysis/core_enrich.R)
# 纯计算; 富集依赖 (clusterProfiler/org.Xx.eg.db) 运行时检查, 缺失时优雅跳过并给出安装提示。
# KEGG 数据源两种模式 (v1.14 移植调整):
#   kegg_online = FALSE (默认): 本地 KEGG.db — 与原 CLI 版一致; KEGG.db 已被
#     Bioconductor 移除, 需从 archive 安装, 无该包时降级为跳过并提示;
#   kegg_online = TRUE: clusterProfiler::enrichKEGG 走 KEGG REST (需联网),
#     支持物种更全 (含斑马鱼 dre), 供无 KEGG.db 的现代环境选用。
# ============================================================

map_symbol2entrez <- function(symbols, OrgDb) {
  sym <- unique(symbols[!is.na(symbols) & symbols != "" & symbols != "NA"])
  sym <- unique(sub(";.*$", "", sym))
  if (length(sym) == 0) return(NULL)
  res <- AnnotationDbi::select(OrgDb, keys = sym, keytype = "SYMBOL",
                               columns = "ENTREZID")
  res[!is.na(res$ENTREZID), , drop = FALSE]
}

# ---- 本地 KEGG: 自建 TERM2GENE (走 KEGG.db, 不联网) ----
# 不用 enrichKEGG(use_internal_data=TRUE): 后者会拼出 hsahsa01100 -> 通路名全 NA;
# 这里按纯编号对齐名称, 并缓存映射表
kegg_local_cache <- new.env(parent = emptyenv())

kegg_local_data <- function(species) {
  if (!is.null(kegg_local_cache[[species]])) return(kegg_local_cache[[species]])
  has_db <- suppressPackageStartupMessages(requireNamespace("KEGG.db", quietly = TRUE))
  if (!has_db)
    stop("未安装 KEGG.db 包 (Bioconductor 已移除, 需从 archive 安装), 本地 KEGG 分析不可用; ",
         "可在富集参数中改用「在线 KEGG (需联网)」")
  p2e <- as.list(KEGG.db::KEGGPATHID2EXTID)          # 键形如 hsa01100 -> Entrez 向量
  ok  <- grepl(paste0("^", species, "[0-9]+$"), names(p2e))
  if (!any(ok)) stop(sprintf("KEGG.db 内不含物种 %s 的通路数据", species))
  p2e <- p2e[ok]
  ids <- names(p2e)
  p2n    <- as.list(KEGG.db::KEGGPATHID2NAME)
  nm_map <- stats::setNames(unlist(p2n, use.names = FALSE), sub("^[a-z]{3}", "", names(p2n)))
  nm     <- unname(nm_map[sub("^[a-z]{3}", "", ids)])
  nm[is.na(nm) | !nzchar(nm)] <- ids[is.na(nm) | !nzchar(nm)]   # 缺名字时退回通路 ID, 避免 NA
  res <- list(
    term2gene = data.frame(term = rep(ids, lengths(p2e)),
                           gene = as.character(unlist(p2e, use.names = FALSE)),
                           stringsAsFactors = FALSE),
    term2name = data.frame(term = ids, name = nm, stringsAsFactors = FALSE))
  kegg_local_cache[[species]] <- res
  res
}

# KEGG 富集入口: 按数据源模式分发; 返回 enrichResult 或 NULL (err 经 add_warning 上报)
kegg_enrich_run <- function(sig_entrez, universe, prep, pval_cutoff, qval_cutoff,
                            p_adjust_method, min_gssize, max_gssize,
                            online, add_warning) {
  run_local <- function() {
    kd  <- kegg_local_data(prep$kegg_org)
    res <- clusterProfiler::enricher(
      gene = sig_entrez$ENTREZID, TERM2GENE = kd$term2gene, TERM2NAME = kd$term2name,
      pvalueCutoff = pval_cutoff, qvalueCutoff = qval_cutoff,
      pAdjustMethod = p_adjust_method,
      minGSSize = min_gssize, maxGSSize = max_gssize)
    if (!is.null(res))
      try({ res@ontology <- "KEGG"; res@organism <- prep$kegg_org; res@keytype <- "kegg" },
          silent = TRUE)
    res
  }
  run_online <- function() {
    res <- clusterProfiler::enrichKEGG(
      gene = sig_entrez$ENTREZID, universe = universe,
      organism = prep$kegg_org, keyType = "kegg",
      pvalueCutoff = pval_cutoff, qvalueCutoff = qval_cutoff,
      pAdjustMethod = p_adjust_method,
      minGSSize = min_gssize, maxGSSize = max_gssize)
    if (!is.null(res))
      try({ res@ontology <- "KEGG"; res@keytype <- "kegg" }, silent = TRUE)
    res
  }
  tryCatch(
    if (isTRUE(online)) run_online() else run_local(),
    error = function(e) {
      add_warning(sprintf("KEGG 富集失败（%s）: %s",
                          if (isTRUE(online)) "在线 KEGG, 需联网" else "本地 KEGG.db",
                          conditionMessage(e)))
      NULL
    })
}

enrich_compute <- function(prep, de, pval_cutoff = 0.05, qval_cutoff = 0.2,
                           p_adjust_method = "BH", min_sig = 5, ont = c("BP", "MF", "CC"),
                           use_kegg = TRUE, kegg_online = FALSE,
                           min_gssize = 3, max_gssize = 500,
                           go_top_n = 10, kegg_top_n = 15) {
  if (is.null(prep) || is.null(de)) return(NULL)
  warnings <- character(0)
  add_warning <- function(m) warnings <<- c(warnings, m)

  # 只保留 BH; "none" = 未校正 (按原始 p 值筛选)
  p_adjust_method <- as.character(p_adjust_method %||% "BH")
  if (!p_adjust_method %in% c("BH", "none")) p_adjust_method <- "BH"
  if (identical(p_adjust_method, "none")) {
    add_warning("P 值未校正：按原始 p 值筛选，qvalue 阈值不参与")
    qval_cutoff <- 1          # 未校正时不再用 q 值做二次过滤
  }

  skip_result <- function(reason) list(
    skipped = TRUE, reason = reason, warnings = warnings, plots = list(), tables = list())

  annot <- prep$annot
  sig   <- de$sig

  # ---- 前置检查 ----
  if (nrow(sig) < min_sig) {
    add_warning(sprintf("显著差异蛋白 < %d（当前 %d 个），跳过功能富集", min_sig, nrow(sig)))
    return(skip_result(sprintf(
      "当前显著差异蛋白仅 %d 个（少于富集分析所需的最小数量 %d），未执行 GO/KEGG 富集。",
      nrow(sig), min_sig)))
  }

  # ---- 依赖检查 (不自动安装; 缺失 -> 优雅跳过 + 安装提示) ----
  org_pkg <- prep$org_pkg
  need_pkgs <- c("clusterProfiler", "AnnotationDbi", org_pkg)
  miss <- need_pkgs[!vapply(need_pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(miss)) {
    add_warning(paste0("缺少富集依赖包: ", paste(miss, collapse = ", ")))
    return(skip_result(paste0(
      "缺少富集依赖包: ", paste(miss, collapse = ", "),
      "。请在 R 中执行 BiocManager::install(c(\"", paste(miss, collapse = "\", \""),
      "\")) 后重试。")))
  }
  if (isTRUE(use_kegg) && !isTRUE(kegg_online) &&
      !requireNamespace("KEGG.db", quietly = TRUE)) {
    add_warning("未安装 KEGG.db (Bioconductor 已移除), 本次 KEGG 富集跳过; ",
                "可在富集参数中启用「在线 KEGG (需联网)」")
    use_kegg <- FALSE
  }
  local_dre_no_path <- isTRUE(use_kegg) && !isTRUE(kegg_online) &&
    identical(prep$kegg_org, "dre")
  if (local_dre_no_path)
    add_warning("本地 KEGG.db 不含斑马鱼（dre）通路，斑马鱼仅支持 GO 富集（或改用在线 KEGG）")

  OrgDb <- tryCatch(getExportedValue(org_pkg, org_pkg), error = function(e) NULL)
  if (is.null(OrgDb)) {
    add_warning(sprintf("注释库 %s 不可用，跳过功能富集", org_pkg))
    return(skip_result(sprintf("注释库 %s 不可用。", org_pkg)))
  }

  entrez <- tryCatch(map_symbol2entrez(annot$Genes, OrgDb),
                     error = function(e) {
                       add_warning(paste("背景基因 ID 转换失败:", conditionMessage(e))); NULL })
  if (is.null(entrez) || nrow(entrez) == 0) {
    add_warning("背景基因 ID 转换失败，跳过功能富集")
    return(skip_result("背景基因无法映射到 ENTREZID。"))
  }

  sig_genes  <- unique(sub(";.*$", "", sig$Genes))
  sig_entrez <- tryCatch(map_symbol2entrez(sig_genes, OrgDb),
                         error = function(e) {
                           add_warning(paste("差异基因 ID 转换失败:", conditionMessage(e))); NULL })
  if (is.null(sig_entrez) || nrow(sig_entrez) < 3) {
    add_warning("显著差异基因映射后不足 3 个，跳过功能富集")
    return(skip_result("显著差异基因映射到 ENTREZID 后不足 3 个。"))
  }

  universe <- unique(entrez$ENTREZID)
  enrich_list <- list()

  # ---- GO ----
  for (o in intersect(ont, c("BP", "MF", "CC"))) {
    go_res <- tryCatch(
      clusterProfiler::enrichGO(gene = sig_entrez$ENTREZID, universe = universe,
                                OrgDb = OrgDb, keyType = "ENTREZID", ont = o,
                                pAdjustMethod = p_adjust_method, pvalueCutoff = pval_cutoff,
                                qvalueCutoff = qval_cutoff, readable = FALSE,
                                minGSSize = min_gssize, maxGSSize = max_gssize),
      error = function(e) {
        add_warning(sprintf("GO-%s 富集失败: %s", o, conditionMessage(e))); NULL })
    if (!is.null(go_res) && nrow(as.data.frame(go_res)) > 0) {
      enrich_list[[paste0("GO_", o)]] <- go_res
    } else {
      add_warning(sprintf("GO-%s: 无显著富集结果", o))
    }
  }

  # ---- KEGG ----
  kegg_res <- NULL
  if (isTRUE(use_kegg)) {
    kegg_res <- kegg_enrich_run(sig_entrez, universe, prep, pval_cutoff, qval_cutoff,
                                p_adjust_method, min_gssize, max_gssize,
                                online = isTRUE(kegg_online), add_warning = add_warning)
    if (!is.null(kegg_res) && nrow(as.data.frame(kegg_res)) > 0) {
      enrich_list[["KEGG"]] <- kegg_res
    } else if (is.null(kegg_res)) {
      # 失败原因已由 kegg_enrich_run 写入 warnings
    } else {
      add_warning("KEGG: 无显著富集结果")
    }
  }

  # ---- 合并表 ----
  enrich_tab <- NULL
  if (length(enrich_list) > 0) {
    enrich_tab <- do.call(rbind, lapply(names(enrich_list), function(nm) {
      d <- as.data.frame(enrich_list[[nm]])
      d$Source <- nm
      d[, c("Source", "ID", "Description", "GeneRatio", "BgRatio",
            "pvalue", "p.adjust", "qvalue", "Count")]
    }))
  }

  # ---- 图形 ----
  plots <- list()
  go_res_plot <- enrich_list[grepl("^GO_", names(enrich_list))]
  for (nm in names(go_res_plot)) {
    d <- as.data.frame(go_res_plot[[nm]])
    d$Description <- factor(d$Description, levels = rev(d$Description[order(d$Count)]))
    d$Label <- paste0(d$Description, " (n=", d$Count, ")")
    d$Label <- factor(d$Label, levels = d$Label[order(d$Count)])
    onto <- sub("^GO_", "", nm)
    stem <- paste0("13_enrichment_go_barplot_", tolower(onto))
    plots[[stem]] <- new_plot(local({
      # 绘图闭包延迟执行: 必须先把 onto 捕获进 local, 否则标题全变成最后一个本体
      dd   <- d
      onto <- onto
      topn <- go_top_n
      function() ggplot2::ggplot(utils::head(dd, topn),
                                 ggplot2::aes(x = Label, y = Count, fill = -log10(p.adjust))) +
        ggplot2::geom_col(width = 0.7, colour = "grey25", linewidth = 0.25) +
        ggplot2::coord_flip() +
        ggplot2::scale_fill_gradient(low = "#3B6FB5", high = "#D9534F", name = "-log10(adj.P)") +
        ggplot2::labs(title = sprintf("GO enrichment - %s (top %d)", onto, topn),
                      x = NULL, y = "Gene count") +
        theme_proteo() + ggplot2::theme(axis.text.y = ggplot2::element_text(size = 9))
    }), kind = "ggplot", width = 9, height = 6,
      label = sprintf("GO-%s 富集条形图", onto))
  }

  if (length(go_res_plot) > 0) {
    go_all <- do.call(rbind, lapply(names(go_res_plot), function(nm) {
      d <- as.data.frame(go_res_plot[[nm]])
      d$Ontology <- sub("^GO_", "", nm)
      d <- utils::head(d[order(d$p.adjust), ], 5)
      d[, c("Ontology", "Description", "GeneRatio", "Count", "p.adjust")]
    }))
    go_all$GeneRatioN <- vapply(strsplit(as.character(go_all$GeneRatio), "/"),
                                function(x) as.numeric(x[1]) / as.numeric(x[2]), numeric(1))
    go_all$Description <- factor(go_all$Description,
                                 levels = go_all$Description[order(go_all$Ontology, -go_all$GeneRatioN)])
    plots[["14_enrichment_go_dotplot"]] <- new_plot(local({
      dd <- go_all
      function() ggplot2::ggplot(dd, ggplot2::aes(x = GeneRatioN, y = Description,
                                                  size = Count, colour = p.adjust)) +
        ggplot2::geom_point(alpha = 0.85) +
        ggplot2::scale_colour_gradient(low = "#D9534F", high = "#3B6FB5", trans = "log10",
                                       name = "adjusted P") +
        ggplot2::scale_size_continuous(range = c(3, 9), name = "Gene count") +
        ggplot2::facet_grid(Ontology ~ ., scales = "free_y", space = "free_y") +
        ggplot2::labs(title = "GO enrichment (top 5 per ontology)", x = "Gene ratio", y = NULL) +
        theme_proteo() +
        ggplot2::theme(axis.text.y = ggplot2::element_text(size = 8.5),
                       strip.text.y = ggplot2::element_text(face = "bold"))
    }), kind = "ggplot", width = 9.5, height = 8, label = "GO 富集气泡图")
  }

  if ("KEGG" %in% names(enrich_list)) {
    d <- as.data.frame(enrich_list[["KEGG"]])
    d <- utils::head(d[order(d$p.adjust), ], kegg_top_n)
    d$GeneRatioN <- vapply(strsplit(as.character(d$GeneRatio), "/"),
                           function(x) as.numeric(x[1]) / as.numeric(x[2]), numeric(1))
    d$Description <- factor(d$Description, levels = rev(d$Description[order(d$Count)]))
    plots[["15_enrichment_kegg_dotplot"]] <- new_plot(local({
      dd  <- d
      org <- prep$kegg_org
      function() ggplot2::ggplot(dd, ggplot2::aes(x = GeneRatioN, y = Description,
                                                  size = Count, colour = p.adjust)) +
        ggplot2::geom_point(alpha = 0.85) +
        ggplot2::scale_colour_gradient(low = "#D9534F", high = "#3B6FB5", trans = "log10",
                                       name = "adjusted P") +
        ggplot2::scale_size_continuous(range = c(3, 8), name = "Gene count") +
        ggplot2::labs(title = sprintf("KEGG pathway enrichment (%s)", org),
                      x = "Gene ratio", y = NULL) +
        theme_proteo() + ggplot2::theme(axis.text.y = ggplot2::element_text(size = 9))
    }), kind = "ggplot", width = 9.5, height = 7, label = "KEGG 通路富集气泡图")
  }

  if (length(enrich_list) == 0) add_warning("无功能富集结果，未输出富集图表")

  # 富集表拆分 (报告 iframe 用)
  tables <- list()
  if (!is.null(enrich_tab)) {
    tables$all  <- enrich_tab
    tables$go   <- enrich_tab[grepl("^GO_", enrich_tab$Source), , drop = FALSE]
    tables$kegg <- enrich_tab[enrich_tab$Source == "KEGG", , drop = FALSE]
  }

  list(
    skipped = FALSE, org_pkg = org_pkg, kegg_org = prep$kegg_org,
    kegg_source = if (isTRUE(kegg_online)) "online" else "local",
    n_sig = nrow(sig), n_sig_mapped = nrow(sig_entrez), n_bg = nrow(entrez),
    sources = names(enrich_list), tables = tables, plots = plots,
    pval_cutoff = pval_cutoff, qval_cutoff = qval_cutoff,
    p_adjust_method = p_adjust_method, ont = ont, use_kegg = isTRUE(use_kegg),
    warnings = warnings
  )
}

# 批量落盘: 富集合并表 + 图形
enrich_save_all <- function(en, out_dir) {
  if (is.null(en) || isTRUE(en$skipped)) return(character(0))
  files <- character(0)
  if (!is.null(en$tables$all)) {
    f <- file.path(out_dir, "06_enrichment_go_kegg.csv")
    utils::write.csv(en$tables$all, f, row.names = FALSE)
    files <- c(files, f)
  }
  for (nm in names(en$plots)) {
    pl <- en$plots[[nm]]
    files <- c(files, save_plot_obj(pl, out_dir, nm, width = pl$width, height = pl$height))
  }
  files
}
