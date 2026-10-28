# ============================================================
# analysis-qc.R — 结果分析·QC 可视化核心 (移植自 mass_analysis/core_qc.R)
# 纯计算: 返回 list(plots, stats, warnings), 不做 I/O
# ============================================================

# 中位数归一化前后箱线图 (预处理页签与 QC 共用)
median_norm_boxplot <- function(p) {
  # aes 数据掩码裸名声明 (R CMD check 消 NOTE)
  Group <- Sample <- Value <- NULL
  before <- as.matrix(p$expr_imp_raw %||% p$expr_imp)
  after  <- as.matrix(p$expr_imp)
  sn <- p$snames; grp <- p$groups; tgt <- p$median_target
  ax <- sample_axis_style(length(sn))
  rng <- range(c(before, after), na.rm = TRUE)
  one <- function(m, ttl) {
    # aes 数据掩码裸名声明 (R CMD check 消 NOTE; 渲染时掩码列照常遮蔽)
    Group <- Sample <- Value <- NULL
    d <- data.frame(Sample = factor(rep(sn, each = nrow(m)), levels = sn),
                    Group  = rep(grp, each = nrow(m)),
                    Value  = as.numeric(m))
    ggplot2::ggplot(d, ggplot2::aes(x = Sample, y = Value, fill = Group)) +
      ggplot2::geom_boxplot(width = 0.7, linewidth = 0.25, outlier.size = 0.3) +
      ggplot2::geom_hline(yintercept = tgt, linetype = "dashed",
                          colour = "grey35", linewidth = 0.35) +
      ggplot2::scale_fill_manual(values = p$grp_col) +
      ggplot2::coord_cartesian(ylim = rng) +
      ggplot2::labs(title = ttl, x = NULL, y = "log2 intensity") +
      theme_proteo() +
      ggplot2::theme(axis.text.x = ggplot2::element_text(
        angle = ax$angle, hjust = ax$hjust, size = ax$text_sz))
  }
  new_plot(function() {
    g1 <- one(before, "Before median normalization")
    g2 <- one(after, sprintf("After median normalization (target %.2f)", tgt))
    gridExtra::grid.arrange(g1, g2, ncol = 2)
  }, kind = "grid", width = ax$width + 1, height = 5.5,
    label = "中位数归一化前后对比箱线图")
}

