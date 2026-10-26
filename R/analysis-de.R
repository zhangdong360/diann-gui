# ============================================================
# analysis-de.R — 结果分析·limma 差异分析核心 (移植自 mass_analysis/core_de.R)
# single 模式: 1 个对比; multi 模式 (>=3 组): 全局 F + 全部两两对比
# ============================================================

# 对比标签: 文件名安全化
safe_tag <- function(g) gsub("[^A-Za-z0-9._-]", "_", g)

de_stem <- function(base, tag) {
  if (!nzchar(tag)) return(base)
  if (grepl("\\.(csv|xlsx|tsv)$", base))
    return(sub("(\\.(csv|xlsx|tsv))$", paste0("_", tag, "\\1"), base))
  paste0(base, "_", tag)
}

# 组名 -> limma 合法变量名 (仅内部): makeContrasts 会 parse 对比串,
# 数字开头/含空格等的组名会报错; 判据同 make.names(x)==x, 不合法换 g1/g2/…
de_safe_levels <- function(levels) {
  levels <- as.character(levels)
  ok <- !is.na(levels) & nzchar(levels) & make.names(levels) == levels
  out <- levels
  if (any(!ok)) out[!ok] <- paste0("g", which(!ok))
  make.unique(out)
}

de_compute <- function(prep, logFC_cutoff = 1, pval_cutoff = 0.05,
                       top_n_label = 12, top_n_boxplot = 9,
                       p_adjust_method = "BH", heatmap_max = 200, heatmap_show_rownames = 60,
                       multi_group = "auto") {
  if (is.null(prep)) return(NULL)
  warnings <- character(0)
  add_warning <- function(m) warnings <<- c(warnings, m)

  p <- prep
  expr_imp <- p$expr_imp
  annot    <- p$annot
  groups   <- p$groups
  group_levels <- p$group_levels
  n_groups <- p$n_groups
  grp_col  <- p$grp_col
  snames   <- p$snames

  # ---- 模式判定 ----
  mode <- if (identical(multi_group, "auto")) {
    ifelse(n_groups >= 3, "multi", "single")
  } else if (isTRUE(multi_group)) "multi" else "single"
  if (mode == "single" && n_groups > 2) mode <- "multi"   # 单对比模式仅适用 2 组

  # ---- 设计矩阵与拟合 (列名必须合法; 展示仍用原始组名) ----
  safe_lv <- stats::setNames(de_safe_levels(group_levels), as.character(group_levels))
  control_grp  <- p$control_grp %in% group_levels && mode == "single"
  if (mode == "single") {
    # 对照组可由用户指定: 对比始终为 非对照 vs 对照
    trt  <- setdiff(group_levels, p$control_grp)[1]
    ctrl <- p$control_grp
    ordered_levels <- c(ctrl, trt)
    design <- stats::model.matrix(~ 0 + factor(groups, levels = ordered_levels))
    colnames(design) <- unname(safe_lv[ordered_levels])
  } else {
    design <- stats::model.matrix(~ 0 + factor(groups, levels = group_levels))
    colnames(design) <- unname(safe_lv[group_levels])
  }
  fit0 <- limma::lmFit(expr_imp, design)

  # ---- 对比清单 ----
  if (mode == "single") {
    pair_list <- list(c(trt = group_levels[group_levels != p$control_grp][1], ctrl = p$control_grp))
  } else {
    comb <- utils::combn(group_levels, 2)
    pair_list <- lapply(seq_len(ncol(comb)), function(k) c(trt = comb[2, k], ctrl = comb[1, k]))
  }

  # ---- 单对比: 差异统计 + 可视化对象 ----
  run_pair_de <- function(trt, ctrl, tag) {
    cnt  <- limma::makeContrasts(contrasts = sprintf("%s-%s", safe_lv[[trt]], safe_lv[[ctrl]]),
                                 levels = design)
    fit2 <- limma::contrasts.fit(fit0, cnt)
    fit3 <- limma::eBayes(fit2)
    # adjust.method 必须显式传入, 否则 topTable 恒用默认 BH, 界面换方法不会生效
    res  <- limma::topTable(fit3, number = Inf, sort.by = "none",
                            adjust.method = p_adjust_method)
    res$Protein.Group <- rownames(res)
    res$Genes         <- annot$Genes
    res$Protein.Names <- annot$Protein.Names
    res$Description   <- annot$First.Protein.Description
    res$Significant   <- ifelse(is.na(res$adj.P.Val), FALSE,
                                abs(res$logFC) > logFC_cutoff & res$adj.P.Val < pval_cutoff)
    res <- res[, c("Protein.Group", "Genes", "Protein.Names", "Description",
                   "logFC", "AveExpr", "t", "P.Value", "adj.P.Val", "Significant")]
    sig <- res[res$Significant, , drop = FALSE]
    sig_up   <- sum(res$logFC > 0 & res$Significant, na.rm = TRUE)
    sig_down <- sum(res$logFC < 0 & res$Significant, na.rm = TRUE)
    if (nrow(sig) == 0)
      add_warning(sprintf("对比 %s vs %s: 未检出显著差异蛋白", trt, ctrl))

    plots <- list()

    # 火山图
    vol_df <- res[is.finite(res$logFC) & is.finite(res$adj.P.Val), ]
    vol_df$Type <- ifelse(abs(vol_df$logFC) > logFC_cutoff & vol_df$adj.P.Val < pval_cutoff,
                          ifelse(vol_df$logFC > 0, "Up", "Down"), "NS")
    vol_df$Type <- factor(vol_df$Type, levels = c("Up", "Down", "NS"))
    top_genes <- vol_df[order(-abs(vol_df$logFC))[seq_len(min(top_n_label, nrow(vol_df)))], ]
    p_lab  <- if (identical(p_adjust_method, "none")) "P" else "adj.P"
    y_lab  <- if (identical(p_adjust_method, "none")) "-log10(P value)" else "-log10(adjusted P value)"
    plots[["09_diff_volcano"]] <- new_plot(function() {
      ggplot2::ggplot(vol_df, ggplot2::aes(x = logFC, y = -log10(adj.P.Val), colour = Type)) +
        ggplot2::geom_point(size = 1.6, alpha = 0.7) +
        ggplot2::geom_hline(yintercept = -log10(pval_cutoff), linetype = "dashed", colour = "grey40") +
        ggplot2::geom_vline(xintercept = c(-logFC_cutoff, logFC_cutoff), linetype = "dashed",
                            colour = "grey40") +
        ggrepel::geom_text_repel(data = top_genes, ggplot2::aes(label = Genes), size = 3,
                                 max.overlaps = 30, colour = "grey20", segment.colour = "grey50") +
        ggplot2::scale_colour_manual(values = PAL_UPDN, name = "Regulation",
                                     labels = c("Up", "Down", "NS")) +
        ggplot2::labs(title = sprintf("Volcano plot (%s vs %s)", trt, ctrl),
                      subtitle = sprintf("|log2FC| > %.1f & %s < %.3f: Up=%d, Down=%d",
                                         logFC_cutoff, p_lab, pval_cutoff, sig_up, sig_down),
                      x = "log2 fold change", y = y_lab) +
        theme_proteo()
    }, kind = "ggplot", width = 8.5, height = 7, label = "差异蛋白火山图")

    # 差异蛋白热图 (Z-score, |logFC| 前 heatmap_max)
    if (nrow(sig) > 0) {
      hm_prots <- rownames(sig)[order(-abs(sig$logFC))]
      if (length(hm_prots) > heatmap_max) {
        hm_prots <- hm_prots[seq_len(heatmap_max)]
        add_warning(sprintf("对比 %s vs %s: 差异蛋白超过 %d 个, 热图仅展示 |logFC| 最大的 %d 个",
                            trt, ctrl, heatmap_max, heatmap_max))
      }
      hm_mat <- expr_imp[hm_prots, , drop = FALSE]
      hm_mat <- t(scale(t(hm_mat)))
      hm_mat[is.nan(hm_mat)] <- 0
      rownames(hm_mat) <- ifelse(is.na(sig[hm_prots, "Genes"]) | sig[hm_prots, "Genes"] == "",
                                 hm_prots, sig[hm_prots, "Genes"])
      lay <- hm_layout(length(hm_prots))
      zlim <- max(abs(hm_mat), na.rm = TRUE) * 0.99
      if (!is.finite(zlim) || zlim == 0) zlim <- 1
      plots[["10_diff_heatmap"]] <- new_plot(function() {
        pheatmap::pheatmap(hm_mat, scale = "none",
                           cluster_rows = nrow(hm_mat) > 1, cluster_cols = ncol(hm_mat) > 1,
                           show_rownames = (length(hm_prots) <= heatmap_show_rownames), show_colnames = TRUE,
                           annotation_col = data.frame(Group = factor(groups), row.names = snames),
                           annotation_colors = list(Group = grp_col),
                           color = grDevices::colorRampPalette(c("#3B6FB5", "white", "#D9534F"))(100),
                           breaks = seq(-zlim, zlim, length.out = 101),
                           fontsize = 10.5, border_color = NA,
                           main = sprintf("Differential proteins (%s vs %s, %d) - Z-score",
                                          trt, ctrl, length(hm_prots)),
                           cellheight = lay$cell)
      }, kind = "grid", width = 8, height = lay$height, label = "差异蛋白 Z-score 热图")
    }

    # 数量柱状图
    cnt_df <- data.frame(Regulation = factor(c("Up", "Down", "NS"), levels = c("Up", "Down", "NS")),
                         Count = c(sig_up, sig_down, nrow(res) - nrow(sig)))
    plots[["11_diff_count_barplot"]] <- new_plot(function() {
      ggplot2::ggplot(cnt_df, ggplot2::aes(x = Regulation, y = Count, fill = Regulation)) +
        ggplot2::geom_col(width = 0.55, colour = "grey25", linewidth = 0.3) +
        ggplot2::geom_text(ggplot2::aes(label = Count), vjust = -0.4, size = 5, fontface = "bold") +
        ggplot2::scale_fill_manual(values = PAL_UPDN) +
        ggplot2::labs(title = sprintf("Number of differential proteins (%s vs %s)", trt, ctrl),
                      x = "Regulation", y = "# Proteins") +
        theme_proteo() + ggplot2::theme(legend.position = "none")
    }, kind = "ggplot", width = 6, height = 5.5, label = "上/下调蛋白数量统计")

    # 关键蛋白箱线图
    if (nrow(sig) > 0) {
      top_prots <- rownames(sig)[order(-abs(sig$logFC))[seq_len(min(top_n_boxplot, nrow(sig)))]]
      box_df <- do.call(rbind, lapply(top_prots, function(pr) {
        data.frame(Protein = ifelse(is.na(sig[pr, "Genes"]) | sig[pr, "Genes"] == "",
                                    pr, sig[pr, "Genes"]),
                   Group = groups, Sample = snames,
                   log2Intensity = as.numeric(expr_imp[pr, ]))
      }))
      box_df$Protein <- factor(box_df$Protein, levels = unique(box_df$Protein))
      plots[["12_diff_top_protein_boxplot"]] <- new_plot(function() {
        ggplot2::ggplot(box_df, ggplot2::aes(x = Group, y = log2Intensity, fill = Group)) +
          ggplot2::geom_boxplot(width = 0.55, outlier.shape = NA, linewidth = 0.4) +
          ggplot2::geom_jitter(width = 0.12, size = 1.6, alpha = 0.75, colour = "grey25") +
          ggplot2::facet_wrap(~ Protein, ncol = 3, scales = "free_y") +
          ggplot2::scale_fill_manual(values = grp_col) +
          ggplot2::labs(title = sprintf("Top differential proteins (%s vs %s)", trt, ctrl),
                        x = "Group", y = "log2 intensity (normalized, imputed)") +
          theme_proteo() +
          ggplot2::theme(legend.position = "none",
                         strip.text = ggplot2::element_text(size = 9.5))
      }, kind = "ggplot", width = 10,
        height = 3.4 * ceiling(length(top_prots) / 3),
        label = "关键差异蛋白表达箱线图")
    }

    list(res = res, sig = sig, sig_up = sig_up, sig_down = sig_down,
         contrast = sprintf("%s vs %s", trt, ctrl), trt = trt, ctrl = ctrl, tag = tag,
         plots = plots, n_up = sig_up, n_down = sig_down)
  }

  # ---- multi 模式: 全局 F 检验 ----
  anova <- NULL
  if (mode == "multi") {
    ref    <- group_levels[1]
    others <- setdiff(group_levels, ref)
    anova_contrasts <- vapply(others, function(g) sprintf("%s-%s", safe_lv[[g]], safe_lv[[ref]]),
                              character(1))
    cnt_anova <- limma::makeContrasts(contrasts = anova_contrasts, levels = design)
    fit_anova <- limma::eBayes(limma::contrasts.fit(fit0, cnt_anova))
    anova_res <- data.frame(
      Protein.Group = rownames(fit_anova),
      F             = fit_anova$F,
      P.Value       = fit_anova$F.p.value)
    anova_res$adj.P.Val   <- stats::p.adjust(anova_res$P.Value, method = p_adjust_method)
    anova_res$Significant <- !is.na(anova_res$adj.P.Val) & anova_res$adj.P.Val < pval_cutoff
    anova_res$Genes         <- annot$Genes
    anova_res$Protein.Names <- annot$Protein.Names
    anova_res$Description   <- annot$First.Protein.Description
    anova_res <- anova_res[order(anova_res$P.Value), ]
    anova_sig <- anova_res[anova_res$Significant, , drop = FALSE]
    if (nrow(anova_sig) == 0)
      add_warning("多组全局 F 检验未检出显著蛋白 (所有组间均无差异)")

    anova <- list(res = anova_res, sig = anova_sig, ref = ref, plots = list())

    # 全局显著蛋白热图 (F 降序前 100)
    if (nrow(anova_sig) > 0) {
      hm_prots <- anova_sig$Protein.Group[order(-anova_sig$F)]
      hm_prots <- hm_prots[seq_len(min(100, length(hm_prots)))]
      hm_mat <- expr_imp[hm_prots, , drop = FALSE]
      hm_mat <- t(scale(t(hm_mat)))
      hm_mat[is.nan(hm_mat)] <- 0
      # 行标签: 建以 Protein.Group 命名的向量再取值 (ifelse 会丢 names)
      gmap <- stats::setNames(
        ifelse(is.na(annot$Genes) | annot$Genes == "", annot$Protein.Group, annot$Genes),
        annot$Protein.Group)
      rownames(hm_mat) <- unname(gmap[hm_prots])
      zlim <- max(abs(hm_mat), na.rm = TRUE) * 0.99
      if (!is.finite(zlim) || zlim == 0) zlim <- 1
      lay <- hm_layout(length(hm_prots))
      anova$plots[["10_multigroup_anova_heatmap"]] <- new_plot(function() {
        pheatmap::pheatmap(hm_mat, scale = "none",
                           cluster_rows = nrow(hm_mat) > 1, cluster_cols = ncol(hm_mat) > 1,
                           show_rownames = (length(hm_prots) <= heatmap_show_rownames), show_colnames = TRUE,
                           annotation_col = data.frame(Group = factor(groups), row.names = snames),
                           annotation_colors = list(Group = grp_col),
                           color = grDevices::colorRampPalette(c("#3B6FB5", "white", "#D9534F"))(100),
                           breaks = seq(-zlim, zlim, length.out = 101),
                           fontsize = 10.5, border_color = NA,
                           main = sprintf("Global differential proteins across %d groups (F-test, %d) - Z-score",
                                          n_groups, length(hm_prots)),
                           cellheight = lay$cell)
      }, kind = "grid", width = 8, height = lay$height,
        label = "全局显著差异蛋白热图")
    }
  }

  # ---- 执行全部对比 ----
  pairs <- vector("list", length(pair_list))
  for (k in seq_along(pair_list)) {
    trt  <- pair_list[[k]][["trt"]]
    ctrl <- pair_list[[k]][["ctrl"]]
    tag  <- if (mode == "multi") paste0(safe_tag(trt), "_vs_", safe_tag(ctrl)) else ""
    pairs[[k]] <- run_pair_de(trt, ctrl, tag)
    names(pairs)[k] <- if (nzchar(tag)) tag else "single"
  }

  # ---- 各对比显著蛋白汇总 ----
  pair_stat <- do.call(rbind, lapply(pairs, function(x)
    data.frame(Contrast = x$contrast, FileTag = x$tag,
               n_significant = nrow(x$sig), n_up = x$sig_up, n_down = x$sig_down,
               stringsAsFactors = FALSE)))

  # 供富集使用的显著蛋白集: single = 该对比; multi = 全部对比并集
  if (mode == "single") {
    sig <- pairs[[1]]$sig
    sig_up   <- pairs[[1]]$sig_up
    sig_down <- pairs[[1]]$sig_down
  } else {
    sig <- do.call(rbind, lapply(pairs, function(x) x$sig))
    if (nrow(sig) > 0) sig <- sig[!duplicated(sig$Protein.Group), ]
    sig_up <- sig_down <- NA_integer_
  }
  if (nrow(sig) == 0)
    add_warning("未检出任何显著差异蛋白, 后续热图/富集将跳过或降级")

  list(
    mode = mode, design = design, pairs = pairs, pair_stat = pair_stat, anova = anova,
    sig = sig, sig_up = sig_up, sig_down = sig_down,
    logFC_cutoff = logFC_cutoff, pval_cutoff = pval_cutoff,
    p_adjust_method = p_adjust_method, heatmap_max = heatmap_max,
    top_n_label = top_n_label, top_n_boxplot = top_n_boxplot,
    warnings = warnings
  )
}