# 缺失值分布概况 (辅助判断 MAR / MNAR): A 平均丰度 vs 缺失率, B 不同缺失率分箱的丰度分布
# 输入取 expr_norm (log2、插补前、保留 NA), 丰度均为 log2 尺度
missing_profile_plots <- function(p) {
  # aes 数据掩码裸名声明 (R CMD check 消 NOTE)
  Abundance <- Bin <- MissingRate <- NULL
  m <- as.matrix(p$expr_norm)
  if (!nrow(m) || !ncol(m)) return(NULL)
  rate  <- rowMeans(is.na(m))
  abund <- rowMeans(m, na.rm = TRUE)
  ok    <- is.finite(abund) & is.finite(rate)
  if (!any(ok)) return(NULL)
  df <- data.frame(Abundance = abund[ok], MissingRate = rate[ok] * 100)

  rho <- tryCatch(suppressWarnings(stats::cor(df$Abundance, df$MissingRate,
                                              method = "spearman",
                                              use = "complete.obs")),
                  error = function(e) NA_real_)

  # 图 A: 平均丰度 vs 缺失率
  pA <- ggplot2::ggplot(df, ggplot2::aes(x = Abundance, y = MissingRate)) +
    ggplot2::geom_point(size = 0.85, alpha = 0.35, colour = "#3B6FB5") +
    ggplot2::labs(title = "A. Mean abundance vs. missing rate",
                  x = "Mean log2 abundance", y = "Missing rate (%)") +
    theme_proteo()
  if (nrow(df) >= 20) {
    # aes 数据掩码裸名声明 (R CMD check 消 NOTE; 渲染时掩码列照常遮蔽)
    Abundance <- Bin <- MissingRate <- NULL
    pA <- pA + ggplot2::geom_smooth(method = "loess", formula = y ~ x, se = TRUE,
                                    colour = "#D9534F", fill = "#F3C0BE", linewidth = 0.7)
  }

  # 图 B: 按缺失率分箱看丰度分布 (箱体左移 = 低丰度更易缺失)
  brk <- c(-Inf, 0, 10, 25, 50, Inf)
  lab <- c("0%", "0-10%", "10-25%", "25-50%", ">50%")
  df$Bin <- cut(df$MissingRate, breaks = brk, labels = lab, right = TRUE)
  cnt <- table(df$Bin)
  lv  <- names(cnt)[cnt > 0]
  df$Bin <- factor(as.character(df$Bin), levels = lv,
                   labels = sprintf("%s\n(n=%d)", lv, as.integer(cnt[lv])))
  pB <- ggplot2::ggplot(df, ggplot2::aes(x = Bin, y = Abundance, fill = Bin)) +
    ggplot2::geom_boxplot(width = 0.62, linewidth = 0.25, outlier.size = 0.3) +
    ggplot2::scale_fill_manual(values = rep(c("#9DC3E6", "#5B8FC9", "#F0A6A3", "#D9534F", "#B33A36"),
                                            length.out = length(lv))) +
    ggplot2::guides(fill = "none") +
    ggplot2::labs(title = "B. Abundance distribution by missing-rate bin",
                  x = "Missing rate", y = "log2 abundance") +
    theme_proteo()

  list(
    plots = list(
      A = new_plot(function() pA, kind = "ggplot", width = 10, height = 4.8,
                   label = "平均丰度 vs 缺失率"),
      B = new_plot(function() pB, kind = "ggplot", width = 10, height = 4.8,
                   label = "不同缺失率蛋白的丰度分布")),
    stats = list(n = nrow(df), miss_pct = mean(is.na(m)) * 100, rho = rho)
  )
}