# 批量落盘 (报告生成时调用): 表格 (csv/xlsx) + 图形
de_save_all <- function(de, out_dir) {
  if (is.null(de)) return(character(0))
  files <- character(0)
  for (pt in de$pairs) {
    tag <- pt$tag
    f1 <- file.path(out_dir, de_stem("04_de_limma_results_all.csv", tag))
    f2 <- file.path(out_dir, de_stem("05_de_significant_proteins.csv", tag))
    f3 <- file.path(out_dir, de_stem("04_05_de_limma_results.xlsx", tag))
    utils::write.csv(pt$res, f1, row.names = FALSE)
    utils::write.csv(pt$sig, f2, row.names = FALSE)
    wb <- openxlsx::createWorkbook()
    openxlsx::addWorksheet(wb, "All results"); openxlsx::writeData(wb, 1, pt$res)
    openxlsx::addWorksheet(wb, "Significant"); openxlsx::writeData(wb, 2, pt$sig)
    openxlsx::saveWorkbook(wb, f3, overwrite = TRUE)
    files <- c(files, f1, f2, f3)
    # 图形
    for (nm in names(pt$plots)) {
      pl <- pt$plots[[nm]]
      files <- c(files, save_plot_obj(pl, out_dir, de_stem(nm, tag),
                                      width = pl$width, height = pl$height))
    }
  }
  if (!is.null(de$anova)) {
    f1 <- file.path(out_dir, "06_multigroup_anova_results.csv")
    f2 <- file.path(out_dir, "06_multigroup_anova_significant.csv")
    utils::write.csv(de$anova$res, f1, row.names = FALSE)
    utils::write.csv(de$anova$sig, f2, row.names = FALSE)
    files <- c(files, f1, f2)
    for (nm in names(de$anova$plots)) {
      pl <- de$anova$plots[[nm]]
      files <- c(files, save_plot_obj(pl, out_dir, nm, width = pl$width, height = pl$height))
    }
    f3 <- file.path(out_dir, "07_pairwise_contrast_summary.csv")
    utils::write.csv(de$pair_stat, f3, row.names = FALSE)
    files <- c(files, f3)
  }
  unique(files)
}