qc_compute <- function(prep, cor_min = NULL, cv_bins = 40) {
  # aes 数据掩码裸名声明 (R CMD check 消 NOTE)
  Detected <- Group <- MissingRate <- PC1 <- PC2 <- Sample <- CV <- CVpct <- NULL
  if (is.null(prep)) return(NULL)
  warnings <- character(0)
  add_warning <- function(m) warnings <<- c(warnings, m)

  p   <- prep
  grp_col <- p$grp_col
  n_groups <- p$n_groups
  # 相关性方法: prep 无此字段, 显式取值复用 (NULL 会让标题与统计表出错)
  cor_method <- p$cor_method %||% "pearson"

  # ---- 文字/尺寸随样本数自适应 (样本多时避免标签拥挤重叠) ----
  n_s        <- length(p$snames)
  ax         <- sample_axis_style(n_s)
  x_ang      <- ax$angle
  x_hj       <- ax$hjust
  x_sz       <- ax$text_sz
  bar_lab_sz <- ax$bar_lab
  bar_w      <- ax$bar_w
  pair_w     <- ax$width
  heat_num   <- if (n_s <= 12) 9 else if (n_s <= 20) 7 else 5
  heat_font  <- if (n_s <= 12) 10 else if (n_s <= 20) 8 else 6.5

  plots <- list()

  # ---- 6.1 蛋白/样本检出数 ----
  plots[["01_qc_detected_counts"]] <- new_plot(function() {
    # aes 数据掩码裸名声明 (R CMD check 消 NOTE; 渲染时掩码列照常遮蔽)
    Detected <- Group <- MissingRate <- PC1 <- PC2 <- Sample <- CV <- CVpct <- NULL
    p1a <- ggplot2::ggplot(data.frame(Sample = factor(p$snames, levels = p$snames),
                                      Group = p$groups, Detected = p$det_sample),
                           ggplot2::aes(x = Sample, y = Detected, fill = Group)) +
      ggplot2::geom_col(width = bar_w, colour = "grey25", linewidth = 0.3) +
      ggplot2::geom_text(ggplot2::aes(label = Detected), vjust = -0.4, size = bar_lab_sz) +
      ggplot2::scale_fill_manual(values = grp_col) +
      ggplot2::labs(title = "Detected proteins per sample", x = "Sample", y = "# Proteins") +
      theme_proteo() +
      ggplot2::theme(axis.text.x = ggplot2::element_text(angle = x_ang, hjust = x_hj, size = x_sz))
    p1b <- ggplot2::ggplot(data.frame(Detected = p$det_prot), ggplot2::aes(x = Detected)) +
      ggplot2::geom_histogram(bins = cv_bins, fill = "#3B6FB5", colour = "white", linewidth = 0.3) +
      ggplot2::labs(title = "Distribution of protein detection frequency",
                    x = "# Samples where protein detected", y = "# Proteins") +
      theme_proteo()
    gridExtra::grid.arrange(p1a, p1b, ncol = 2)
  }, kind = "grid", width = pair_w, height = 5, label = "每样本检出蛋白数 + 蛋白检出频率分布")

  # ---- 6.2 缺失值 ----
  plots[["02_qc_missingness"]] <- new_plot(function() {
    p2a <- ggplot2::ggplot(p$miss_df, ggplot2::aes(x = factor(Sample, levels = p$snames),
                                                   y = MissingRate, fill = Group)) +
      ggplot2::geom_col(width = bar_w, colour = "grey25", linewidth = 0.3) +
      ggplot2::geom_text(ggplot2::aes(label = sprintf("%.1f%%", MissingRate)),
                         vjust = -0.4, size = bar_lab_sz) +
      ggplot2::scale_fill_manual(values = grp_col) +
      ggplot2::labs(title = "Missing value rate per sample", x = "Sample", y = "Missing rate (%)") +
      theme_proteo() +
      ggplot2::theme(axis.text.x = ggplot2::element_text(angle = x_ang, hjust = x_hj, size = x_sz))
    p2b <- ggplot2::ggplot(data.frame(MissingRate = p$miss_per_prot * 100),
                           ggplot2::aes(x = MissingRate)) +
      ggplot2::geom_histogram(bins = cv_bins, fill = "#D9534F", colour = "white", linewidth = 0.3) +
      ggplot2::labs(title = "Distribution of protein missing rate",
                    x = "Missing rate per protein (%)", y = "# Proteins") +
      theme_proteo()
    gridExtra::grid.arrange(p2a, p2b, ncol = 2)
  }, kind = "grid", width = pair_w, height = 5, label = "每样本缺失率 + 蛋白缺失率分布")

  # ---- 需要完整矩阵的三张图: 用 expr_imp 的完全检出子集 (不足 3 个则跳过) ----
  expr_complete <- p$expr_imp[stats::complete.cases(p$expr_imp), , drop = FALSE]
  has_complete  <- nrow(expr_complete) >= 3 && ncol(expr_complete) >= 2
  pca_var <- NULL; cor_range <- NULL
  if (!isTRUE(p$imputed))
    add_warning(sprintf("未做缺失值插补：PCA / 样本相关性 / 层次聚类仅基于 %d 个完全检出蛋白",
                        nrow(expr_complete)))

  if (has_complete) {
    # ---- 6.3 PCA ----
    pca_res <- stats::prcomp(t(expr_complete), center = TRUE, scale. = TRUE)
    pca_var <- round(100 * summary(pca_res)$importance[2, 1:2], 2)
    pca_df  <- data.frame(Sample = rownames(pca_res$x),
                          PC1 = pca_res$x[, 1], PC2 = pca_res$x[, 2], Group = p$groups)
    plots[["03_qc_pca"]] <- new_plot(function() {
      ggplot2::ggplot(pca_df, ggplot2::aes(x = PC1, y = PC2, colour = Group, label = Sample)) +
        ggplot2::geom_point(size = 4) +
        ggrepel::geom_text_repel(size = 3.8, max.overlaps = 30, colour = "grey20") +
        ggplot2::scale_colour_manual(values = grp_col) +
        ggplot2::labs(title = "PCA of samples (imputed, normalized)",
                      x = sprintf("PC1 (%.1f%%)", pca_var[1]),
                      y = sprintf("PC2 (%.1f%%)", pca_var[2])) +
        theme_proteo()
    }, kind = "ggplot", width = 7.5, height = 6.5, label = "样本 PCA 得分图")

    # ---- 6.4 样本相关性热图 ----
    cor_mat  <- stats::cor(expr_complete, method = cor_method)
    # 行列按「分组顺序 + 组内原始样本顺序」排列, 不做聚类 (便于按组读图)
    ord      <- order(match(p$groups, p$group_levels), seq_along(p$snames))
    cor_mat  <- cor_mat[ord, ord, drop = FALSE]
    sn_ord   <- p$snames[ord]
    gr_ord   <- factor(p$groups[ord], levels = p$group_levels)
    cor_cols <- grDevices::colorRampPalette(c("#3B6FB5", "white", "#D9534F"))(100)
    cor_lo <- if (!is.null(cor_min) && is.finite(cor_min) && cor_min < 1) min(cor_min, min(cor_mat)) else min(cor_mat)
    cor_range <- range(cor_mat[upper.tri(cor_mat)])
    # 尺寸: 宽固定 8in, 格子按样本数反推, 高 = 矩阵 + 边距 (否则图例/列名被裁)
    cor_w    <- 8
    cor_cell <- max(4, min(42, (cor_w - 2.5) * 72 / max(n_s, 1)))
    # 行列名字号: 随样本数与名字长度收缩, 避免长名互相重叠
    #   样本 >8 时列名 45° 斜排, 可用间距约 cell*1.414; <=8 时水平排列, 只够 cell 宽
    max_lab   <- max(nchar(sn_ord, type = "width"), 1L)   # 中文按 2 个半角宽计
    name_base <- if (n_s <= 12) 9.5 else if (n_s <= 20) 8 else 6.5
    name_cap  <- if (n_s > 8) cor_cell * 1.414 / max(0.5 * max_lab, 1)
                 else          cor_cell * 0.95  / max(0.5 * max_lab, 1)
    name_font <- max(4, min(name_base, name_cap))
    cor_h    <- max(6.5, (n_s * cor_cell + 150) / 72)
    plots[["04_qc_correlation_heatmap"]] <- new_plot(function() {
      pheatmap::pheatmap(cor_mat, cluster_rows = FALSE, cluster_cols = FALSE,
                         # 样本多时关数值、缩字号
                         display_numbers = n_s <= 24, number_format = "%.2f", number_color = "grey20",
                         fontsize_number = heat_num, fontsize = heat_font, border_color = "white",
                         fontsize_row = name_font, fontsize_col = name_font,
                         angle_col = if (n_s > 8) 45 else 0,
                         color = cor_cols,
                         breaks = seq(cor_lo - 0.01, 1, length.out = 101),
                         main = paste0("Sample correlation (", cor_method, ")"),
                         annotation_col = data.frame(Group = gr_ord, row.names = sn_ord),
                         annotation_colors = list(Group = grp_col),
                         cellwidth = cor_cell, cellheight = cor_cell)
    }, kind = "grid", width = cor_w, height = cor_h, label = "样本间相关性热图")

    # ---- 6.5 样本层次聚类 ----
    hc   <- stats::hclust(stats::dist(t(expr_complete)), method = "complete")
    dend <- stats::as.dendrogram(hc)
    plots[["05_qc_sample_clustering"]] <- new_plot(function() {
      plot(dend, main = "Hierarchical clustering of samples",
           xlab = "Sample", ylab = "Distance", cex.main = 1.2)
      stats::rect.hclust(hc, k = n_groups, border = grp_col)
    }, kind = "base", width = 7.5, height = 6, label = "样本层次聚类树状图")
  } else {
    add_warning("完全检出蛋白不足 3 个，未生成 PCA / 样本相关性热图 / 样本层次聚类图")
  }

  # ---- 6.6 组内 CV 分布 ----
  cv_df <- do.call(rbind, lapply(p$group_levels, function(g) {
    idx <- which(p$groups == g)
    m <- p$expr_raw[, idx, drop = FALSE]
    cv <- apply(m, 1, function(x) {
      x <- x[!is.na(x)]
      if (length(x) < 2 || mean(x) == 0) NA_real_ else stats::sd(x) / mean(x)
    })
    data.frame(Group = g, CV = cv)
  }))
  cv_df <- cv_df[is.finite(cv_df$CV), ]
  plots[["06_qc_cv_distribution"]] <- new_plot(function() {
    ggplot2::ggplot(cv_df, ggplot2::aes(x = CV, fill = Group)) +
      ggplot2::geom_density(alpha = 0.45, linewidth = 0.6) +
      ggplot2::scale_fill_manual(values = grp_col) +
      ggplot2::scale_x_continuous(labels = scales::percent_format()) +
      ggplot2::labs(title = "Within-group coefficient of variation (CV) distribution",
                    x = "CV", y = "Density") +
      theme_proteo()
  }, kind = "ggplot", width = 8, height = 5.5, label = "组内变异系数分布")

  # ---- 6.7 组内 CV 重复性箱线图 (按组比较重复性) ----
  cv_box_df <- cv_df
  if (nrow(cv_box_df) > 0) {
    cv_box_df$Group <- factor(cv_box_df$Group, levels = p$group_levels)
    cv_box_df$CVpct <- cv_box_df$CV * 100
    cv_summary <- do.call(rbind, lapply(p$group_levels, function(g) {
      v <- cv_box_df$CVpct[cv_box_df$Group == g]
      data.frame(Group = g, n = sum(is.finite(v)),
                 median = stats::median(v, na.rm = TRUE) / 100,
                 iqr = stats::IQR(v, na.rm = TRUE) / 100,
                 q1 = stats::quantile(v, 0.25, na.rm = TRUE) / 100,
                 q3 = stats::quantile(v, 0.75, na.rm = TRUE) / 100,
                 stringsAsFactors = FALSE)
    }))
    plots[["07_qc_cv_boxplot"]] <- new_plot(function() {
      ggplot2::ggplot(cv_box_df, ggplot2::aes(x = Group, y = CVpct, fill = Group)) +
        ggplot2::geom_boxplot(width = 0.55, outlier.shape = NA, linewidth = 0.45, alpha = 0.9) +
        ggplot2::geom_jitter(width = 0.16, size = 0.7, alpha = 0.28, colour = "grey30") +
        ggplot2::stat_summary(fun = stats::median, geom = "point", shape = 23, size = 2.6,
                              fill = "white", colour = "grey20") +
        ggplot2::scale_fill_manual(values = grp_col) +
        ggplot2::labs(title = "Within-group CV reproducibility (per protein)",
                      subtitle = "Boxplot with individual proteins; diamond = median",
                      x = "Group", y = "CV (%)") +
        theme_proteo() + ggplot2::theme(legend.position = "none")
    }, kind = "ggplot", width = 8, height = 5.5,
      label = "组内 CV 重复性箱线图")
  } else {
    add_warning("组内 CV 无法计算（每组有效重复不足），未生成 CV 箱线图")
    cv_summary <- NULL
  }

  # ---- 6.8 中位数归一化前后 ----
  plots[["08_qc_median_norm_boxplot"]] <- median_norm_boxplot(p)

  # ---- QC 汇总统计 (供报告正文) ----
  stats <- list(
    det_sample = stats::setNames(as.integer(p$det_sample), p$snames),
    pca_var    = pca_var,
    cv_median  = stats::setNames(
      vapply(p$group_levels, function(g) stats::median(cv_df$CV[cv_df$Group == g], na.rm = TRUE), numeric(1)),
      p$group_levels),
    cv_summary = cv_summary,
    cor_range  = cor_range,
    cor_method = cor_method
  )

  list(plots = plots, stats = stats, warnings = warnings)
}

# 批量落盘 (报告生成时调用); 返回 图片基名 -> 实际文件路径
qc_save_all <- function(qc, out_dir) {
  if (is.null(qc)) return(character(0))
  res <- character(0)
  for (nm in names(qc$plots)) {
    pl <- qc$plots[[nm]]
    res[[nm]] <- save_plot_obj(pl, out_dir, nm, width = pl$width, height = pl$height)
  }
  res
}
